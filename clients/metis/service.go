package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

const launchdLabel = "com.metiser.bridge"

var legacyLaunchdLabels = []string{"com.metis.bridge"}

// installService copies the running binary to a stable location and
// registers it as a login service (launchd agent on macOS, systemd user
// unit on Linux) running `metis run`. The caller's PATH is baked
// into the service definition: services get a bare PATH, and the agent
// CLIs (claude / pi / codex) usually live in version-manager shims.
func installService(logf func(string, ...any)) error {
	if _, err := LoadConfig(configPath()); err != nil {
		return fmt.Errorf("refusing to install a service that would crash-loop: %w", err)
	}
	binary, err := installBinary()
	if err != nil {
		return err
	}
	logf("installed binary at %s", binary)

	logPath := filepath.Join(filepath.Dir(configPath()), "daemon.log")
	switch runtime.GOOS {
	case "darwin":
		return installLaunchd(binary, logPath, logf)
	case "linux":
		return installSystemd(binary, logPath, logf)
	default:
		return fmt.Errorf("service install not supported on %s", runtime.GOOS)
	}
}

// stopService halts the running service until the next login or
// `metis install`. The service definition stays in place. A mid-task
// stop abandons in-flight claims — the agent subprocess (its own
// process group) is orphaned and the server reclaims the silent task.
func stopService(logf func(string, ...any)) error {
	switch runtime.GOOS {
	case "darwin":
		if err := bootoutLaunchd(append([]string{launchdLabel}, legacyLaunchdLabels...)); err != nil {
			return fmt.Errorf("not running? launchctl bootout: %w", err)
		}
		logf("service %s stopped — starts again at next login or metis install", launchdLabel)
		return nil
	case "linux":
		if out, err := exec.Command("systemctl", "--user", "stop", "metis-bridge.service").CombinedOutput(); err != nil {
			return fmt.Errorf("systemctl stop: %s", strings.TrimSpace(string(out)))
		}
		logf("service metis-bridge stopped — starts again at next login or metis install")
		return nil
	default:
		return fmt.Errorf("service stop not supported on %s", runtime.GOOS)
	}
}

func statusService(logf func(string, ...any)) error {
	logPath := filepath.Join(filepath.Dir(configPath()), "daemon.log")
	switch runtime.GOOS {
	case "darwin":
		if _, err := os.Stat(launchdPlistPath()); err != nil {
			for _, label := range legacyLaunchdLabels {
				if _, err := os.Stat(launchdPlistPathFor(label)); err == nil {
					logf("legacy service %s installed — run: metis install to migrate", label)
					return nil
				}
			}
			logf("not installed — run: metis install")
			return nil
		}
		out, err := exec.Command("launchctl", "print", launchdDomain()+"/"+launchdLabel).Output()
		if err != nil {
			logf("installed but stopped — start with: metis install")
			return nil
		}
		logf("running%s (logs: %s)", launchdPid(string(out)), logPath)
		return nil
	case "linux":
		if _, err := os.Stat(systemdUnitPath()); err != nil {
			logf("not installed — run: metis install")
			return nil
		}
		state, err := exec.Command("systemctl", "--user", "is-active", "metis-bridge.service").Output()
		status := strings.TrimSpace(string(state))
		if err != nil && status == "" {
			status = "unknown"
		}
		logf("%s (logs: journalctl --user -u metis-bridge; also %s)", status, logPath)
		return nil
	default:
		return fmt.Errorf("service status not supported on %s", runtime.GOOS)
	}
}

// logService follows the daemon's output: the launchd log file on
// macOS, the user journal on Linux (the systemd unit logs there, not
// to a file).
func logService() error {
	switch runtime.GOOS {
	case "darwin":
		logPath := filepath.Join(filepath.Dir(configPath()), "daemon.log")
		return passthrough("tail", "-n", "50", "-F", logPath)
	case "linux":
		return passthrough("journalctl", "--user", "-u", "metis-bridge.service", "-n", "50", "-f")
	default:
		return fmt.Errorf("log not supported on %s", runtime.GOOS)
	}
}

func passthrough(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == -1 {
		return nil // ^C lands on the whole foreground group; not a failure
	}
	return err
}

// launchdPid pulls the "pid = N" line out of `launchctl print` output.
func launchdPid(report string) string {
	for _, line := range strings.Split(report, "\n") {
		if trimmed := strings.TrimSpace(line); strings.HasPrefix(trimmed, "pid = ") {
			return " (pid " + strings.TrimPrefix(trimmed, "pid = ") + ")"
		}
	}
	return ""
}

func launchdDomain() string {
	return "gui/" + strconv.Itoa(os.Getuid())
}

func bootoutLaunchd(labels []string) error {
	var firstErr error
	stopped := false
	for _, label := range labels {
		if out, err := exec.Command("launchctl", "bootout", launchdDomain()+"/"+label).CombinedOutput(); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %s", label, strings.TrimSpace(string(out)))
			}
		} else {
			stopped = true
		}
	}
	if stopped {
		return nil
	}
	return firstErr
}

func removeLaunchd(label string) error {
	_ = exec.Command("launchctl", "bootout", launchdDomain()+"/"+label).Run()
	if err := os.Remove(launchdPlistPathFor(label)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func uninstallService(logf func(string, ...any)) error {
	switch runtime.GOOS {
	case "darwin":
		for _, label := range append([]string{launchdLabel}, legacyLaunchdLabels...) {
			if err := removeLaunchd(label); err != nil {
				return err
			}
		}
		logf("removed %s (binary left in place)", launchdPlistPath())
		return nil
	case "linux":
		_ = exec.Command("systemctl", "--user", "disable", "--now", "metis-bridge.service").Run()
		unit := systemdUnitPath()
		if err := os.Remove(unit); err != nil && !os.IsNotExist(err) {
			return err
		}
		logf("removed %s (binary left in place)", unit)
		return nil
	default:
		return fmt.Errorf("service uninstall not supported on %s", runtime.GOOS)
	}
}

// installBinary copies the running executable to /usr/local/bin when
// writable, else ~/.local/bin. Running from the target already is fine.
func installBinary() (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		return "", err
	}
	for _, dir := range []string{"/usr/local/bin", localBinDir()} {
		target := filepath.Join(dir, "metis")
		if self == target {
			return target, nil
		}
		if err := copyExecutable(self, target); err == nil {
			return target, nil
		}
	}
	return "", fmt.Errorf("could not write metis into /usr/local/bin or %s", localBinDir())
}

func localBinDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "bin")
}

func copyExecutable(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	// Write-then-rename: the target may be the currently running service
	// binary, which cannot be overwritten in place.
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".metis-install-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

func launchdPlistPath() string {
	return launchdPlistPathFor(launchdLabel)
}

func launchdPlistPathFor(label string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist")
}

func installLaunchd(binary, logPath string, logf func(string, ...any)) error {
	plist := launchdPlistPath()
	if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
		return err
	}
	for _, label := range legacyLaunchdLabels {
		if err := removeLaunchd(label); err != nil {
			return err
		}
	}
	if err := os.WriteFile(plist, []byte(launchdPlist(binary, logPath, os.Getenv("PATH"))), 0o644); err != nil {
		return err
	}
	_ = exec.Command("launchctl", "bootout", launchdDomain()+"/"+launchdLabel).Run()
	if out, err := exec.Command("launchctl", "bootstrap", launchdDomain(), plist).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl bootstrap: %s", strings.TrimSpace(string(out)))
	}
	logf("service %s running (logs: %s)", launchdLabel, logPath)
	return nil
}

func xmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}

func launchdPlist(binary, logPath, path string) string {
	binary, logPath, path = xmlEscape(binary), xmlEscape(logPath), xmlEscape(path)
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>%s</string>
  </dict>
</dict>
</plist>
`, launchdLabel, binary, logPath, logPath, path)
}

func systemdUnitPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "systemd", "user", "metis-bridge.service")
}

func installSystemd(binary, logPath string, logf func(string, ...any)) error {
	unit := systemdUnitPath()
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(unit, []byte(systemdUnit(binary, os.Getenv("PATH"))), 0o644); err != nil {
		return err
	}
	if out, err := exec.Command("systemctl", "--user", "enable", "--now", "metis-bridge.service").CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl enable: %s", strings.TrimSpace(string(out)))
	}
	logf("service metis-bridge running (logs: journalctl --user -u metis-bridge; also %s)", logPath)
	return nil
}

func systemdUnit(binary, path string) string {
	return fmt.Sprintf(`[Unit]
Description=metis — unattended daemon for delegated Metis workflow steps

[Service]
ExecStart=%s run
Restart=always
RestartSec=30
Environment="PATH=%s"

[Install]
WantedBy=default.target
`, binary, path)
}
