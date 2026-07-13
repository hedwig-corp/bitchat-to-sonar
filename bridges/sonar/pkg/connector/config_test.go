package connector

import (
	"os"
	"path/filepath"
	"testing"
)

func validTestConnector(t *testing.T) *SonarConnector {
	t.Helper()
	root := t.TempDir()
	daemon := filepath.Join(root, "sonar-bridge-daemon")
	if err := os.WriteFile(daemon, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	return &SonarConnector{Config: Config{
		DaemonPath:         daemon,
		StateDir:           filepath.Join(root, "accounts"),
		MasterKeyFile:      filepath.Join(root, "master-key"),
		Relays:             []string{"wss://relay.example"},
		BlossomServer:      "https://blossom.example",
		MediaDownloadHosts: []string{"blossom.example"},
	}}
}

func TestConfigRejectsSecretsInCommandLineURLs(t *testing.T) {
	connector := validTestConnector(t)
	if err := connector.ValidateConfig(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	connector.Config.Relays = []string{"wss://token@relay.example"}
	if err := connector.ValidateConfig(); err == nil {
		t.Fatal("relay URL credentials were accepted")
	}

	connector = validTestConnector(t)
	connector.Config.BlossomServer = "https://blossom.example/secret-token"
	if err := connector.ValidateConfig(); err == nil {
		t.Fatal("Blossom URL secret path was accepted")
	}
}
