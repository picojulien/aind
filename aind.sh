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
#   opencode mode:
#   ~/.config/opencode/      — OpenCode config and credentials.
#   ~/.local/share/opencode/ — OpenCode local data, auth.json, sessions.
#   ~/.cache/opencode/       — OpenCode cache, npm plugins, indexes.
#   ~/.local/state/opencode/ — OpenCode UI state, model selection.
#   ~/.aind/opencode.jsonc   — shared AIND OpenCode config, mounted read-only
#                               as /etc/opencode/opencode.jsonc. Created when
#                               missing; legacy AIND defaults are migrated, and
#                               custom local edits persist.
#
#   ~/.aind/<cname>.claude_settings_local.json — per-container Claude settings
#                     override, mounted as ~/.claude/settings.local.json inside
#                     the container. Edit it to customize hooks (e.g. Notification)
#                     without touching the host settings.
#   ~/.aind/<cname>.github_token  — fine-grained GitHub PAT passed as GH_TOKEN.
#   ~/.aind/<cname>.gitlab_token  — GitLab PAT passed as GITLAB_TOKEN.
#                     Both tokens cover git transport (clone/push/pull via
#                     credential helper) and API calls (gh/glab CLI). They are
#                     optional.
#   <workspace>/    — the directory passed to `start` (default: $PWD). Scope
#                     this carefully — never use $HOME as the workspace or you
#                     expose your entire home directory including SSH keys,
#                     .env files, and other secrets.
#                     In OpenCode mode, --cwd/-cwd starts OpenCode in an existing
#                     subdirectory while keeping this mount as the workspace root.
#
# Network: the container has unrestricted outbound internet access, so any of
# the data listed above can be exfiltrated by a malicious tool or dependency.
# Do not use this script with workspaces that contain sensitive data.

set -euo pipefail

VERSION=14

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
# then to a pure-bash resolution that canonicalizes the existing path or nearest
# existing parent while preserving missing leaf creation.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  elif readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"
  else
    local path="$1" parent leaf resolved suffix=""
    [[ "$path" == /* ]] || path="$PWD/$path"

    if [[ -d "$path" ]]; then
      (cd -- "$path" && pwd -P)
      return 0
    fi

    if [[ -e "$path" ]]; then
      parent="${path%/*}"
      leaf="${path##*/}"
      [[ "$parent" != "$path" && -n "$parent" ]] || parent="/"
      resolved="$(cd -- "$parent" && pwd -P)"
      if [[ "$resolved" == "/" ]]; then
        printf '/%s\n' "$leaf"
      else
        printf '%s/%s\n' "$resolved" "$leaf"
      fi
      return 0
    fi

    parent="$path"
    while [[ "$parent" != "/" && ! -d "$parent" ]]; do
      leaf="${parent##*/}"
      suffix="${leaf}${suffix:+/$suffix}"
      parent="${parent%/*}"
      [[ -n "$parent" ]] || parent="/"
    done

    if [[ -d "$parent" ]]; then
      resolved="$(cd -- "$parent" && pwd -P)"
      if [[ -n "$suffix" ]]; then
        if [[ "$resolved" == "/" ]]; then
          printf '/%s\n' "$suffix"
        else
          printf '%s/%s\n' "$resolved" "$suffix"
        fi
      else
        printf '%s\n' "$resolved"
      fi
    else
      printf '%s\n' "$path"
    fi
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

# Parse mode flag, optional --cwd/-cwd, and optional workspace path from arguments.
# Sets PARSED_MODE, PARSED_CWD, and PARSED_WORKSPACE.
parse_args() {
  PARSED_MODE="claude"
  PARSED_CWD=""
  PARSED_WORKSPACE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --copilot) PARSED_MODE="copilot"; shift ;;
      --gemini)  PARSED_MODE="gemini"; shift ;;
      --opencode) PARSED_MODE="opencode"; shift ;;
      --cwd|-cwd)
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != -* ]] \
          || err "--cwd/-cwd requires a relative OpenCode start subdirectory."
        PARSED_CWD="$2"
        shift 2
        ;;
      --cwd=*|-cwd=*)
        PARSED_CWD="${1#*=}"
        [[ -n "$PARSED_CWD" ]] \
          || err "--cwd/-cwd requires a relative OpenCode start subdirectory."
        shift
        ;;
      --*)
        err "Unknown option: $1"
        ;;
      -*)
        err "Unknown option: $1"
        ;;
      *)
        PARSED_WORKSPACE="$1"
        shift
        ;;
    esac
  done

  if [[ -n "$PARSED_CWD" && "$PARSED_MODE" != "opencode" ]]; then
    err "--cwd/-cwd can only be used with --opencode."
  fi
}

# Resolve an existing directory physically, following symlinks.
resolve_existing_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  (cd -- "$dir" && pwd -P)
}

# Validate that OpenCode starts in an existing relative subdirectory inside the
# mounted workspace. Prints the resolved start directory.
validate_opencode_start_dir() {
  local workspace="$1" cwd="${2:-}" workspace_resolved start_dir
  if [[ -z "$cwd" ]]; then
    if start_dir="$(resolve_existing_dir "$workspace")"; then
      printf '%s\n' "$start_dir"
    else
      printf '%s\n' "$workspace"
    fi
    return 0
  fi

  [[ "$cwd" != /* ]] \
    || err "--cwd/-cwd must be relative, not absolute: $cwd"

  if ! workspace_resolved="$(resolve_existing_dir "$workspace")"; then
    err "OpenCode workspace must exist and be a directory when --cwd/-cwd is used: $workspace"
  fi
  if ! start_dir="$(resolve_existing_dir "$workspace_resolved/$cwd")"; then
    err "--cwd/-cwd must be an existing directory under the workspace: $cwd"
  fi

  if [[ "$workspace_resolved" == "/" ]]; then
    printf '%s\n' "$start_dir"
    return 0
  fi

  case "$start_dir" in
    "$workspace_resolved"|"$workspace_resolved"/*) printf '%s\n' "$start_dir" ;;
    *) err "--cwd/-cwd resolves outside the workspace: $cwd" ;;
  esac
}

# Check whether the container with the given name is currently running.
container_running() {
  [[ -n $(docker ps -q --filter "name=^${1}$") ]]
}

# Check whether the container exists in any state (running, stopped, etc.).
container_exists() {
  [[ -n $(docker ps -aq --filter "name=^${1}$") ]]
}

# Read the aind mode label from an existing container. Older containers do not
# have this label; return empty so they remain compatible.
container_mode_label() {
  local mode
  mode="$(docker inspect --format '{{ index .Config.Labels "aind.mode" }}' "$1" 2>/dev/null || true)"
  [[ "$mode" == "<no value>" ]] && mode=""
  echo "$mode"
}

# Prevent accidentally reusing a labeled container with a different tool mode.
ensure_container_mode() {
  local cname="$1" requested_mode="$2" existing_mode
  existing_mode="$(container_mode_label "$cname")"
  if [[ -n "$existing_mode" && "$existing_mode" != "$requested_mode" ]]; then
    err "Container '$cname' was created for '$existing_mode' mode, but '$requested_mode' was requested. Use the original mode or remove the container first."
  fi
}

# Check whether an existing container has a bind mount at the given destination.
container_has_bind_mount() {
  local cname="$1" destination="$2" mounts
  mounts="$(docker inspect --format '{{ range .Mounts }}{{ .Type }} {{ .Destination }}{{ "\n" }}{{ end }}' "$cname" 2>/dev/null || true)"
  [[ $'\n'"$mounts"$'\n' == *$'\n'"bind $destination"$'\n'* ]]
}

# Check whether an existing container has a read-only bind mount from the
# expected host source at the given destination.
container_has_readonly_bind_mount_from() {
  local cname="$1" destination="$2" expected_source="$3"
  local expected_source_resolved mounts type source mount_destination rw
  expected_source_resolved="$(resolve_path "$expected_source")"
  mounts="$(docker inspect --format '{{ range .Mounts }}{{ .Type }}{{ "\t" }}{{ .Source }}{{ "\t" }}{{ .Destination }}{{ "\t" }}{{ .RW }}{{ "\n" }}{{ end }}' "$cname" 2>/dev/null || true)"

  while IFS=$'\t' read -r type source mount_destination rw; do
    if [[ "$type" == "bind" && "$mount_destination" == "$destination" && "$rw" == "false" &&
          ( "$source" == "$expected_source" || "$source" == "$expected_source_resolved" ) ]]; then
      return 0
    fi
  done <<< "$mounts"
  return 1
}

# OpenCode credentials and AIND config live in mode-specific bind mounts.
# Existing containers created before OpenCode support may not have them, so fail
# before attaching.
ensure_opencode_mounts() {
  local cname="$1" workspace="$2" missing=()
  container_has_bind_mount "$cname" "/home/node/.config/opencode" \
    || missing+=("/home/node/.config/opencode")
  container_has_bind_mount "$cname" "/home/node/.local/share/opencode" \
    || missing+=("/home/node/.local/share/opencode")
  container_has_bind_mount "$cname" "/home/node/.cache/opencode" \
    || missing+=("/home/node/.cache/opencode")
  container_has_bind_mount "$cname" "/home/node/.local/state/opencode" \
    || missing+=("/home/node/.local/state/opencode")
  container_has_readonly_bind_mount_from "$cname" "/etc/opencode/opencode.jsonc" "$TOKENS_DIR/opencode.jsonc" \
    || missing+=("/etc/opencode/opencode.jsonc (read-only from $TOKENS_DIR/opencode.jsonc)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Container '$cname' is missing or has invalid OpenCode bind mount(s): ${missing[*]}. Remove and recreate it with: aind rm --opencode '$workspace' && aind start --opencode '$workspace'"
  fi
}

# Create the shared AIND-managed OpenCode config when absent, or migrate known
# AIND-generated defaults. Custom edits are not overwritten.
# Agent permissions are explicit because OpenCode merges global and agent
# permissions, and agent rules take precedence over the global yolo setting.
opencode_builtin_agent_names() {
  printf '%s\n' build plan general explore title summary compaction
}

opencode_discovered_agent_names() {
  local workspace dir path name
  local dirs=(
    "$HOME/.config/opencode/agents"
    "$HOME/.config/opencode/agent"
  )
  for workspace in "$@"; do
    [[ -n "$workspace" ]] || continue
    dirs+=(
      "$workspace/.opencode/agents"
      "$workspace/.opencode/agent"
    )
  done

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for path in "$dir"/*.md; do
      [[ -f "$path" ]] || continue
      name="${path##*/}"
      name="${name%.md}"
      [[ -n "$name" && "$name" != *$'\n'* ]] || continue
      printf '%s\n' "$name"
    done
  done
}

opencode_agent_names() {
  { opencode_builtin_agent_names; opencode_discovered_agent_names "$@"; } | LC_ALL=C sort -u
}

opencode_json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

opencode_workspace_id_for_start_dir() {
  local start_dir="$1"
  printf 'ws-%s\n' "$(printf '%s\n' "$start_dir" | sha256_cmd | cut -c1-32)"
}

opencode_default_config_template() {
  local agent first=true
  cat <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "*": "allow"
  },
  "default_agent": "build",
  "agent": {
EOF
  while IFS= read -r agent; do
    if $first; then
      first=false
    else
      printf ',\n'
    fi
    printf '    '
    opencode_json_string "$agent"
    printf ': {\n      "permission": {\n        "*": "allow"\n      }\n    }'
  done < <(opencode_agent_names "$@")
  cat <<'EOF'

  }
}
EOF
}

opencode_config_is_legacy() {
  local config="$1" current legacy
  IFS= read -r -d '' current < "$config" || true
  IFS= read -r -d '' legacy <<'EOF' || true
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
EOF

  [[ "$current" == "$legacy" ]]
}

opencode_config_is_bad_permission_template() {
  local config="$1" current bad_template
  IFS= read -r -d '' current < "$config" || true
  IFS= read -r -d '' bad_template <<'EOF' || true
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow",
  "default_agent": "build",
  "agent": {
    "build": {
      "permission": "allow"
    },
    "plan": {
      "permission": "allow"
    },
    "general": {
      "permission": "allow"
    },
    "explore": {
      "permission": "allow"
    }
  }
}
EOF

  [[ "$current" == "$bad_template" ]]
}

ensure_opencode_config() {
  local config="$TOKENS_DIR/opencode.jsonc"
  [[ -e "$config" && ! -f "$config" ]] \
    && err "OpenCode config path exists but is not a file: $config"
  if [[ ! -f "$config" ]]; then
    opencode_default_config_template "$@" > "$config"
    chmod 600 "$config"
  elif opencode_config_is_legacy "$config" || opencode_config_is_bad_permission_template "$config"; then
    opencode_default_config_template "$@" > "$config"
    chmod 600 "$config"
  else
    log "OpenCode config exists at $config; custom edits preserved. For yolo mode, use permission: {\"*\":\"allow\"} and agent entries with permission: {\"*\":\"allow\"}."
  fi
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

# Install OpenCode CLI via the native installer.
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/node/.opencode/bin:$PATH"

USER root
# fd-find installs as fdfind on Debian; symlink to the conventional name.
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd
RUN mkdir -p /etc/opencode
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
  parse_args "$@"
  local mode="$PARSED_MODE" cwd="$PARSED_CWD" workspace_arg="$PARSED_WORKSPACE"
  local workspace
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  local start_dir="$workspace"
  local cname
  cname="$(container_name "$workspace")"

  if [[ "$mode" == "opencode" ]]; then
    start_dir="$(validate_opencode_start_dir "$workspace" "$cwd")"
    mkdir -p "$TOKENS_DIR"
    ensure_opencode_config "$workspace" "$start_dir"
  fi

  local exists=false
  if container_exists "$cname"; then
    ensure_container_mode "$cname" "$mode"
    if [[ "$mode" == "opencode" ]]; then
      ensure_opencode_mounts "$cname" "$workspace"
    fi
    exists=true
  fi

  if container_running "$cname"; then
    : # already running, fall through to attach
  elif $exists; then
    log "Restarting stopped container '$cname'..."
    docker start "$cname"
  else
    build_image false || true

    mkdir -p "$workspace" "$TOKENS_DIR"

    # Config mounts differ between modes:
    #   claude:  ~/.claude (config/history) and ~/.claude.json
    #   copilot: ~/.copilot
    #   gemini:  ~/.gemini
    #   opencode: ~/.config/opencode, ~/.local/share/opencode, and
    #     AIND's shared OpenCode config mounted read-only under /etc/opencode.
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
      opencode)
        mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                 "$HOME/.cache/opencode" "$HOME/.local/state/opencode"
        chmod 700 "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                  "$HOME/.cache/opencode" "$HOME/.local/state/opencode"
        local opencode_config="$TOKENS_DIR/opencode.jsonc"
        config_mounts=(
          -v "$HOME/.config/opencode:/home/node/.config/opencode"
          -v "$HOME/.local/share/opencode:/home/node/.local/share/opencode"
          -v "$HOME/.cache/opencode:/home/node/.cache/opencode"
          -v "$HOME/.local/state/opencode:/home/node/.local/state/opencode"
          -v "$opencode_config:/etc/opencode/opencode.jsonc:ro"
        ) ;;
      *)
        local settings_local="$TOKENS_DIR/${cname}.claude_settings_local.json"
        [[ -f "$settings_local" ]] || echo '{}' > "$settings_local"
        config_mounts=(
          -v "$HOME/.claude:/home/node/.claude"
          -v "$HOME/.claude.json:/home/node/.claude.json"
          -v "$settings_local:/home/node/.claude/settings.local.json"
        ) ;;
    esac

    log "Starting container '$cname' (workspace: $workspace)..."
    # USER_UID/USER_GID: passed to the entrypoint so it can remap the node user.
    # WORKSPACE: mounted workspace root, available inside the container.
    # GIT_*: set the git identity for all commits made by the AI tool.
    # GH_TOKEN/GITLAB_TOKEN: injected at exec time (not run time) so a
    #   stop/start cycle picks up updated token files without needing docker rm.
    # workspace mount: uses the exact host path so paths match on both sides.
    # aind.mode label: detects accidental reuse of a workspace container with
    #   a different AI tool mode on future runs.
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
      --label "aind.mode=$mode" \
      --name "$cname" \
      -e USER_UID="$(id -u)" \
      -e USER_GID="$(id -g)" \
      -e WORKSPACE="$workspace" \
      -e GIT_AUTHOR_NAME="$(case "$mode" in copilot) echo 'GitHub Copilot';; gemini) echo 'Gemini CLI';; opencode) echo 'OpenCode';; *) echo 'Claude Code';; esac)" \
      -e GIT_AUTHOR_EMAIL="$(case "$mode" in copilot) echo 'noreply@github.com';; gemini) echo 'noreply@google.com';; opencode) echo 'noreply@opencode.ai';; *) echo 'noreply@anthropic.com';; esac)" \
      -e GIT_COMMITTER_NAME="$(case "$mode" in copilot) echo 'GitHub Copilot';; gemini) echo 'Gemini CLI';; opencode) echo 'OpenCode';; *) echo 'Claude Code';; esac)" \
      -e GIT_COMMITTER_EMAIL="$(case "$mode" in copilot) echo 'noreply@github.com';; gemini) echo 'noreply@google.com';; opencode) echo 'noreply@opencode.ai';; *) echo 'noreply@anthropic.com';; esac)" \
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
    opencode) mode_icon="🔓" ;;
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
  #   gemini:  registers git credential helpers, then runs gemini --yolo.
  #   opencode: registers git credential helpers, then runs the OpenCode TUI.
  #             Permission bypass for the TUI is configured via /etc/opencode/opencode.jsonc;
  #             --dangerously-skip-permissions is only valid for `opencode run`.
  local tmux_cmd
  case "$mode" in
    copilot) tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; copilot --allow-all; exec zsh" ;;
    gemini)  tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; gemini --yolo; exec zsh" ;;
    opencode) tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; opencode; exec zsh" ;;
    *)       tmux_cmd="gh auth setup-git 2>/dev/null; glab auth setup-git 2>/dev/null; claude --dangerously-skip-permissions; exec zsh" ;;
  esac

  local exec_env=(
    -e TERM="${TERM:-xterm-256color}"
    -e LANG="${LANG:-C.UTF-8}"
    -e LC_ALL="${LC_ALL:-C.UTF-8}"
    -e HOME=/home/node
    -e WORKSPACE="$workspace"
    -e AIND_START_DIR="$start_dir"
    -e GH_TOKEN="$gh_token"
    -e GITLAB_TOKEN="$gitlab_token"
  )
  if [[ "$mode" == "opencode" ]]; then
    # OpenCode scopes sessions by a random workspace_id generated at server start.
    # We pin it to a deterministic hash of the OpenCode start directory so the
    # same directory always gets the same workspace_id — both inside and outside
    # the container.
    # To see the same sessions on the host, export the value printed below.
    local opencode_workspace_id
    opencode_workspace_id="$(opencode_workspace_id_for_start_dir "$start_dir")"
    log "OpenCode start directory: $start_dir"
    log "OpenCode workspace ID for start directory: $opencode_workspace_id"
    log "  → to share sessions with the host, run on the host:"
    log "      export OPENCODE_WORKSPACE_ID=$opencode_workspace_id"

    # OpenCode config does not currently expose LSP tool activation.
    exec_env+=(
      -e XDG_CONFIG_HOME=/home/node/.config
      -e XDG_DATA_HOME=/home/node/.local/share
      -e XDG_CACHE_HOME=/home/node/.cache
      -e XDG_STATE_HOME=/home/node/.local/state
      -e OPENCODE_EXPERIMENTAL_LSP_TOOL=true
      -e OPENCODE_WORKSPACE_ID="$opencode_workspace_id"
    )
  fi

  # Forward terminal settings so the UI renders correctly inside the container.
  # Double-quoting the bash -c string lets the host shell expand $tmux_cmd now,
  # while \$AIND_START_DIR is deferred to the container's bash via the escaped $.
  docker exec -it --user node \
    "${exec_env[@]}" \
    "$cname" bash -c "
    : \"\${AIND_START_DIR:=\$WORKSPACE}\"
    if ! tmux has-session -t main 2>/dev/null; then
      tmux_env=( -e \"WORKSPACE=\$WORKSPACE\" -e \"AIND_START_DIR=\$AIND_START_DIR\" )
      if [[ -n \"\${OPENCODE_WORKSPACE_ID:-}\" ]]; then
        # Pass OpenCode env through tmux so new sessions receive it even if a
        # tmux server already exists with older environment state.
        tmux_env+=( -e \"HOME=\$HOME\" )
        tmux_env+=( -e \"XDG_CONFIG_HOME=\$XDG_CONFIG_HOME\" )
        tmux_env+=( -e \"XDG_DATA_HOME=\$XDG_DATA_HOME\" )
        tmux_env+=( -e \"XDG_CACHE_HOME=\$XDG_CACHE_HOME\" )
        tmux_env+=( -e \"XDG_STATE_HOME=\$XDG_STATE_HOME\" )
        tmux_env+=( -e \"OPENCODE_EXPERIMENTAL_LSP_TOOL=\$OPENCODE_EXPERIMENTAL_LSP_TOOL\" )
        tmux_env+=( -e \"OPENCODE_WORKSPACE_ID=\$OPENCODE_WORKSPACE_ID\" )
      fi
      tmux new-session -s main -c \"\$AIND_START_DIR\" \"\${tmux_env[@]}\" \"${tmux_cmd}\"
    else
      if [[ -n \"\${OPENCODE_WORKSPACE_ID:-}\" ]]; then
        printf '[aind] OpenCode tmux session already exists; exit or kill it, then re-run aind, to pick up start directory, workspace ID, or config changes.\\n' >&2
      fi
      tmux attach -t main
    fi
  "
}

# Stop the container for the given workspace without removing it, so that its
# writable layer (installed packages, etc.) survives and is reused on the next
# start. To fully remove the container use the rm command.
cmd_stop() {
  parse_args "$@"
  local workspace_arg="$PARSED_WORKSPACE"
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
  parse_args "$@"
  local workspace_arg="$PARSED_WORKSPACE"
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
  parse_args "$@"
  local workspace_arg="$PARSED_WORKSPACE"
  if [[ -z "$workspace_arg" ]]; then
    docker ps -a --filter "name=^${CONTAINER_PREFIX}"
  else
    local cname
    cname="$(container_name "$workspace_arg")"
    docker ps -a --filter "name=^${cname}$"
  fi
}

cmd_logs() {
  parse_args "$@"
  local workspace_arg="$PARSED_WORKSPACE"
  local workspace cname
  workspace="$(resolve_path "${workspace_arg:-$PWD}")"
  cname="$(container_name "$workspace")"
  docker logs --tail 50 -f "$cname"
}

cmd_restart() {
  parse_args "$@"
  if [[ "$PARSED_MODE" == "opencode" ]]; then
    local workspace
    workspace="$(resolve_path "${PARSED_WORKSPACE:-$PWD}")"
    validate_opencode_start_dir "$workspace" "$PARSED_CWD" >/dev/null
  fi
  cmd_stop "$@"
  cmd_start "$@"
}

# -- dispatch -----------------------------------------------------------------

usage() {
  echo "Usage: $0 {build [--force]|start|stop|restart|rm|status|logs|version|help} [--copilot|--gemini|--opencode] [--cwd|-cwd <relative-subdir>] [workspace]"
  echo
  echo "  build   [--force]                        Rebuild image if embedded content changed (--force always rebuilds)"
  echo "  start   [--copilot|--gemini|--opencode] [--cwd|-cwd <relative-subdir>] [workspace] Attach to session or start a new one (default: \$PWD)"
  echo "  stop    [--copilot|--gemini|--opencode] [workspace] Stop the container, preserving its state (default: \$PWD)"
  echo "  restart [--copilot|--gemini|--opencode] [--cwd|-cwd <relative-subdir>] [workspace] Stop then start the container (default: \$PWD)"
  echo "  rm      [--copilot|--gemini|--opencode] [workspace] Remove the container (default: \$PWD)"
  echo "  status  [--copilot|--gemini|--opencode] [workspace] Show container status; no arg lists all (default: \$PWD)"
  echo "  logs    [--copilot|--gemini|--opencode] [workspace] Tail container logs (default: \$PWD)"
  echo "  version                                  Print the script version"
  echo "  help                                     Print this help message"
  echo
  echo "  --copilot                       Use GitHub Copilot instead of Claude."
  echo "  --gemini                        Use Gemini CLI instead of Claude."
  echo "  --opencode                      Use OpenCode instead of Claude."
  echo "  --cwd, -cwd <relative-subdir>    In --opencode mode, start OpenCode in an existing relative workspace subdirectory."
  echo "  --cwd=..., -cwd=...              Same as above; mount root and container name still use [workspace]."
}

if [[ "${AIND_SOURCE_ONLY:-}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

case "${1:-}" in
  --help|-h|help) usage; exit 0 ;;
esac

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
