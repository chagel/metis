#!/usr/bin/env bash
#
# Provision a Metis `job`-role host for the :docker agent runtime under
# gVisor (Docker-in-Docker). Run this ONCE per job host, before
# `kamal deploy`. Kamal ships containers, not host packages — this is the
# out-of-band host prep the deploy assumes (see docs/coding-runtime.md).
#
# It is idempotent: re-running skips work already done.
#
# What it does:
#   1. installs gVisor (runsc) from the official apt repo
#   2. registers runsc with the Docker daemon (runc stays the default)
#   3. creates the path-identical agent workspace dir, owned by the
#      container's runtime uid
#   4. verifies a container actually runs under runsc
#
# Optional:
#   --build-image DIR   build the metis-pi image from a repo checkout at DIR
#   --rootless          print rootless-dockerd guidance (see caveat below)
#
# Target: Debian/Ubuntu (apt). Needs sudo and a working Docker install.
#
# Usage:
#   sudo ./docker/provision-job-host.sh
#   sudo ./docker/provision-job-host.sh --build-image /opt/metis
#
set -euo pipefail

# --- config (override via env) ---------------------------------------------
AGENT_DIR="${METIS_AGENT_DIR:-/srv/metis/agent}"   # must equal METIS_PERSISTENT_ROOT
RUNTIME_UID="${METIS_RUNTIME_UID:-1000}"           # rails uid in the prod image
RUNTIME_GID="${METIS_RUNTIME_GID:-1000}"
IMAGE_NAME="${METIS_DOCKER_IMAGE:-metis-pi}"

BUILD_IMAGE_DIR=""
SHOW_ROOTLESS=0

# --- helpers ---------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --build-image) BUILD_IMAGE_DIR="${2:?--build-image needs a path}"; shift 2 ;;
    --rootless)    SHOW_ROOTLESS=1; shift ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "this provisions a Linux host (gVisor is Linux-only); got $(uname -s)"
command -v apt-get >/dev/null || die "expected a Debian/Ubuntu host (apt-get not found)"
command -v docker  >/dev/null || die "Docker is not installed — install Docker first"

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# --- 1. install gVisor (runsc) ---------------------------------------------
if command -v runsc >/dev/null; then
  ok "runsc already installed ($(runsc --version 2>/dev/null | head -1))"
else
  log "Installing gVisor (runsc) from the official apt repo"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
  curl -fsSL https://gvisor.dev/archive.key \
    | $SUDO gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
    | $SUDO tee /etc/apt/sources.list.d/gvisor.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq runsc
  ok "runsc installed"
fi

# --- 2. register runsc with the Docker daemon ------------------------------
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q runsc; then
  ok "runsc already registered with the Docker daemon"
else
  log "Registering runsc with Docker (runc stays the default runtime)"
  # Back up daemon.json first — runsc install rewrites it, and this may be a
  # shared host with other apps' daemon config.
  if [ -f /etc/docker/daemon.json ]; then
    $SUDO cp -n /etc/docker/daemon.json "/etc/docker/daemon.json.pre-runsc" || true
    ok "backed up /etc/docker/daemon.json -> daemon.json.pre-runsc"
  fi
  $SUDO runsc install                       # writes runtimes.runsc into /etc/docker/daemon.json
  # SIGHUP live-reloads the runtimes list WITHOUT stopping containers — no
  # outage for co-tenant apps. (A full restart is not needed to add a runtime.)
  if command -v systemctl >/dev/null; then
    $SUDO systemctl reload docker
  else
    $SUDO service docker reload
  fi
  ok "runsc registered; Docker reloaded (no container restart)"
fi

# --- 3. agent workspace dir (path-identical bind-mount source) -------------
if [ -d "$AGENT_DIR" ] && [ "$(stat -c '%u:%g' "$AGENT_DIR")" = "${RUNTIME_UID}:${RUNTIME_GID}" ]; then
  ok "agent dir $AGENT_DIR exists, owned by ${RUNTIME_UID}:${RUNTIME_GID}"
else
  log "Creating agent dir $AGENT_DIR (owner ${RUNTIME_UID}:${RUNTIME_GID})"
  $SUDO mkdir -p "$AGENT_DIR"
  $SUDO chown "${RUNTIME_UID}:${RUNTIME_GID}" "$AGENT_DIR"
  ok "agent dir ready — set METIS_PERSISTENT_ROOT=$AGENT_DIR and bind-mount it at the same path"
fi

# --- optional: build the pi image on this host's daemon --------------------
if [ -n "$BUILD_IMAGE_DIR" ]; then
  [ -f "$BUILD_IMAGE_DIR/docker/pi-runtime/Dockerfile" ] \
    || die "no docker/pi-runtime/Dockerfile under $BUILD_IMAGE_DIR"
  if [ -x "$BUILD_IMAGE_DIR/bin/rails" ]; then
    log "Building $IMAGE_NAME via the rake task (canonical pi version)"
    ( cd "$BUILD_IMAGE_DIR" && bin/rails "docker:image[$IMAGE_NAME]" )
  else
    die "bin/rails not runnable in $BUILD_IMAGE_DIR — build on the dev machine and push to your registry instead (rake \"docker:image[$IMAGE_NAME]\")"
  fi
  ok "image $IMAGE_NAME built"
fi

# --- 4. verify -------------------------------------------------------------
log "Verifying a container runs under runsc"
if docker run --rm --runtime=runsc alpine true 2>/dev/null \
   || docker run --rm --runtime=runsc hello-world >/dev/null 2>&1; then
  ok "containers run under runsc"
else
  warn "could not run a throwaway container under runsc — check 'docker info' / daemon logs"
fi

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  log "Smoke-testing $IMAGE_NAME under runsc"
  docker run --rm --runtime=runsc "$IMAGE_NAME" pi --version \
    && ok "$IMAGE_NAME runs pi under runsc" \
    || warn "$IMAGE_NAME present but 'pi --version' failed under runsc"
else
  warn "image '$IMAGE_NAME' not present on this host — build it or pull from your registry (--pull never needs it local)"
fi

# --- rootless guidance -----------------------------------------------------
if [ "$SHOW_ROOTLESS" -eq 1 ]; then
  cat <<'ROOTLESS'

------------------------------------------------------------------------
Rootless dockerd (recommended to cap the DooD socket's blast radius)
------------------------------------------------------------------------
Rootless setup is user-specific and not automated here. Outline:

  curl -fsSL https://get.docker.com/rootless | sh        # as the deploy user
  systemctl --user enable --now docker
  loginctl enable-linger "$USER"                          # survive logout
  # re-run gVisor registration against the rootless daemon:
  runsc install                                           # writes ~/.config/docker/daemon.json
  systemctl --user restart docker

CAVEAT — the rootless socket is NOT /var/run/docker.sock. It lives at
  /run/user/<uid>/docker.sock
So the job-role volume in config/deploy.yml must point there, e.g.:
  - "/run/user/1000/docker.sock:/var/run/docker.sock"
runsc runs under rootless with the systrap platform (the default).
------------------------------------------------------------------------
ROOTLESS
fi

log "Done. Next: ensure config/deploy.yml has METIS_PERSISTENT_ROOT=$AGENT_DIR"
log "and the job-role socket + $AGENT_DIR bind mounts, then 'kamal deploy'."
log "Measure the gVisor cost: rake \"docker:bench_runtime[$IMAGE_NAME]\""
