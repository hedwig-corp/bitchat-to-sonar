package connector

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"

	"github.com/hedwig-corp/bitchat-to-sonar/bridges/sonar/pkg/sonaripc"
)

const loginFlowID = "org.hedwig.sonar.create_identity"

func (connector *SonarConnector) GetLoginFlows() []bridgev2.LoginFlow {
	return []bridgev2.LoginFlow{{
		Name:        "Create Sonar identity",
		Description: "Create a bridge-specific Sonar identity stored on this bridge",
		ID:          loginFlowID,
	}}
}

func (connector *SonarConnector) CreateLogin(ctx context.Context, user *bridgev2.User, flowID string) (bridgev2.LoginProcess, error) {
	if flowID != loginFlowID {
		return nil, fmt.Errorf("unknown login flow ID")
	}
	return &SonarLogin{User: user, Connector: connector}, nil
}

type SonarLogin struct {
	User      *bridgev2.User
	Connector *SonarConnector
}

func (login *SonarLogin) Start(ctx context.Context) (*bridgev2.LoginStep, error) {
	stateID, err := randomStateID()
	if err != nil {
		return nil, err
	}
	stateDir := filepath.Join(login.Connector.Config.StateDir, stateID)
	if err = os.Mkdir(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create Sonar account directory: %w", err)
	}
	ipcConfig := login.Connector.ipcConfig()
	identity, err := sonaripc.InitIdentity(ctx, ipcConfig, stateDir)
	if err != nil {
		return nil, err
	}
	metadata := &UserLoginMetadata{
		AccountID: identity.AccountID,
		StateID:   stateID,
		Npub:      identity.Npub,
		PubkeyHex: identity.PubkeyHex,
	}
	userLogin, err := login.User.NewLogin(ctx, &database.UserLogin{
		ID:         networkid.UserLoginID(identity.AccountID),
		RemoteName: shortIdentity(identity.Npub),
		Metadata:   metadata,
	}, &bridgev2.NewLoginParams{
		LoadUserLogin: func(ctx context.Context, userLogin *bridgev2.UserLogin) error {
			userLogin.Client = newSonarClient(userLogin, login.Connector)
			return nil
		},
	})
	if err != nil {
		return nil, err
	}
	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeComplete,
		StepID:       "org.hedwig.sonar.identity_created",
		Instructions: fmt.Sprintf("Created Sonar identity %s", shortIdentity(identity.Npub)),
		CompleteParams: &bridgev2.LoginCompleteParams{
			UserLoginID: userLogin.ID,
			UserLogin:   userLogin,
		},
	}, nil
}

func (login *SonarLogin) Cancel() {}

func randomStateID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", fmt.Errorf("generate account state ID: %w", err)
	}
	return "account-" + hex.EncodeToString(bytes[:]), nil
}

func shortIdentity(npub string) string {
	if len(npub) <= 20 {
		return npub
	}
	return npub[:12] + "…" + npub[len(npub)-6:]
}
