package sonaripc

import (
	"path/filepath"
	"testing"
)

func TestResolveStateDirRejectsTraversal(t *testing.T) {
	for _, stateID := range []string{"", ".", "..", "../escape", "nested/account"} {
		if _, err := ResolveStateDir(t.TempDir(), stateID); err == nil {
			t.Fatalf("accepted unsafe state ID %q", stateID)
		}
	}
}

func TestResolveStateDirStaysUnderRoot(t *testing.T) {
	root := t.TempDir()
	path, err := ResolveStateDir(root, "account-123")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != root {
		t.Fatalf("resolved outside root: %s", path)
	}
}
