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

func TestLoadConfigSingleServerShorthand(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x/", "token": "t", "projects": {"p": "~/code/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Servers) != 1 {
		t.Fatalf("servers = %d, want shorthand folded into one", len(cfg.Servers))
	}
	server := cfg.Servers[0]
	if server.Server != "http://x" {
		t.Fatalf("server = %q, want trailing slash trimmed", server.Server)
	}
	if server.Name != "x" {
		t.Fatalf("name = %q, want derived from host", server.Name)
	}
	home, _ := os.UserHomeDir()
	if server.Projects["p"] != filepath.Join(home, "code", "p") {
		t.Fatalf("project path = %q, want ~ expanded", server.Projects["p"])
	}
	if cfg.PollInterval != 30 || cfg.HeartbeatInterval != 240 || cfg.GCTTL != 86400 {
		t.Fatalf("defaults not applied: %+v", cfg)
	}
	if cfg.Agent != "claude" || cfg.Client == "" {
		t.Fatalf("agent/client defaults not applied: %+v", cfg)
	}
}

func TestLoadConfigMultiServer(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t, `{
	  "servers": [
	    {"name": "prod", "server": "https://prod.example", "token": "t1", "projects": {"a": "/a"}},
	    {"server": "https://dev.example", "token": "t2", "projects": {"b": "/b"}}
	  ]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Servers) != 2 {
		t.Fatalf("servers = %d", len(cfg.Servers))
	}
	if cfg.Servers[1].Name != "dev.example" {
		t.Fatalf("unnamed server name = %q, want host fallback", cfg.Servers[1].Name)
	}
	prodRoot := cfg.WorktreeRoot(cfg.Servers[0])
	devRoot := cfg.WorktreeRoot(cfg.Servers[1])
	if prodRoot == devRoot {
		t.Fatal("per-server worktree roots must not collide")
	}
	if filepath.Base(prodRoot) != "prod" {
		t.Fatalf("prod root = %q", prodRoot)
	}
}

func TestLoadConfigValidates(t *testing.T) {
	cases := map[string]string{
		`{"token": "t", "projects": {"p": "/p"}}`:         `"servers"`,
		`{"server": "http://x", "token": "t"}`:            `"projects"`,
		`{"server": "http://x", "projects": {"p": "/p"}}`: `"token"`,
		`{"servers": [
		   {"name": "a", "server": "http://x", "token": "t", "projects": {"p": "/p"}},
		   {"name": "a", "server": "http://y", "token": "t", "projects": {"p": "/p"}}
		 ]}`: "duplicate server name",
	}
	for content, wantSubstring := range cases {
		_, err := LoadConfig(writeConfig(t, content))
		if err == nil || !strings.Contains(err.Error(), wantSubstring) {
			t.Fatalf("config %s: error = %v, want mention of %s", content, err, wantSubstring)
		}
	}
}

func TestEnvTokenNeverFansOutToServerList(t *testing.T) {
	t.Setenv("METIS_BRIDGE_TOKEN", "mbt_prod_token")
	_, err := LoadConfig(writeConfig(t, `{
	  "servers": [
	    {"name": "prod", "server": "https://prod.example", "token": "t1", "projects": {"a": "/a"}},
	    {"name": "dev", "server": "https://dev.example", "projects": {"b": "/b"}}
	  ]
	}`))
	if err == nil || !strings.Contains(err.Error(), `"token"`) {
		t.Fatalf("a tokenless entry in an explicit servers list must be a hard error, got %v", err)
	}
}

func TestEnvTokenFillsTokenlessServer(t *testing.T) {
	t.Setenv("METIS_BRIDGE_TOKEN", "mbt_env")
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x", "projects": {"p": "/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Servers[0].Token != "mbt_env" {
		t.Fatalf("token = %q, want env fill", cfg.Servers[0].Token)
	}

	// A token in the file wins — env must not clobber per-server tokens.
	cfg, err = LoadConfig(writeConfig(t,
		`{"server": "http://x", "token": "mbt_file", "projects": {"p": "/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Servers[0].Token != "mbt_file" {
		t.Fatalf("token = %q, want file token kept", cfg.Servers[0].Token)
	}
}

func TestMaxWorkersDefaultsToOne(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x", "token": "t", "projects": {"p": "/p"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Servers[0].MaxWorkers != 1 {
		t.Fatalf("max_workers = %d, want default 1", cfg.Servers[0].MaxWorkers)
	}

	// Set explicitly — on a servers entry and via the flat shorthand.
	cfg, err = LoadConfig(writeConfig(t, `{
	  "servers": [{"name": "prod", "server": "http://x", "token": "t",
	    "projects": {"p": "/p"}, "max_workers": 3}]
	}`))
	if err != nil || cfg.Servers[0].MaxWorkers != 3 {
		t.Fatalf("max_workers = %d, %v, want 3", cfg.Servers[0].MaxWorkers, err)
	}
	cfg, err = LoadConfig(writeConfig(t,
		`{"server": "http://x", "token": "t", "projects": {"p": "/p"}, "max_workers": 2}`))
	if err != nil || cfg.Servers[0].MaxWorkers != 2 {
		t.Fatalf("shorthand max_workers = %d, %v, want 2", cfg.Servers[0].MaxWorkers, err)
	}
}

func TestProjectLookupIsCaseInsensitive(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t,
		`{"server": "http://x", "token": "t", "projects": {"metis": "/code/metis"}}`))
	if err != nil {
		t.Fatal(err)
	}
	// The server's ?project= filter matches case-insensitively, so the
	// daemon can claim "Metis" while configured as "metis" — the local
	// lookup must agree or it instantly fails a claimed run.
	path, ok := cfg.Servers[0].Checkout("Metis")
	if !ok || path != "/code/metis" {
		t.Fatalf("Checkout(\"Metis\") = %q, %v", path, ok)
	}
}
