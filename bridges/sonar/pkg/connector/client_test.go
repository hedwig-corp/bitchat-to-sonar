package connector

import (
	"testing"

	"github.com/hedwig-corp/bitchat-to-sonar/bridges/sonar/pkg/sonaripc"
)

func TestLoginMetadataMustMatchDaemonIdentity(t *testing.T) {
	metadata := &UserLoginMetadata{
		AccountID: "account",
		Npub:      "npub",
		PubkeyHex: "pubkey",
	}
	identity := &sonaripc.Identity{
		AccountID: "account",
		Npub:      "npub",
		PubkeyHex: "pubkey",
	}
	if !metadata.matchesIdentity(identity) {
		t.Fatal("matching daemon identity was rejected")
	}
	identity.PubkeyHex = "different"
	if metadata.matchesIdentity(identity) {
		t.Fatal("mismatched daemon identity was accepted")
	}
}
