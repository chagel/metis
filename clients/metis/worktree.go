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

// taskMeta is the daemon's bookkeeping stamp inside a worktree: claim
// and settle timestamps (gc eligibility), and per-agent session
// pointers — the transcript itself stays in the agent CLI's own store.
type taskMeta struct {
	ClaimedAt string                   `json:"claimed_at,omitempty"`
	SettledAt string                   `json:"settled_at,omitempty"`
	Status    string                   `json:"status,omitempty"`
	Sessions  map[string]sessionRecord `json:"sessions,omitempty"`
}

type sessionRecord struct {
	ID   string `json:"id"`
	Step int    `json:"step"`
}

// repoLocks serializes parent-checkout git mutations: parallel workers
// (and the gc sweep) may share one configured checkout, and concurrent
// worktree add/prune/remove race on its .git metadata.
var repoLocks sync.Map

func lockRepo(repo string) func() {
	mu, _ := repoLocks.LoadOrStore(repo, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	return mu.(*sync.Mutex).Unlock
}

// Worktree is the per-run isolation: a git worktree off the project's
// configured checkout, on a metis/<run-ref> branch — never a checkout
// doing other duty. Keyed by run so consecutive delegated steps share
// repo state; an existing worktree for the same ref is reused — the
// machine-local resume and the step-to-step handoff alike (another
// machine starts fresh from the checkout's HEAD).
type Worktree struct {
	Repo string
	Root string
	Ref  string
}

func (w Worktree) Path() string {
	return filepath.Join(w.Root, w.Ref)
}

func (w Worktree) Branch() string {
	return "metis/" + strings.ToLower(w.Ref)
}

func (w Worktree) Prepare() error {
	if info, err := os.Stat(w.Path()); err == nil && info.IsDir() {
		return w.claimMeta()
	}
	if err := os.MkdirAll(w.Root, 0o755); err != nil {
		return err
	}
	defer lockRepo(w.Repo)()
	if err := w.git("worktree", "prune"); err != nil {
		return err
	}
	var err error
	if w.branchExists(w.Branch()) {
		err = w.git("worktree", "add", w.Path(), w.Branch()) // re-claim after gc — same branch
	} else {
		err = w.git("worktree", "add", w.Path(), "-b", w.Branch())
	}
	if err != nil {
		return err
	}
	if err := w.excludeMeta(); err != nil {
		return err
	}
	return w.claimMeta()
}

// claimMeta marks the worktree active again: settled_at must go (it is
// the gc eligibility signal) but everything else — the session pointers
// above all — survives the re-claim.
func (w Worktree) claimMeta() error {
	return w.mergeMeta(func(meta *taskMeta) {
		meta.ClaimedAt = time.Now().UTC().Format(time.RFC3339)
		meta.SettledAt = ""
		meta.Status = ""
	})
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
	return w.mergeMeta(func(meta *taskMeta) {
		meta.SettledAt = time.Now().UTC().Format(time.RFC3339)
		meta.Status = status
	})
}

// Session pointers are the machine-local memory across a run's steps.
// An empty id still marks "a completed session lives in this cwd" —
// enough for the cwd-scoped --continue agents.
func (w Worktree) SaveSession(agent, id string, step int) error {
	return w.mergeMeta(func(meta *taskMeta) {
		if meta.Sessions == nil {
			meta.Sessions = map[string]sessionRecord{}
		}
		meta.Sessions[agent] = sessionRecord{ID: id, Step: step}
	})
}

func (w Worktree) Session(agent string) (id string, step int, ok bool) {
	record, ok := w.readMeta().Sessions[agent]
	return record.ID, record.Step, ok
}

func (w Worktree) readMeta() taskMeta {
	meta := taskMeta{}
	if raw, err := os.ReadFile(filepath.Join(w.Path(), metaFile)); err == nil {
		_ = json.Unmarshal(raw, &meta)
	}
	return meta
}

func (w Worktree) mergeMeta(update func(*taskMeta)) error {
	meta := w.readMeta()
	update(&meta)
	encoded, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(w.Path(), metaFile), encoded, 0o644)
}

// CommitLeftovers enforces the commit-before-finishing contract the
// prompt only states: uncommitted work on a completed step would be
// invisible to later steps and swept by gc, so the daemon commits it
// rather than trusting the agent did. Returns whether a commit was
// made; a clean tree is a no-op. The meta file lives in info/exclude,
// so it never rides along.
func (w Worktree) CommitLeftovers(message string) (bool, error) {
	status, err := exec.Command("git", "-C", w.Path(), "status", "--porcelain").Output()
	if err != nil {
		return false, fmt.Errorf("git status failed in %s", w.Path())
	}
	if strings.TrimSpace(string(status)) == "" {
		return false, nil
	}
	for _, args := range [][]string{
		{"add", "-A"},
		{"-c", "user.name=metis", "-c", "user.email=daemon@metis.invalid", "commit", "-m", message},
	} {
		out, err := exec.Command("git", append([]string{"-C", w.Path()}, args...)...).CombinedOutput()
		if err != nil {
			return false, fmt.Errorf("git %s failed: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
		}
	}
	return true, nil
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
	var meta taskMeta
	if json.Unmarshal(raw, &meta) != nil || meta.SettledAt == "" {
		return time.Time{}, 0, false // still being worked
	}
	stamp, err := time.Parse(time.RFC3339, meta.SettledAt)
	if err != nil {
		return time.Time{}, 0, false
	}
	return stamp, ttl, true
}
