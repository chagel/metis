package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Daemon releases are nested-module tags (clients/metis/vX.Y.Z) on the
// monorepo, with prebuilt binaries attached by the daemon-release
// workflow. The app's own vX.Y.Z releases carry no binaries and are
// filtered out by the prefix.
const (
	releaseAPI    = "https://api.github.com/repos/chagel/metis/releases?per_page=100"
	releasePrefix = "clients/metis/v"
)

type release struct {
	TagName string `json:"tag_name"`
	Assets  []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

func (r release) version() string {
	return strings.TrimPrefix(r.TagName, releasePrefix)
}

func (r release) assetURL(name string) string {
	for _, asset := range r.Assets {
		if asset.Name == name {
			return asset.URL
		}
	}
	return ""
}

// upgradeService downloads the newest released daemon binary for this
// platform, verifies its checksum, swaps it over the binary running
// this command, and bounces the login service when one is installed.
func upgradeService(logf func(string, ...any)) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		return err
	}
	u := &upgrader{api: releaseAPI, current: version, target: self,
		restart: restartService, logf: logf}
	return u.run()
}

type upgrader struct {
	api     string
	current string
	target  string
	restart func(logf func(string, ...any)) error
	logf    func(string, ...any)
	http    *http.Client
}

func (u *upgrader) run() error {
	latest, err := u.latestRelease()
	if err != nil {
		return err
	}
	if latest == nil {
		return fmt.Errorf("no daemon release found (tags %s*)", releasePrefix)
	}
	switch {
	case latest.version() == u.current:
		u.logf("already up to date (v%s)", u.current)
		return nil
	case !newerVersion(latest.version(), u.current):
		u.logf("running v%s, ahead of the latest release v%s — nothing to do", u.current, latest.version())
		return nil
	}

	name := "metis-" + runtime.GOOS + "-" + runtime.GOARCH
	url := latest.assetURL(name)
	if url == "" {
		return fmt.Errorf("release %s carries no %s binary", latest.TagName, name)
	}
	binary, err := u.fetch(url)
	if err != nil {
		return err
	}
	if err := u.verify(latest, name, binary); err != nil {
		return err
	}
	if err := writeExecutable(u.target, binary); err != nil {
		return err
	}
	u.logf("upgraded %s: v%s → v%s", u.target, u.current, latest.version())
	return u.restart(u.logf)
}

// latestRelease returns the newest daemon release, nil when none exists
// — the releases list is newest-first and mixes in the app's releases.
func (u *upgrader) latestRelease() (*release, error) {
	body, err := u.fetch(u.api)
	if err != nil {
		return nil, err
	}
	var releases []release
	if err := json.Unmarshal(body, &releases); err != nil {
		return nil, fmt.Errorf("could not parse the releases list: %w", err)
	}
	for i := range releases {
		if strings.HasPrefix(releases[i].TagName, releasePrefix) {
			return &releases[i], nil
		}
	}
	return nil, nil
}

// verify checks the binary against the release's checksums.txt. A
// release without one is accepted with a warning — a hand-cut release
// must not wedge every upgrade — but a present, non-matching entry is
// fatal.
func (u *upgrader) verify(rel *release, name string, binary []byte) error {
	url := rel.assetURL("checksums.txt")
	if url == "" {
		u.logf("release %s has no checksums.txt — skipping verification", rel.TagName)
		return nil
	}
	sums, err := u.fetch(url)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(binary)
	sum := hex.EncodeToString(digest[:])
	for _, line := range strings.Split(string(sums), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == name {
			if fields[0] == sum {
				return nil
			}
			return fmt.Errorf("checksum mismatch for %s — refusing to install", name)
		}
	}
	return fmt.Errorf("checksums.txt has no entry for %s", name)
}

func (u *upgrader) fetch(url string) ([]byte, error) {
	client := u.http
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Minute}
	}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s → HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// newerVersion reports whether a (dotted decimal, "0.5.0") is a later
// version than b.
func newerVersion(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(as), len(bs)); i++ {
		an, bn := versionPart(as, i), versionPart(bs, i)
		if an != bn {
			return an > bn
		}
	}
	return false
}

func versionPart(parts []string, i int) int {
	if i >= len(parts) {
		return 0
	}
	n, _ := strconv.Atoi(parts[i])
	return n
}
