package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// releaseServer serves a GitHub-shaped releases list plus assets. The
// list leads with an app release (no binaries) to prove the prefix
// filter skips it.
func releaseServer(t *testing.T, daemonVersion string, binary []byte, sums string) *httptest.Server {
	t.Helper()
	assetName := "metis-" + runtime.GOOS + "-" + runtime.GOARCH
	mux := http.NewServeMux()
	var server *httptest.Server
	mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `[
			{"tag_name": "v9.9.9", "assets": []},
			{"tag_name": "clients/metis/v%s", "assets": [
				{"name": "%s", "browser_download_url": "%s/assets/%s"},
				{"name": "checksums.txt", "browser_download_url": "%s/assets/checksums.txt"}
			]}
		]`, daemonVersion, assetName, server.URL, assetName, server.URL)
	})
	mux.HandleFunc("/assets/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(binary)
	})
	mux.HandleFunc("/assets/checksums.txt", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(sums))
	})
	server = httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func checksumLine(binary []byte) string {
	digest := sha256.Sum256(binary)
	return hex.EncodeToString(digest[:]) + "  metis-" + runtime.GOOS + "-" + runtime.GOARCH + "\n"
}

func testUpgrader(t *testing.T, server *httptest.Server, current string) (*upgrader, string, *int) {
	t.Helper()
	target := filepath.Join(t.TempDir(), "metis")
	if err := os.WriteFile(target, []byte("old-binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	restarts := 0
	u := &upgrader{api: server.URL + "/releases", current: current, targets: []string{target},
		restart: func(func(string, ...any)) error { restarts++; return nil },
		logf:    func(string, ...any) {}}
	return u, target, &restarts
}

func TestUpgradeSwapsBinaryAndRestarts(t *testing.T) {
	binary := []byte("new-binary-content")
	server := releaseServer(t, "9.0.0", binary, checksumLine(binary))
	u, target, restarts := testUpgrader(t, server, "0.3.0")

	if err := u.run(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(binary) {
		t.Fatalf("target = %q, want the released binary", got)
	}
	info, _ := os.Stat(target)
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("mode = %v, want 0755", info.Mode().Perm())
	}
	if *restarts != 1 {
		t.Fatalf("restarts = %d, want 1", *restarts)
	}
}

// The invoked binary and the service's installed copy can differ (e.g.
// ~/go/bin/metis upgrading a service on ~/.local/bin/metis) — both must
// end up on the new version or the restarted service keeps the old one.
func TestUpgradeReplacesServiceAndInvokedCopies(t *testing.T) {
	binary := []byte("new-binary-content")
	server := releaseServer(t, "9.0.0", binary, checksumLine(binary))
	dir := t.TempDir()
	service := filepath.Join(dir, "local-bin", "metis")
	invoked := filepath.Join(dir, "go-bin", "metis")
	for _, path := range []string{service, invoked} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("old-binary"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	restarts := 0
	u := &upgrader{api: server.URL + "/releases", current: "0.3.0",
		targets: []string{service, invoked},
		restart: func(func(string, ...any)) error { restarts++; return nil },
		logf:    func(string, ...any) {}}

	if err := u.run(); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{service, invoked} {
		got, _ := os.ReadFile(path)
		if string(got) != string(binary) {
			t.Fatalf("%s = %q, want the released binary", path, got)
		}
	}
	if restarts != 1 {
		t.Fatalf("restarts = %d, want 1", restarts)
	}
}

func TestUpgradeRefusesMissingChecksums(t *testing.T) {
	binary := []byte("new-binary-content")
	assetName := "metis-" + runtime.GOOS + "-" + runtime.GOARCH
	mux := http.NewServeMux()
	var server *httptest.Server
	mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `[{"tag_name": "clients/metis/v9.0.0", "assets": [
			{"name": "%s", "browser_download_url": "%s/assets/%s"}
		]}]`, assetName, server.URL, assetName)
	})
	mux.HandleFunc("/assets/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(binary)
	})
	server = httptest.NewServer(mux)
	t.Cleanup(server.Close)
	u, target, restarts := testUpgrader(t, server, "0.3.0")

	err := u.run()
	if err == nil || !strings.Contains(err.Error(), "no checksums.txt") {
		t.Fatalf("err = %v, want missing-checksums refusal", err)
	}
	got, _ := os.ReadFile(target)
	if string(got) != "old-binary" || *restarts != 0 {
		t.Fatalf("an unverifiable release must leave the binary and service alone (got %q, %d restarts)", got, *restarts)
	}
}

func TestUpgradeIsNoopWhenCurrentOrAhead(t *testing.T) {
	binary := []byte("new-binary-content")
	server := releaseServer(t, "9.0.0", binary, checksumLine(binary))
	for _, current := range []string{"9.0.0", "10.0.0"} {
		u, target, restarts := testUpgrader(t, server, current)
		if err := u.run(); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(target)
		if string(got) != "old-binary" || *restarts != 0 {
			t.Fatalf("v%s: binary or service must be untouched (got %q, %d restarts)", current, got, *restarts)
		}
	}
}

func TestUpgradeRefusesChecksumMismatch(t *testing.T) {
	binary := []byte("new-binary-content")
	tampered := strings.Repeat("0", 64) + checksumLine(binary)[64:]
	server := releaseServer(t, "9.0.0", binary, tampered)
	u, target, restarts := testUpgrader(t, server, "0.3.0")

	err := u.run()
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("err = %v, want checksum mismatch", err)
	}
	got, _ := os.ReadFile(target)
	if string(got) != "old-binary" || *restarts != 0 {
		t.Fatalf("a failed verify must leave the binary and service alone (got %q, %d restarts)", got, *restarts)
	}
}

func TestUpgradeErrorsWithoutPlatformAsset(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[{"tag_name": "clients/metis/v9.0.0", "assets": []}]`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	u, _, _ := testUpgrader(t, server, "0.3.0")

	err := u.run()
	if err == nil || !strings.Contains(err.Error(), "carries no metis-") {
		t.Fatalf("err = %v, want missing-asset error", err)
	}
}

func TestUpgradeErrorsWhenNoDaemonReleaseExists(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/releases", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[{"tag_name": "v0.1.4", "assets": []}]`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	u, _, _ := testUpgrader(t, server, "0.3.0")

	if err := u.run(); err == nil || !strings.Contains(err.Error(), "no daemon release") {
		t.Fatalf("err = %v, want no-daemon-release error", err)
	}
}

func TestNewerVersion(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"0.5.0", "0.3.0", true},
		{"0.3.0", "0.5.0", false},
		{"0.3.0", "0.3.0", false},
		{"1.0.0", "0.9.9", true},
		{"0.10.0", "0.9.0", true}, // numeric, not lexicographic
		{"0.3.1", "0.3", true},
	}
	for _, c := range cases {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Fatalf("newerVersion(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}
