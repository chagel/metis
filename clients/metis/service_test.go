package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeLaunchctl puts a scripted launchctl first on PATH and returns the
// file each invocation's arguments are appended to. The script can
// branch on $count — how many times its subcommand has run so far.
func fakeLaunchctl(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	body := "#!/bin/sh\n" +
		"echo \"$1\" >> \"" + log + "\"\n" +
		"count=$(grep -c \"^$1$\" \"" + log + "\")\n" +
		script + "\n"
	if err := os.WriteFile(filepath.Join(dir, "launchctl"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return log
}

func launchctlCalls(t *testing.T, log string) []string {
	t.Helper()
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Fields(string(raw))
}

func TestRebootstrapWaitsOutTeardownAndRetries(t *testing.T) {
	log := fakeLaunchctl(t, `case "$1" in
bootout) exit 0;;
print) [ "$count" -le 2 ] && exit 0 || exit 113;;
bootstrap) [ "$count" -ge 2 ] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; };;
esac`)
	if err := rebootstrapLaunchd("/tmp/x.plist"); err != nil {
		t.Fatalf("rebootstrap = %v", err)
	}
	calls := launchctlCalls(t, log)
	want := []string{"bootout", "print", "print", "print", "bootstrap", "bootstrap"}
	if strings.Join(calls, " ") != strings.Join(want, " ") {
		t.Fatalf("calls = %v, want %v", calls, want)
	}
}

func TestRebootstrapReportsPersistentFailure(t *testing.T) {
	log := fakeLaunchctl(t, `case "$1" in
print) exit 113;;
bootstrap) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5;;
esac`)
	err := rebootstrapLaunchd("/tmp/x.plist")
	if err == nil || !strings.Contains(err.Error(), "Input/output error") {
		t.Fatalf("rebootstrap = %v, want the launchctl stderr", err)
	}
	calls := launchctlCalls(t, log)
	if got := strings.Count(strings.Join(calls, " "), "bootstrap"); got != 3 {
		t.Fatalf("bootstrap attempts = %d, want 3", got)
	}
}

func TestLaunchdPlist(t *testing.T) {
	plist := launchdPlist("/usr/local/bin/metis", "/Users/m/.metis/daemon.log", "/opt/x/bin:/usr/bin")
	for _, want := range []string{
		"<string>com.metiser.bridge</string>",
		"<string>/usr/local/bin/metis</string>",
		"<string>run</string>",
		"<key>KeepAlive</key><true/>",
		"<string>/Users/m/.metis/daemon.log</string>",
		// Services get a bare PATH; the agent CLIs live in shims.
		"<string>/opt/x/bin:/usr/bin</string>",
	} {
		if !strings.Contains(plist, want) {
			t.Fatalf("plist missing %q:\n%s", want, plist)
		}
	}
}

func TestLaunchdPlistEscapesXML(t *testing.T) {
	plist := launchdPlist("/usr/local/bin/metis", "/l.log", "/opt/Mike & Co/bin:/usr/bin")
	if !strings.Contains(plist, "/opt/Mike &amp; Co/bin:/usr/bin") {
		t.Fatalf("PATH must be xml-escaped:\n%s", plist)
	}
	if strings.Contains(plist, "& Co") {
		t.Fatal("raw ampersand survived into the plist")
	}
}

func TestLaunchdPid(t *testing.T) {
	report := "com.metiser.bridge = {\n\tactive count = 1\n\tpid = 4242\n\tstate = running\n}"
	if got := launchdPid(report); got != " (pid 4242)" {
		t.Fatalf("launchdPid = %q", got)
	}
	if got := launchdPid("state = not running"); got != "" {
		t.Fatalf("pidless report must yield empty, got %q", got)
	}
}

func TestLaunchdMigrationKeepsLegacyLabelVisible(t *testing.T) {
	if len(legacyLaunchdLabels) != 1 || legacyLaunchdLabels[0] != "com.metis.bridge" {
		t.Fatalf("legacy labels = %v", legacyLaunchdLabels)
	}
	if !strings.HasSuffix(launchdPlistPathFor(legacyLaunchdLabels[0]), "com.metis.bridge.plist") {
		t.Fatalf("legacy plist path = %q", launchdPlistPathFor(legacyLaunchdLabels[0]))
	}
}

func TestSystemdUnit(t *testing.T) {
	unit := systemdUnit("/home/m/.local/bin/metis", "/opt/x/bin:/usr/bin")
	for _, want := range []string{
		"ExecStart=/home/m/.local/bin/metis run",
		"Restart=always",
		`Environment="PATH=/opt/x/bin:/usr/bin"`,
	} {
		if !strings.Contains(unit, want) {
			t.Fatalf("unit missing %q:\n%s", want, unit)
		}
	}
}
