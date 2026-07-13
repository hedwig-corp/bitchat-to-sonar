package connector

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"go.mau.fi/util/ptr"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"

	"github.com/hedwig-corp/bitchat-to-sonar/bridges/sonar/pkg/sonaripc"
)

type SonarClient struct {
	UserLogin *bridgev2.UserLogin
	connector *SonarConnector

	processMu       sync.Mutex
	process         *sonaripc.Client
	cancel          context.CancelFunc
	loggedIn        atomic.Bool
	queuedRemoteID  networkid.MessageID
	queuedRemoteSeq uint64
}

var _ bridgev2.NetworkAPI = (*SonarClient)(nil)
var _ bridgev2.IdentifierResolvingNetworkAPI = (*SonarClient)(nil)

func newSonarClient(login *bridgev2.UserLogin, connector *SonarConnector) *SonarClient {
	return &SonarClient{UserLogin: login, connector: connector}
}

func (connector *SonarConnector) ipcConfig() sonaripc.Config {
	return sonaripc.Config{
		DaemonPath:    connector.Config.DaemonPath,
		MasterKeyFile: connector.Config.MasterKeyFile,
		Relays:        connector.Config.Relays,
		BlossomServer: connector.Config.BlossomServer,
		MediaHosts:    connector.Config.MediaDownloadHosts,
	}
}

func (client *SonarClient) Connect(ctx context.Context) {
	client.processMu.Lock()
	defer client.processMu.Unlock()
	if client.process != nil {
		return
	}
	metadata := client.metadata()
	stateDir, err := sonaripc.ResolveStateDir(client.connector.Config.StateDir, metadata.StateID)
	if err == nil {
		client.process, err = sonaripc.Start(client.connector.ipcConfig(), stateDir)
	}
	if err != nil {
		client.UserLogin.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateTransientDisconnect,
			Error:      "sonar-daemon-unavailable",
			Message:    "The local Sonar account daemon could not be started",
			Info:       map[string]any{"go_error": err.Error()},
		})
		return
	}
	client.loggedIn.Store(true)
	eventContext, cancel := context.WithCancel(context.Background())
	client.cancel = cancel
	client.UserLogin.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnected})
	go client.eventLoop(eventContext)
}

func (client *SonarClient) Disconnect() {
	client.processMu.Lock()
	defer client.processMu.Unlock()
	if client.cancel != nil {
		client.cancel()
		client.cancel = nil
	}
	if client.process != nil {
		_ = client.process.Close()
		client.process = nil
	}
	client.loggedIn.Store(false)
}

func (client *SonarClient) IsLoggedIn() bool                 { return client.loggedIn.Load() }
func (client *SonarClient) LogoutRemote(ctx context.Context) { client.Disconnect() }

func (client *SonarClient) GetCapabilities(ctx context.Context, portal *bridgev2.Portal) *event.RoomFeatures {
	media := func() *event.FileFeatures {
		return &event.FileFeatures{
			MimeTypes:        map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported},
			Caption:          event.CapLevelFullySupported,
			MaxCaptionLength: 64 * 1024,
			MaxSize:          25 * 1024 * 1024,
		}
	}
	return &event.RoomFeatures{
		MaxTextLength: 64 * 1024,
		File: event.FileFeatureMap{
			event.MsgImage: media(), event.MsgVideo: media(), event.MsgAudio: media(),
			event.MsgFile: media(),
		},
		Edit: event.CapLevelRejected, Delete: event.CapLevelRejected,
		Reaction: event.CapLevelRejected, Reply: event.CapLevelRejected,
		Poll: event.CapLevelRejected, Thread: event.CapLevelRejected,
	}
}

func (client *SonarClient) IsThisUser(ctx context.Context, userID networkid.UserID) bool {
	return string(userID) == client.metadata().PubkeyHex
}

func (client *SonarClient) GetChatInfo(ctx context.Context, portal *bridgev2.Portal) (*bridgev2.ChatInfo, error) {
	return &bridgev2.ChatInfo{Members: &bridgev2.ChatMemberList{
		IsFull: true,
		Members: []bridgev2.ChatMember{
			{EventSender: bridgev2.EventSender{IsFromMe: true, Sender: client.selfUserID()}, Membership: event.MembershipJoin, PowerLevel: ptr.Ptr(50)},
			{EventSender: bridgev2.EventSender{Sender: networkid.UserID(portal.ID)}, Membership: event.MembershipJoin, PowerLevel: ptr.Ptr(50)},
		},
	}}, nil
}

func (client *SonarClient) GetUserInfo(ctx context.Context, ghost *bridgev2.Ghost) (*bridgev2.UserInfo, error) {
	id := string(ghost.ID)
	name := "Sonar " + id
	if len(id) > 12 {
		name = "Sonar " + id[:12] + "…"
	}
	return &bridgev2.UserInfo{
		Identifiers: []string{"nostr:" + id},
		Name:        ptr.Ptr(name),
	}, nil
}

func (client *SonarClient) ResolveIdentifier(ctx context.Context, identifier string, createChat bool) (*bridgev2.ResolveIdentifierResponse, error) {
	var resolved struct {
		PeerHex string  `json:"peer_hex"`
		GroupID *string `json:"group_id"`
		Pending bool    `json:"pending"`
	}
	if err := client.call(ctx, "resolve_dm", map[string]any{"peer": strings.TrimSpace(identifier)}, &resolved); err != nil {
		return nil, err
	}
	userID := networkid.UserID(resolved.PeerHex)
	key := client.portalKey(resolved.PeerHex)
	ghost, err := client.UserLogin.Bridge.GetGhostByID(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("get Sonar ghost: %w", err)
	}
	response := &bridgev2.ResolveIdentifierResponse{Ghost: ghost, UserID: userID}
	response.UserInfo, _ = client.GetUserInfo(ctx, ghost)
	if createChat {
		portal, portalErr := client.UserLogin.Bridge.GetPortalByKey(ctx, key)
		if portalErr != nil {
			return nil, fmt.Errorf("get Sonar portal: %w", portalErr)
		}
		info, _ := client.GetChatInfo(ctx, portal)
		response.Chat = &bridgev2.CreateChatResponse{Portal: portal, PortalKey: key, PortalInfo: info}
	}
	return response, nil
}

func (client *SonarClient) metadata() *UserLoginMetadata {
	return client.UserLogin.Metadata.(*UserLoginMetadata)
}

func (client *SonarClient) selfUserID() networkid.UserID {
	return networkid.UserID(client.metadata().PubkeyHex)
}

func (client *SonarClient) portalKey(peerHex string) networkid.PortalKey {
	return networkid.PortalKey{ID: networkid.PortalID(peerHex), Receiver: client.UserLogin.ID}
}

func (client *SonarClient) call(ctx context.Context, method string, params any, result any) error {
	client.processMu.Lock()
	process := client.process
	client.processMu.Unlock()
	if process == nil {
		return fmt.Errorf("Sonar daemon is not connected")
	}
	return process.Call(ctx, method, params, result)
}

func (client *SonarClient) eventLoop(ctx context.Context) {
	ticker := time.NewTicker(client.connector.Config.PollInterval())
	defer ticker.Stop()
	for {
		if err := client.pollEvents(ctx); err != nil && ctx.Err() == nil {
			client.UserLogin.BridgeState.Send(status.BridgeState{
				StateEvent: status.StateTransientDisconnect,
				Error:      "sonar-event-replay-failed", Message: "Sonar event replay is temporarily unavailable",
				Info: map[string]any{"go_error": err.Error()},
			})
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
