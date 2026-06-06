# pi runtime image for Agent::Runtime::Docker — pi plus a basic toolchain.
#
# Build it with:        bin/rails "docker:image[metis-pi]"
# Point Metis at it:    export METIS_DOCKER_IMAGE=metis-pi
#                       export METIS_AGENT_RUNTIME=docker
FROM node:22-slim

# pi's bash tool expects a basic toolchain on PATH. `gh` is here so the
# agent can authenticate as the operator against GitHub via the
# `GH_TOKEN` the runtime injects per turn (see app/services/agent/
# runtime/base.rb). Installed from GitHub's apt source — the
# `gh-cli.list` repo holds the current major.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg ripgrep \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# pi itself, pinned to the version pi-agent-rb supports. The rake task
# passes PI_VERSION from PiAgent::SUPPORTED_PI_VERSION.
ARG PI_VERSION
RUN npm install --global "@earendil-works/pi-coding-agent@${PI_VERSION}"

# The MCP connector bridge (pi-mcp-adapter). Keep the version in sync
# with bin/setup and lib/tasks/e2b.rake.
#
# Install it under the same HOME the runtime uses (`--env HOME=/tmp` in
# Agent::Runtime::Docker#docker_args), so pi at runtime finds the
# package + settings.json. The container runs as the host UID with no
# /etc/passwd entry, so we chmod the tree world-rwx — the runtime user
# must be able to read the extension and write pi's session/cache state.
RUN HOME=/tmp pi install npm:pi-mcp-adapter@2.7.0 \
 && chmod -R a+rwX /tmp/.pi

# The Google Workspace CLI (gws) — how the agent reaches Gmail,
# Calendar, and Drive. It reads its bearer from
# GOOGLE_WORKSPACE_CLI_TOKEN, which Agent::Runtime::Base#sandbox_env
# exports per turn from the user's Google OauthGrant. The shipped
# `gws-*` skills in `.pi/skills/` are what tells the agent how to
# drive it. The npm package downloads the matching pre-built binary
# from the project's GitHub Releases.
RUN npm install --global @googleworkspace/cli

# The app's bundled pi extensions, baked in at the path
# Runtime::Docker#extension_paths expects (EXTENSIONS_DIR =
# /metis-extensions). Baked rather than bind-mounted from the Rails side
# because under Docker-in-Docker a host-daemon bind mount resolves the
# source against the host filesystem, not the job container — so the repo
# path would not exist. Build context is the repo root (see docker:image);
# rebuild this image when .pi/extensions changes.
COPY .pi/extensions /metis-extensions
