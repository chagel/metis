package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const metaFile = ".metis-task.json"

// repoLocks serializes parent-checkout git mutations: parallel workers
// (and the gc sweep) may share one configured checkout, and concurrent
// worktree add/prune/remove race on its .git metadata.
var repoLocks sync.Map

func lockRepo(repo string) func() {
	mu, _ := repoLocks.LoadOrStore(repo, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	return mu.(*sync.Mutex).Unlock
}

// Worktree is the per-task isolation: a git worktree off the project's
// configured checkout, on a metis/<ref> branch — the task never touches
// a checkout doing other duty. An existing worktree for the same ref is
// reused: that is the machine-local resume (a re-claimed task continues
// where this machine left off; another machine starts fresh).
type Worktree struct {
	Repo string
	Root string
	Ref  string
}

func (w Worktree) Path() string {
	return filepath.Join(w.Root, w.Ref)
}

func (w Worktree) Prepare() error {
	if info, err := os.Stat(w.Path()); err == nil && info.IsDir() {
		return w.writeMeta(map[string]any{"claimed_at": time.Now().UTC().Format(time.RFC3339)})
	}
	if err := os.MkdirAll(w.Root, 0o755); err != nil {
		return err
	}
	defer lockRepo(w.Repo)()
	if err := w.git("worktree", "prune"); err != nil {
		return err
	}
	branch := "metis/" + strings.ToLower(w.Ref)
	var err error
	if w.branchExists(branch) {
		err = w.git("worktree", "add", w.Path(), branch) // re-claim after gc — same branch
	} else {
		err = w.git("worktree", "add", w.Path(), "-b", branch)
	}
	if err != nil {
		return err
	}
	if err := w.excludeMeta(); err != nil {
		return err
	}
	return w.writeMeta(map[string]any{"claimed_at": time.Now().UTC().Format(time.RFC3339)})
}

// excludeMeta keeps the bookkeeping file out of the agent's commits: the
// unattended prompt says "commit your work", agents git add -A, and the
// meta would ride into real branches. The worktree's private exclude
// (gitdir/info/exclude) hides it without touching the repo's .gitignore.
func (w Worktree) excludeMeta() error {
	out, err := exec.Command("git", "-C", w.Path(), "rev-parse", "--git-path", "info/exclude").Output()
	if err != nil {
		return fmt.Errorf("git rev-parse --git-path failed: %w", err)
	}
	exclude := strings.TrimSpace(string(out))
	if !filepath.IsAbs(exclude) {
		exclude = filepath.Join(w.Path(), exclude)
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(exclude, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(metaFile + "\n")
	return err
}

func (w Worktree) Settle(status string) error {
	meta := map[string]any{}
	if raw, err := os.ReadFile(filepath.Join(w.Path(), metaFile)); err == nil {
		_ = json.Unmarshal(raw, &meta)
	}
	meta["settled_at"] = time.Now().UTC().Format(time.RFC3339)
	meta["status"] = status
	return w.writeMeta(meta)
}

func (w Worktree) writeMeta(meta map[string]any) error {
	encoded, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(w.Path(), metaFile), encoded, 0o644)
}

func (w Worktree) branchExists(branch string) bool {
	return exec.Command("git", "-C", w.Repo, "rev-parse", "--verify", "refs/heads/"+branch).Run() == nil
}

func (w Worktree) git(args ...string) error {
	out, err := exec.Command("git", append([]string{"-C", w.Repo}, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("git %s failed: %s", args[0], strings.TrimSpace(string(out)))
	}
	return nil
}

// GCWorktrees removes worktrees whose task settled longer than ttl ago,
// and orphans (no meta — a daemon crash mid-prepare) past three times
// that. Unsettled worktrees are never touched.
func GCWorktrees(root string, repoFor func(ref string) string, ttl time.Duration, now time.Time, logf func(string, ...any)) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(root, entry.Name())
		stamp, cutoff, ok := gcStamp(path, ttl, entry)
		if !ok || now.Sub(stamp) < cutoff {
			continue
		}
		if repo := repoFor(entry.Name()); repo != "" {
			unlock := lockRepo(repo)
			_ = exec.Command("git", "-C", repo, "worktree", "remove", "--force", path).Run()
			unlock()
		}
		_ = os.RemoveAll(path)
		logf("gc: removed %s", path)
	}
}

func gcStamp(path string, ttl time.Duration, entry os.DirEntry) (time.Time, time.Duration, bool) {
	raw, err := os.ReadFile(filepath.Join(path, metaFile))
	if err != nil {
		info, infoErr := entry.Info()
		if infoErr != nil {
			return time.Time{}, 0, false
		}
		return info.ModTime().UTC(), ttl * 3, true // orphan
	}
	var meta struct {
		SettledAt string `json:"settled_at"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.SettledAt == "" {
		return time.Time{}, 0, false // still being worked
	}
	stamp, err := time.Parse(time.RFC3339, meta.SettledAt)
	if err != nil {
		return time.Time{}, 0, false
	}
	return stamp, ttl, true
}
