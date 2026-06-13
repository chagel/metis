package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

const configSkeleton = `{
  "agent": "claude",
  "servers": [
    {
      "name": "prod",
      "server": "https://your-metis-host",
      "token": "mbt_… (or set METIS_BRIDGE_TOKEN)",
      "projects": {
        "your-project-name": "~/path/to/its/checkout"
      }
    }
  ]
}
`

// Server is one Metis deployment this machine works for. Tokens and
// projects are per-server: different instances, different identities.
type Server struct {
	Name       string            `json:"name"`
	Server     string            `json:"server"`
	Token      string            `json:"token"`
	Projects   map[string]string `json:"projects"`
	MaxWorkers int               `json:"max_workers"`
}

// Config holds the daemon's settings. All intervals are seconds. The
// flat server/token/projects trio is accepted as single-server
// shorthand for the servers list.
type Config struct {
	Servers    []*Server         `json:"servers"`
	Server     string            `json:"server"`
	Token      string            `json:"token"`
	Projects   map[string]string `json:"projects"`
	MaxWorkers int               `json:"max_workers"`

	Client             string   `json:"client"`
	Agent              string   `json:"agent"`
	AgentArgs          []string `json:"agent_args"`
	PollInterval       int      `json:"poll_interval"`
	HeartbeatInterval  int      `json:"heartbeat_interval"`
	InactivityTimeout  int      `json:"inactivity_timeout"`
	CancelPollInterval int      `json:"cancel_poll_interval"`
	GCTTL              int      `json:"gc_ttl"`
	WorkspacesRoot     string   `json:"workspaces_root"`
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("no config at %s — run: metis init", path)
	}
	cfg := &Config{}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, fmt.Errorf("config is not valid JSON: %w", err)
	}
	return cfg, cfg.normalize()
}

func (c *Config) normalize() error {
	if c.Client == "" {
		host, _ := os.Hostname()
		c.Client, _, _ = strings.Cut(host, ".")
	}
	if c.Agent == "" {
		c.Agent = "claude"
	}
	setDefault(&c.PollInterval, 30)
	setDefault(&c.HeartbeatInterval, 240)
	setDefault(&c.InactivityTimeout, 600)
	setDefault(&c.CancelPollInterval, 30)
	setDefault(&c.GCTTL, 86400)
	if c.WorkspacesRoot == "" {
		c.WorkspacesRoot = "~/.metis/worktrees"
	}
	c.WorkspacesRoot = expandHome(c.WorkspacesRoot)

	if len(c.Servers) == 0 && c.Server != "" {
		// METIS_BRIDGE_TOKEN applies only to the single-server shorthand —
		// a credential must never fan out to every tokenless entry of a
		// multi-server list (it would be sent to the other deployments).
		token := c.Token
		if token == "" {
			token = os.Getenv("METIS_BRIDGE_TOKEN")
		}
		c.Servers = []*Server{{Server: c.Server, Token: token, Projects: c.Projects, MaxWorkers: c.MaxWorkers}}
	}
	if len(c.Servers) == 0 {
		return errors.New(`config needs "servers" (or the single-server "server"/"token"/"projects" shorthand)`)
	}
	seen := map[string]bool{}
	for _, server := range c.Servers {
		if err := server.normalize(); err != nil {
			return err
		}
		if seen[server.Name] {
			return fmt.Errorf("duplicate server name %q", server.Name)
		}
		seen[server.Name] = true
	}
	return nil
}

func (s *Server) normalize() error {
	s.Server = strings.TrimSuffix(s.Server, "/")
	if s.Server == "" {
		return errors.New(`every server needs "server"`)
	}
	if s.Name == "" {
		parsed, err := url.Parse(s.Server)
		if err != nil || parsed.Hostname() == "" {
			return fmt.Errorf("server %q is not a valid URL", s.Server)
		}
		s.Name = parsed.Hostname()
	}
	if strings.TrimSpace(s.Token) == "" {
		return fmt.Errorf(`server %q needs "token" (METIS_BRIDGE_TOKEN applies only to the single-server shorthand)`, s.Name)
	}
	if len(s.Projects) == 0 {
		return fmt.Errorf(`server %q needs "projects" — the daemon only claims tasks it has a checkout for`, s.Name)
	}
	if s.MaxWorkers < 1 {
		s.MaxWorkers = 1
	}
	// Project names are matched case-insensitively, mirroring the
	// server's ?project= claim filter — the daemon must never claim a
	// task it then refuses to work (dogfooded: "metis" vs "Metis"
	// instantly failed a real run).
	lowered := make(map[string]string, len(s.Projects))
	for name, path := range s.Projects {
		lowered[strings.ToLower(name)] = expandHome(path)
	}
	s.Projects = lowered
	return nil
}

// Checkout resolves a task's project to its local path, matching the
// server's case-insensitive project filter.
func (s *Server) Checkout(projectName string) (string, bool) {
	path, ok := s.Projects[strings.ToLower(projectName)]
	return path, ok
}

// WorktreeRoot keeps each server's worktrees apart — dev's RUN-1 and
// prod's RUN-1 are different tasks.
func (c *Config) WorktreeRoot(server *Server) string {
	return filepath.Join(c.WorkspacesRoot, server.Name)
}

func setDefault(value *int, fallback int) {
	if *value == 0 {
		*value = fallback
	}
}

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(path[1:], "/"))
	}
	return path
}
