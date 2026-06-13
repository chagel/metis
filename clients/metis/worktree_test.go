package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWorktreeGC(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `echo '{"final":"done"}'`, "RUN-1", nil) // settled meta

	live := filepath.Join(testWorktreeRoot(root), "RUN-LIVE")
	if err := os.MkdirAll(live, 0o755); err != nil {
		t.Fatal(err)
	}
	claimedOnly, _ := json.Marshal(map[string]any{"claimed_at": time.Now().UTC().Format(time.RFC3339)})
	if err := os.WriteFile(filepath.Join(live, metaFile), claimedOnly, 0o644); err != nil {
		t.Fatal(err)
	}
	orphan := filepath.Join(testWorktreeRoot(root), "RUN-ORPHAN")
	if err := os.MkdirAll(orphan, 0o755); err != nil {
		t.Fatal(err)
	}

	GCWorktrees(testWorktreeRoot(root), func(string) string { return repo }, time.Minute,
		time.Now().UTC().Add(time.Hour), func(string, ...any) {})

	if _, err := os.Stat(filepath.Join(testWorktreeRoot(root), "RUN-1")); !os.IsNotExist(err) {
		t.Fatal("settled worktree past ttl must be removed")
	}
	if _, err := os.Stat(live); err != nil {
		t.Fatal("unsettled worktree must be kept")
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatal("orphan past 3x ttl must be removed")
	}
}

func TestWorktreePrepareReusesBranchAfterGC(t *testing.T) {
	repo, root := initRepo(t)
	worktree := Worktree{Repo: repo, Root: root, Ref: "RUN-9"}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	if err := worktree.Settle("completed"); err != nil {
		t.Fatal(err)
	}
	// gc removes the dir but the metis/run-9 branch lingers in the repo.
	GCWorktrees(root, func(string) string { return repo }, 0, time.Now().UTC().Add(time.Hour),
		func(string, ...any) {})
	if err := worktree.Prepare(); err != nil {
		t.Fatalf("re-prepare after gc must reuse the branch: %v", err)
	}
}

func TestWorktreePrepareRefreshesMetaWhenReusingExistingWorktree(t *testing.T) {
	repo, root := initRepo(t)
	worktree := Worktree{Repo: repo, Root: root, Ref: "RUN-10"}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	if err := worktree.Settle("completed"); err != nil {
		t.Fatal(err)
	}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(worktree.Path(), metaFile))
	if err != nil {
		t.Fatal(err)
	}
	var meta map[string]any
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatal(err)
	}
	if meta["settled_at"] != nil || meta["status"] != nil || meta["claimed_at"] == nil {
		t.Fatalf("reuse meta = %v", meta)
	}
}

func TestMetaFileIsInvisibleToGit(t *testing.T) {
	repo, root := initRepo(t)
	worktree := Worktree{Repo: repo, Root: root, Ref: "RUN-5"}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	// Unattended agents run git add -A; the daemon's bookkeeping must
	// never ride into their commits.
	out, err := exec.Command("git", "-C", worktree.Path(), "status", "--porcelain").Output()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), metaFile) {
		t.Fatalf("meta file visible to git:\n%s", out)
	}
}
