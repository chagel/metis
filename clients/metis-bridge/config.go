package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const configSkeleton = `{
  "server": "https://your-metis-host",
  "token": "mbt_… (or set METIS_BRIDGE_TOKEN)",
  "agent": "claude",
  "projects": {
    "your-project-name": "~/path/to/its/checkout"
  }
}
`

// Config holds the daemon's settings. All intervals are seconds.
type Config struct {
	Server             string            `json:"server"`
	Token              string            `json:"token"`
	Client             string            `json:"client"`
	Agent              string            `json:"agent"`
	AgentArgs          []string          `json:"agent_args"`
	Projects           map[string]string `json:"projects"`
	PollInterval       int               `json:"poll_interval"`
	HeartbeatInterval  int               `json:"heartbeat_interval"`
	InactivityTimeout  int               `json:"inactivity_timeout"`
	CancelPollInterval int               `json:"cancel_poll_interval"`
	GCTTL              int               `json:"gc_ttl"`
	WorkspacesRoot     string            `json:"workspaces_root"`
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("no config at %s — run: metis-bridge init", path)
	}
	cfg := &Config{}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, fmt.Errorf("config is not valid JSON: %w", err)
	}
	return cfg, cfg.normalize()
}

func (c *Config) normalize() error {
	c.Server = strings.TrimSuffix(c.Server, "/")
	if token := os.Getenv("METIS_BRIDGE_TOKEN"); token != "" {
		c.Token = token
	}
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
		c.WorkspacesRoot = "~/.metis-bridge/worktrees"
	}
	c.WorkspacesRoot = expandHome(c.WorkspacesRoot)
	for name, path := range c.Projects {
		c.Projects[name] = expandHome(path)
	}

	switch {
	case c.Server == "":
		return errors.New(`config needs "server"`)
	case strings.TrimSpace(c.Token) == "":
		return errors.New(`config needs "token" or METIS_BRIDGE_TOKEN`)
	case len(c.Projects) == 0:
		return errors.New(`config needs "projects" — the daemon only claims tasks it has a checkout for`)
	}
	return nil
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
