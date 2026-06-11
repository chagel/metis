// metis-bridge — the unattended local daemon for delegated Metis workflow
// steps (docs/local-bridge.md, Phase 4). It polls the bridge pull API,
// claims tasks for the projects configured on this machine, runs a coding
// agent headless in a per-task git worktree, streams progress back, and
// submits the result. Metis never drives this machine — the daemon pulls.
//
// Go stdlib only, single static binary. macOS / Linux.
package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
)

const version = "0.2.0"

func main() {
	command := "help"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	logger := log.New(os.Stdout, "", log.LstdFlags)

	var err error
	switch command {
	case "init":
		err = writeSkeleton(configPath())
	case "once", "run":
		err = withDaemon(logger, func(d *Daemon) error { return d.Run(command == "once") })
	case "gc":
		err = withDaemon(logger, func(d *Daemon) error { d.GC(); return nil })
	case "help", "--help":
		usage()
	default:
		usage()
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "metis-bridge: %v\n", err)
		os.Exit(1)
	}
}

func withDaemon(logger *log.Logger, fn func(*Daemon) error) error {
	cfg, err := LoadConfig(configPath())
	if err != nil {
		return err
	}
	daemon, err := NewDaemon(cfg, logger.Printf)
	if err != nil {
		return err
	}
	return fn(daemon)
}

func configPath() string {
	if path := os.Getenv("METIS_BRIDGE_CONFIG"); path != "" {
		return path
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".metis-bridge", "config.json")
}

func writeSkeleton(path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(configSkeleton), 0o600); err != nil {
		return err
	}
	fmt.Printf("Wrote %s — fill in server, token, and projects.\n", path)
	return nil
}

func usage() {
	fmt.Printf(`metis-bridge %s — unattended daemon for delegated Metis workflow steps

Usage: metis-bridge <init|once|run|gc>
  init   write a config skeleton to ~/.metis-bridge/config.json (or $METIS_BRIDGE_CONFIG)
  once   one poll → work the claimed task → exit
  run    poll forever
  gc     sweep settled task worktrees
`, version)
}
