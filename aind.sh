#!/usr/bin/env bash
# Copyright (c) 2026 Julien Sagot
# SPDX-License-Identifier: MIT
#
# aind — Run AI coding tools inside a persistent Docker container.
#
# Each workspace gets its own named container. The container stays alive after
# you disconnect so the AI tool can keep working; reattach at any time with:
#
#   aind start [workspace]
#
# The Docker image is built from an embedded Dockerfile defined in this script,
# loosely based on the upstream Anthropic devcontainer Dockerfile. It adds a
# few local extras: tmux, extra CLI tools, Docker CE for Docker-in-Docker, and
# UID remapping. The image is rebuilt only when the embedded content changes.
#
# Docker-in-Docker: containers can run docker/docker build inside the container.
# This is enabled by the sysbox-runc container runtime on the host,
# which uses Linux user namespaces to give each container its own isolated
# Docker daemon — without --privileged and without mounting the host Docker
# socket. The host Docker socket is never exposed, so Claude's Docker daemon
# cannot reach host containers or images.
#
# Sysbox is optional. Without it the script runs normally but Docker-in-Docker
# is unavailable. To enable it, install sysbox on the host:
# Installation instructions: https://github.com/nestybox/sysbox#installation
# On Ubuntu/Debian the quickest path is:
#   wget https://downloads.nestybox.com/sysbox/releases/v0.6.4/sysbox-ce_0.6.4-0.linux_amd64.deb
#   sudo apt-get install ./sysbox-ce_*.deb
# Verify with: docker info --format '{{.Runtimes}}' | grep sysbox
#
# Security: the following host paths are mounted into the container and are
# therefore accessible to the AI tool and any code it runs.
#
#   claude mode:
#   ~/.claude/      — full config dir: conversation history, project memories,
#                     settings, and credentials.
#   ~/.claude.json  — global Claude Code config.
#
#   copilot mode:
#   ~/.copilot/     — Copilot config and credentials.
#
#   gemini mode:
#   ~/.gemini/      — Gemini CLI config and credentials.
#
#   ~/.aind/<cname>.github_token  — fine-grained GitHub PAT passed as GH_TOKEN.
#   ~/.aind/<cname>.gitlab_token  — GitLab PAT passed as GITLAB_TOKEN.
#                     Both tokens cover git transport (clone/push/pull via
#                     credential helper) and API calls (gh/glab CLI). They are
#                     optional.
#   <workspace>/    — the directory passed to `start` (default: $PWD). Scope
#                     this carefully — never use $HOME as the workspace or you
#                     expose your entire home directory including SSH keys,
#                     .env files, and other secrets.
#
# Network: the container has unrestricted outbound internet access, so any of
# the data listed above can be exfiltrated by a malicious tool or dependency.
# Do not use this script with workspaces that contain sensitive data.

set -euo pipefail

VERSION=12

IMAGE_NAME="aind"
CONTAINER_PREFIX="aind-"
TOKENS_DIR="$HOME/.aind"

# -- portability helpers ------------------------------------------------------

# sha256sum is a GNU coreutils tool; macOS ships shasum instead.
sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# realpath is GNU coreutils; not available by default on macOS.
# Fall back to readlink -f (also GNU, but present on more systems),
# then to a pure-bash resolution that handles relative paths without
# resolving symlinks.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  elif readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"
  else
    local path="$1"
    [[ "$path" == /* ]] || path="$PWD/$path"
    echo "$path"
  fi
}

# -- helpers ------------------------------------------------------------------

log() { echo "[aind] $*"; }
err() { echo "[aind] ERROR: $*" >&2; exit 1; }

# Verify that all external tools the script relies on are available before
# doing any real work, so failures are reported early and clearly.
check_deps() {
  local missing=()
  for cmd in docker curl find sort; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || missing+=("sha256sum or shasum")
  [[ ${#missing[@]} -eq 0 ]] || err "Missing required commands: ${missing[*]}"
}

# Derive a Docker-safe container name from the workspace path.
# Slashes are replaced with dashes — e.g. /home/ju/my-project → ai--home-ju-my-project.
container_name() {
  local workspace
  workspace="$(resolve_path "${1:-$PWD}")"
  echo "${CONTAINER_PREFIX}${workspace}" | tr '/' '-'
}

# Parse mode flag and optional workspace path from arguments.
# Outputs two space-separated fields: <claude|copilot|gemini> <workspace_or_empty>
# Usage: read -r mode workspace_arg <<< "$(parse_args "$@")"
parse_args() {
  local mode="claude" workspace=""
  for arg in "$@"; do
    case "$arg" in
      --copilot) mode="copilot" ;;
      --gemini)  mode="gemini" ;;
      *)         workspace="$arg" ;;
    esac
  done
  echo "$mode" "$workspace"
}

# Check whether the container with the given name is currently running.
container_running() {
  [[ -n $(docker ps -q --filter "name=^${1}$") ]]
}

# Check whether the container exists in any state (running, stopped, etc.).
container_exists() {
  [[ -n $(docker ps -aq --filter "name=^${1}$") ]]
}

# -- build context ------------------------------------------------------------

# Write the container entrypoint script into the build context directory.
# The entrypoint runs as root at container startup to remap the 'node' user's
# UID/GID to match the host user, so files created inside the container are
# owned by the correct user on the host side.
write_entrypoint() {
  cat > "$1/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e
HOST_UID="${USER_UID:-1000}"
HOST_GID="${USER_GID:-1000}"
if [ "$(id -g node)" != "$HOST_GID" ]; then
  groupmod -g "$HOST_GID" node
fi
if [ "$(id -u node)" != "$HOST_UID" ]; then
  usermod -u "$HOST_UID" node
fi
# Fix ownership of the home directory after the UID/GID remap.
chown -R node:node /home/node /commandhistory 2>/dev/null || true
# Start the Docker daemon for Docker-in-Docker support.
# This works without --privileged because the host uses sysbox-runc, which
# gives each container its own Linux user namespace with an isolated kernel
# view. The daemon here cannot see or affect the host's Docker daemon, its
# containers, or its images — it is fully scoped to this container.
if command -v dockerd >/dev/null 2>&1; then
  dockerd > /var/log/dockerd.log 2>&1 &
fi
exec "$@"
EOF
}

# Write the embedded Dockerfile into the build context directory.
# The Dockerfile is self-contained in this script (see the heredoc below),
# loosely based on the upstream Anthropic devcontainer Dockerfile. Local
# additions on top of the upstream baseline:
#   - extra apt packages (tmux, ripgrep, fd-find, …)
#   - Docker CE from the official Docker apt repo (docker-ce, compose, buildx)
#   - a root-owned entrypoint that remaps node UID/GID at container startup
#   - passwordless sudo for the node user
write_dockerfile() {
  cat > "$1/Dockerfile" <<'DOCKERFILE'
FROM node:20

ARG TZ
ENV TZ="$TZ"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  tmux \
  ripgrep \
  fd-find \
  python3 \
  python3-pip \
  build-essential \
  wget \
  htop \
  netcat-openbsd \
  tree \
  ca-certificates \
  curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Docker CE (latest) from the official Docker repository.
# This gives us docker-ce, docker-compose-plugin, and buildx — unlike the
# distro's docker.io package which ships an older engine without compose.
RUN . /etc/os-release \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
       -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && echo \
       "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/${ID} \
       ${VERSION_CODENAME} stable" \
       > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
       docker-ce \
       docker-ce-cli \
       containerd.io \
       docker-buildx-plugin \
       docker-compose-plugin \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pin runc to v1.1.x for sysbox compatibility.
# runc ≥ 1.2 uses openat2(RESOLVE_NO_XDEV) when applying sysctls, which
# rejects sysboxfs's FUSE-mounted /proc/sys with EXDEV and aborts container
# startup. v1.1.x predates that check and works correctly inside sysbox.
ARG RUNC_VERSION=v1.1.14
RUN ARCH=$(dpkg --print-architecture) \
  && curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" \
       -o /usr/bin/runc \
  && chmod +x /usr/bin/runc

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude Code via the native installer (npm install is deprecated).
# Running as node installs to /home/node/.local/bin — no root workarounds needed.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/node/.local/bin:$PATH"

# Install GitHub Copilot CLI via the official installer.
RUN curl -fsSL https://gh.io/copilot-install | bash

# Install Gemini CLI.
RUN npm install -g @google/gemini-cli

USER root
# fd-find installs as fdfind on Debian; symlink to the conventional name.
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd
RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node && chmod 440 /etc/sudoers.d/node
# Add node to the docker group so it can reach the DinD daemon socket without sudo.
RUN usermod -aG docker node

# Entrypoint: remaps node UID/GID to match the host user at runtime.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE
}


# Write the Dockerfile and supporting files into a build context directory.
# The caller owns the directory and is responsible for cleaning it up.
prepare_build_context() {
  local dir="$1"
  write_dockerfile "$dir"
  write_entrypoint "$dir"
}

# Produce a single hash representing the entire build context. This is used
# to detect changes to the embedded Dockerfile/entrypoint — the hash is stored
# as a Docker image label and compared on each run.
# Uses a while loop instead of xargs so sha256_cmd (a bash function) can be
# called directly; xargs only invokes external commands.
context_hash() {
  find "$1" -type f | sort | while IFS= read -r f; do
    sha256_cmd "$f"
  done | sha256_cmd | cut -d' ' -f1
}

# Retrieve the build context hash that was embedded in the image at build time.
# Returns an empty string if the image doesn't exist yet.
image_hash() {
  docker image inspect "$IMAGE_NAME" \
    --format '{{index .Config.Labels "context-hash"}}' 2>/dev/null || true
}

# Write the embedded build context into a temp directory, hash the result, and
# rebuild the image only if the hash differs from the one stored in the existing
# image (or if --force is passed). The temp directory is always cleaned up on
# return. Returns 0 if a build ran, 1 if it was skipped.
build_image() {
  local force="${1:-false}"
  local tmp
  tmp=$(mktemp -d)
  # Clean up the temp build context on function return, and reset the RETURN
  # trap so it doesn't leak to the caller (bash RETURN traps are global).
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN

  prepare_build_context "$tmp"

  local new_hash
  new_hash=$(context_hash "$tmp")

  if ! $force && [ "$(image_hash)" = "$new_hash" ]; then
    log "Image is up to date (no changes detected)."
    return 1
  fi

  log "Building image..."
  # Store the context hash as a label so future runs can detect changes.
  docker build \
    --label "context-hash=$new_hash" \
    --build-arg TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
    -t "$IMAGE_NAME" \
    "$tmp"
  log "Image built."
}

# -- commands -----------------------------------------------------------------

cmd_build() {
  local force=false
  [[ "${1:-}" == "--force" ]] && force=true
  build_image "$force" || true
}

# -- GitHub / GitLab integration ----------------------------------------------
#
# A single fine-grained PAT per provider covers both git transport
# (clone/push/pull over HTTPS) and API calls (gh/glab CLI):
#
#   ~/.aind/<cname>.github_token  → passed as GH_TOKEN
#   ~/.aind/<cname>.gitlab_token  → passed as GITLAB_TOKEN
#
# At container startup, `gh auth setup-git` and `glab auth setup-git`
# register the respective CLI as a git credential helper, so git picks up
# the token automatically for all HTTPS operations.
#
# GitHub: create a fine-grained PAT at https://github.com/settings/tokens
#   Under "Repository access", choose "All repositories" or select specific repos.
#   Under "Repository permissions", set:
#     - Contents:       Read and write  (git push/pull, file access)
#     - Pull requests:  Read and write  (gh pr create/merge)
#     - Issues:         Read and write  (gh issue create/comment)
#     - Metadata:       Read-only       (required by GitHub, auto-selected)
#   For --copilot mode, also set under "Account permissions":
#     - Copilot:        Read-only       (required for Copilot API requests)
#   Without "Contents: Read and write" pushes will fail with a 403.
#   Without "Copilot: Read-only" Copilot will fail with a 401.
#   Reduce scope if write access is not needed (e.g. Contents: Read-only for read-only workflows).
# GitLab: create a PAT at https://gitlab.com/-/user_settings/personal_access_tokens
#   Recommended scope: api.
#
# Save with correct permissions:
#   install -m600 /dev/stdin ~/.aind/<cname>.github_token   # paste, Ctrl+D
#   install -m600 /dev/stdin ~/.aind/<cname>.gitlab_token
#
# Both tokens are optional. If absent, a warning is shown at start time
# and all GitHub/GitLab access (git and API) is disabled.

# Read the per-container GitHub token (see integration notes above).
read_github_token() {
  local token_file="$TOKENS_DIR/${1}.github_token"
  [[ -f "$token_file" ]] && cat "$token_file" || echo ""
}

# Read the per-container GitLab token (see integration notes above).
read_gitlab_token() {
  local token_file="$TOKENS_DIR/${1}.gitlab_token"
  [[ -f "$token_file" ]] && cat "$token_file" || echo ""
}


# Start a container for the given workspace if one isn't already running,
# then attach to its tmux session. On first attach a new tmux session is
# created with the AI tool running inside; subsequent calls reattach to it.
# This means disconnecting (Ctrl+B, D) leaves the AI tool running in the background.
#
# Container lifecycle:
#   - First start: creates a fresh container from the image.
#   - After stop: restarts the existing stopped container, preserving its
#     writable layer (installed packages, etc.).
#   - To pick up a new image build, remove the container first:
#       docker rm <container-name>
cmd_start() {
  read -r mode workspace_arg <<< "$(parse_args "$@")"
  local workspace
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  local cname
  cname="$(container_name "$workspace")"

  if container_running "$cname"; then
    : # already running, fall through to attach
  elif container_exists "$cname"; then
    log "Restarting stopped container '$cname'..."
    docker start "$cname"
  else
    build_image false || true

    mkdir -p "$workspace" "$TOKENS_DIR"

    # Config mounts differ between modes:
    #   claude:  ~/.claude (config/history) and ~/.claude.json
    #   copilot: ~/.copilot
    #   gemini:  ~/.gemini
    local config_mounts=()
    case "$mode" in
      copilot)
        config_mounts=(
          -v "$HOME/.copilot:/home/node/.copilot"
        ) ;;
      gemini)
        mkdir -p "$HOME/.gemini"
        config_mounts=(
          -v "$HOME/.gemini:/home/node/.gemini"
        ) ;;
      *)
        config_mounts=(
          -v "$HOME/.claude:/home/node/.claude"
          -v "$HOME/.claude.json:/home/node/.claude.json"
        ) ;;
    esac

    log "Starting container '$cname' (workspace: $workspace)..."
    # USER_UID/USER_GID: passed to the entrypoint so it can remap the node user.
    # WORKSPACE: made available inside the container so tmux can cd into it.
    # GIT_*: set the git identity for all commits made by the AI tool.
    # GH_TOKEN/GITLAB_TOKEN: injected at exec time (not run time) so a
    #   stop/start cycle picks up updated token files without needing docker rm.
    # workspace mount: uses the exact host path so paths match on both sides.
    # sleep infinity: keeps the container alive with no resource cost; all work
    #   happens inside a tmux session started via docker exec.
    # --runtime=sysbox-runc: uses the sysbox container runtime instead of the
    #   default runc. Sysbox uses Linux user namespaces to give the container
    #   its own isolated kernel view, enabling a real Docker daemon (and thus
    #   docker build / docker run) inside the container without --privileged
    #   and without exposing the host Docker socket. Requires sysbox installed
    #   on the host — see the top of this script for installation instructions.
    local runtime_flag=""
    if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q sysbox; then
      runtime_flag="--runtime=sysbox-runc"
      log "sysbox-runc available — starting with Docker-in-Docker support."
    else
      log "sysbox-runc not available — starting without Docker-in-Docker support."
    fi

    docker run -d \
      ${runtime_flag:+"$runtime_flag"} \
      --name "$cname" \
      -e USER_UID="$(id -u)" \
      -e USER_GID="$(id -g)" \
      -e WORKSPACE="$workspace" \
      -e GIT_AUTHOR_NAME="$(case "$mode" in copilot) echo 'GitHub Copilot';; gemini) echo 'Gemini CLI';; *) echo 'Claude Code';; esac)" \
      -e GIT_AUTHOR_EMAIL="$(case "$mode" in copilot) echo 'noreply@github.com';; gemini) echo 'noreply@google.com';; *) echo 'noreply@anthropic.com';; esac)" \
      -e GIT_COMMITTER_NAME="$(case "$mode" in copilot) echo 'GitHub Copilot';; gemini) echo 'Gemini CLI';; *) echo 'Claude Code';; esac)" \
      -e GIT_COMMITTER_EMAIL="$(case "$mode" in copilot) echo 'noreply@github.com';; gemini) echo 'noreply@google.com';; *) echo 'noreply@anthropic.com';; esac)" \
      "${config_mounts[@]}" \
      -v "$workspace:$workspace" \
      --workdir "$workspace" \
      "$IMAGE_NAME" \
      sleep infinity
  fi

  # Warn about missing API tokens before attaching so the message is visible.
  # On any warning, pause for acknowledgement before the tmux session takes over.
  local warned=false
  if [[ ! -f "$TOKENS_DIR/${cname}.github_token" ]]; then
    if [[ "$mode" == "copilot" ]]; then
      log "No GitHub token found — Copilot auth will fail." \
          "To enable: create a fine-grained PAT with 'Copilot Requests' permission at https://github.com/settings/tokens" \
          "and save it with: install -m600 /dev/stdin $TOKENS_DIR/${cname}.github_token"
      return 1
    else
      log "No GitHub token found — all GitHub access (git and API) is disabled." \
          "To enable: create a fine-grained PAT at https://github.com/settings/tokens" \
          "and save it with: install -m600 /dev/stdin $TOKENS_DIR/${cname}.github_token"
      warned=true
    fi
  fi
  [[ -f "$TOKENS_DIR/${cname}.gitlab_token" ]] \
    || { log "No GitLab token found — all GitLab access (git and API) is disabled." \
             "To enable: create a PAT at https://gitlab.com/-/user_settings/personal_access_tokens (scope: api)" \
             "and save it with: install -m600 /dev/stdin $TOKENS_DIR/${cname}.gitlab_token"; warned=true; }
  $warned && { log "Press Enter to continue..."; read -r; }

  # Set the terminal tab/window title to the short workspace path.
  local mode_icon
  case "$mode" in
    copilot) mode_icon="🤖" ;;
    gemini)  mode_icon="✨" ;;
    *)       mode_icon="🧠" ;;
  esac
  printf '\033]0;%s\007' "${mode_icon} $(basename "$workspace") - ${workspace}"

  log "Attaching to '$cname' (detach with Ctrl+B, D)..."
  # Read tokens fresh on every attach so stop/start picks up new token files
  # without requiring docker rm.
  local gh_token gitlab_token
  gh_token="$(read_github_token "$cname")"
  gitlab_token="$(read_gitlab_token "$cname")"

  # The tmux startup command differs between modes:
  #   claude:  registers git credential helpers, then runs claude --dangerously-skip-permissions.
  #            --dangerously-skip-permissions is safe here: the container's isolated filesystem
  #            is the security boundary.
  #   copilot: registers git credential helpers, then runs copilot --allow-all.
  #   gemini:  registers git credential helpers, then runs gemini.
  local tmux_cmd
  case "$mode" in
    copilot) tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; copilot --allow-all; exec zsh" ;;
    gemini)  tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; gemini --yolo; exec zsh" ;;
    *)       tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; claude --dangerously-skip-permissions; exec zsh" ;;
  esac

  # Forward terminal settings so the UI renders correctly inside the container.
  # Double-quoting the bash -c string lets the host shell expand $tmux_cmd now,
  # while \$WORKSPACE is deferred to the container's bash via the escaped $.
  docker exec -it --user node \
    -e TERM="${TERM:-xterm-256color}" \
    -e LANG="${LANG:-C.UTF-8}" \
    -e LC_ALL="${LC_ALL:-C.UTF-8}" \
    -e GH_TOKEN="$gh_token" \
    -e GITLAB_TOKEN="$gitlab_token" \
    "$cname" bash -c "
    if ! tmux has-session -t main 2>/dev/null; then
      tmux new-session -s main -c \"\$WORKSPACE\" \"${tmux_cmd}\"
    else
      tmux attach -t main
    fi
  "
}

# Stop the container for the given workspace without removing it, so that its
# writable layer (installed packages, etc.) survives and is reused on the next
# start. To fully remove the container use the rm command.
cmd_stop() {
  read -r _mode workspace_arg <<< "$(parse_args "$@")"
  local workspace cname
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  cname="$(container_name "$workspace")"

  log "Stopping container '$cname'..."
  docker stop "$cname" 2>/dev/null && log "Done." || log "No such container."
}

# Remove the container for the given workspace, discarding its writable layer
# (installed packages, etc.). The next start will create a fresh container.
# -f handles the running case without a prior stop: it SIGKILLs PID 1 and
# removes the container in one step. A graceful stop is unnecessary here
# because the entire writable layer (including any dockerd state) is discarded
# anyway.
cmd_rm() {
  read -r _mode workspace_arg <<< "$(parse_args "$@")"
  local workspace cname
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  cname="$(container_name "$workspace")"

  log "Removing container '$cname'..."
  docker rm -f "$cname" 2>/dev/null && log "Done." || log "No such container."
}

cmd_version() {
  echo "aind version $VERSION"
}

cmd_status() {
  read -r _mode workspace_arg <<< "$(parse_args "$@")"
  if [[ -z "$workspace_arg" ]]; then
    docker ps -a --filter "name=^${CONTAINER_PREFIX}"
  else
    local cname
    cname="$(container_name "$workspace_arg")"
    docker ps -a --filter "name=^${cname}$"
  fi
}

cmd_logs() {
  read -r _mode workspace_arg <<< "$(parse_args "$@")"
  local workspace cname
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  cname="$(container_name "$workspace")"
  docker logs --tail 50 -f "$cname"
}

cmd_restart() {
  cmd_stop "$@"
  cmd_start "$@"
}

# -- dispatch -----------------------------------------------------------------

usage() {
  echo "Usage: $0 {build [--force]|start|stop|restart|rm|status|logs|version} [--copilot|--gemini] [workspace]"
  echo
  echo "  build   [--force]                        Rebuild image if embedded content changed (--force always rebuilds)"
  echo "  start   [--copilot|--gemini] [workspace] Attach to session or start a new one (default: \$PWD)"
  echo "  stop    [--copilot|--gemini] [workspace] Stop the container, preserving its state (default: \$PWD)"
  echo "  restart [--copilot|--gemini] [workspace] Stop then start the container (default: \$PWD)"
  echo "  rm      [--copilot|--gemini] [workspace] Remove the container (default: \$PWD)"
  echo "  status  [--copilot|--gemini] [workspace] Show container status; no arg lists all (default: \$PWD)"
  echo "  logs    [--copilot|--gemini] [workspace] Tail container logs (default: \$PWD)"
  echo "  version                                  Print the script version"
  echo
  echo "  --copilot  Use GitHub Copilot instead of Claude."
  echo "  --gemini   Use Gemini CLI instead of Claude."
}

check_deps

# If no subcommand is given (first arg is a flag or path, not a known verb),
# default to 'start' and pass all args through.
case "${1:-}" in
  build|start|stop|restart|rm|status|logs|version) : ;;
  *) set -- start "$@" ;;
esac

case "$1" in
  build)   cmd_build "${2:-}" ;;
  start)   cmd_start "${@:2}" ;;
  stop)    cmd_stop "${@:2}" ;;
  restart) cmd_restart "${@:2}" ;;
  rm)      cmd_rm "${@:2}" ;;
  status)  cmd_status "${@:2}" ;;
  logs)    cmd_logs "${@:2}" ;;
  version) cmd_version ;;
  *)       usage; exit 1 ;;
esac
