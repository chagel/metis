package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeConfig(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadConfigDefaultsAndExpansion(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x/", "token": "t", "projects": {"p": "~/code/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Server != "http://x" {
		t.Fatalf("server = %q, want trailing slash trimmed", cfg.Server)
	}
	home, _ := os.UserHomeDir()
	if cfg.Projects["p"] != filepath.Join(home, "code", "p") {
		t.Fatalf("project path = %q, want ~ expanded", cfg.Projects["p"])
	}
	if cfg.PollInterval != 30 || cfg.HeartbeatInterval != 240 || cfg.GCTTL != 86400 {
		t.Fatalf("defaults not applied: %+v", cfg)
	}
	if cfg.Agent != "claude" || cfg.Client == "" {
		t.Fatalf("agent/client defaults not applied: %+v", cfg)
	}
}

func TestLoadConfigValidates(t *testing.T) {
	cases := map[string]string{
		`{"token": "t", "projects": {"p": "/p"}}`:         `"server"`,
		`{"server": "http://x", "token": "t"}`:            `"projects"`,
		`{"server": "http://x", "projects": {"p": "/p"}}`: `"token"`,
	}
	for content, wantSubstring := range cases {
		_, err := LoadConfig(writeConfig(t, content))
		if err == nil || !strings.Contains(err.Error(), wantSubstring) {
			t.Fatalf("config %s: error = %v, want mention of %s", content, err, wantSubstring)
		}
	}
}

func TestEnvTokenOverridesConfig(t *testing.T) {
	t.Setenv("METIS_BRIDGE_TOKEN", "mbt_env")
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x", "token": "mbt_file", "projects": {"p": "/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Token != "mbt_env" {
		t.Fatalf("token = %q, want env override", cfg.Token)
	}
}
