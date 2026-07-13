package connector

import (
	"context"
	"fmt"
	"os"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
)

type SonarConnector struct {
	bridge *bridgev2.Bridge
	Config Config
}

var _ bridgev2.NetworkConnector = (*SonarConnector)(nil)

func (connector *SonarConnector) Init(bridge *bridgev2.Bridge) {
	connector.bridge = bridge
	bridge.Config.BridgeStatusNotices = "none"
}

func (connector *SonarConnector) Start(ctx context.Context) error {
	if err := os.MkdirAll(connector.Config.StateDir, 0o700); err != nil {
		return fmt.Errorf("create Sonar account root: %w", err)
	}
	return os.Chmod(connector.Config.StateDir, 0o700)
}

func (connector *SonarConnector) GetBridgeInfoVersion() (info, capabilities int) {
	return 1, 1
}

func (connector *SonarConnector) GetCapabilities() *bridgev2.NetworkGeneralCapabilities {
	return &bridgev2.NetworkGeneralCapabilities{
		Provisioning: bridgev2.ProvisioningCapabilities{
			ResolveIdentifier: bridgev2.ResolveIdentifierCapabilities{
				Search:   true,
				CreateDM: true,
			},
		},
	}
}

func (connector *SonarConnector) GetName() bridgev2.BridgeName {
	return bridgev2.BridgeName{
		DisplayName:      "Sonar",
		NetworkURL:       "https://github.com/hedwig-corp/bitchat-to-sonar",
		NetworkIcon:      "",
		NetworkID:        "sonar",
		BeeperBridgeType: "github.com/hedwig-corp/bitchat-to-sonar/bridges/sonar",
		DefaultPort:      29338,
	}
}

type UserLoginMetadata struct {
	AccountID   string `json:"account_id"`
	StateID     string `json:"state_id"`
	Npub        string `json:"npub"`
	PubkeyHex   string `json:"pubkey_hex"`
	EventCursor uint64 `json:"event_cursor,omitempty"`
}

func (connector *SonarConnector) GetDBMetaTypes() database.MetaTypes {
	return database.MetaTypes{
		Portal:   nil,
		Ghost:    nil,
		Message:  nil,
		Reaction: nil,
		UserLogin: func() any {
			return &UserLoginMetadata{}
		},
	}
}

func (connector *SonarConnector) LoadUserLogin(ctx context.Context, login *bridgev2.UserLogin) error {
	metadata, ok := login.Metadata.(*UserLoginMetadata)
	if !ok || metadata.AccountID == "" || metadata.StateID == "" || metadata.Npub == "" || metadata.PubkeyHex == "" {
		return fmt.Errorf("Sonar login metadata is incomplete")
	}
	login.Client = newSonarClient(login, connector)
	return nil
}
