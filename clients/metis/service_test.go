package main

import (
	"strings"
	"testing"
)

func TestLaunchdPlist(t *testing.T) {
	plist := launchdPlist("/usr/local/bin/metis", "/Users/m/.metis/daemon.log", "/opt/x/bin:/usr/bin")
	for _, want := range []string{
		"<string>com.metis.bridge</string>",
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

func TestSystemdUnit(t *testing.T) {
	unit := systemdUnit("/home/m/.local/bin/metis", "/opt/x/bin:/usr/bin")
	for _, want := range []string{
		"ExecStart=/home/m/.local/bin/metis run",
		"Restart=always",
		"Environment=PATH=/opt/x/bin:/usr/bin",
	} {
		if !strings.Contains(unit, want) {
			t.Fatalf("unit missing %q:\n%s", want, unit)
		}
	}
}
