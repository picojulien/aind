#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
RAW_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aind-parse-test.XXXXXX")"
TMP_DIR="$(cd -- "$RAW_TMP_DIR" && pwd -P)"
ORIGINAL_PATH="$PATH"
BASH_BIN="$(command -v bash)"
trap 'rm -rf "$TMP_DIR"' EXIT

AIND_SOURCE_ONLY=1 source "$ROOT_DIR/aind.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  [[ "$actual" == "$expected" ]] || fail "$desc: expected '$expected', got '$actual'"
  pass "$desc"
}

assert_array_len() {
  local expected="$1" actual="$2" desc="$3"
  [[ "$actual" == "$expected" ]] || fail "$desc: expected $expected item(s), got $actual"
  pass "$desc"
}

assert_file_has_line() {
  local file="$1" expected="$2" desc="$3" line
  while IFS= read -r line; do
    if [[ "$line" == "$expected" ]]; then
      pass "$desc"
      return 0
    fi
  done < "$file"
  fail "$desc: expected line '$expected' in $file"
}

expect_failure() {
  local desc="$1" expected_stderr="$2" stderr
  shift 2
  stderr="$TMP_DIR/stderr"
  if ( "$@" ) 2>"$stderr"; then
    fail "$desc: expected failure"
  fi
  local output
  output="$(<"$stderr")"
  case "$output" in
    *"$expected_stderr"*) pass "$desc" ;;
    *) fail "$desc: expected stderr containing '$expected_stderr', got '$output'" ;;
  esac
}

parse_args --opencode workspace --cwd subdir
assert_eq "opencode" "$PARSED_MODE" "--cwd sets OpenCode mode"
assert_eq "workspace" "$PARSED_WORKSPACE" "--cwd preserves workspace"
assert_eq "subdir" "$PARSED_CWD" "--cwd parses separate value"

parse_args --opencode workspace -cwd subdir
assert_eq "workspace" "$PARSED_WORKSPACE" "-cwd preserves workspace"
assert_eq "subdir" "$PARSED_CWD" "-cwd parses separate value"

parse_args --opencode workspace --cwd=subdir
assert_eq "workspace" "$PARSED_WORKSPACE" "--cwd= preserves workspace"
assert_eq "subdir" "$PARSED_CWD" "--cwd= parses value"

parse_args --opencode workspace -cwd=subdir
assert_eq "workspace" "$PARSED_WORKSPACE" "-cwd= preserves workspace"
assert_eq "subdir" "$PARSED_CWD" "-cwd= parses value"

parse_args --opencode foo-bar
assert_eq "foo-bar" "$PARSED_WORKSPACE" "hyphenated workspace parses as positional"
assert_eq "" "$PARSED_CWD" "hyphenated workspace does not set cwd"

parse_args --opencode workspace --cwd=./-bad
assert_eq "./-bad" "$PARSED_CWD" "equals form allows cwd beginning with dash after ./"

expect_failure "--cwd without --opencode fails" "can only be used with --opencode" parse_args --cwd subdir
expect_failure "unknown single-dash option fails" "Unknown option: -bad" parse_args --opencode -bad
expect_failure "-cwd separate dash argument fails" "requires a relative OpenCode start subdirectory" parse_args --opencode workspace -cwd -bad
expect_failure "--ro-mount without value fails" "--ro-mount requires a non-empty path" parse_args --ro-mount
expect_failure "--ro-mount empty separate value fails" "--ro-mount requires a non-empty path" parse_args --ro-mount ""
expect_failure "--ro-mount empty equals value fails" "--ro-mount requires a non-empty path" parse_args --ro-mount=
expect_failure "--rw-mount without value fails" "--rw-mount requires a non-empty path" parse_args --rw-mount
expect_failure "--rw-mount empty separate value fails" "--rw-mount requires a non-empty path" parse_args --rw-mount ""
expect_failure "--rw-mount empty equals value fails" "--rw-mount requires a non-empty path" parse_args --rw-mount=

mkdir -p "$TMP_DIR/empty-path"
for help_arg in --help -h help; do
  help_out="$TMP_DIR/help-${help_arg#-}.out"
  if ! PATH="$TMP_DIR/empty-path" "$BASH_BIN" "$ROOT_DIR/aind.sh" "$help_arg" >"$help_out"; then
    fail "$help_arg exits successfully without dependency checks"
  fi
  case "$(<"$help_out")" in
    Usage:*) pass "$help_arg prints usage without dependency checks" ;;
    *) fail "$help_arg should print usage" ;;
  esac
done

mkdir -p "$TMP_DIR/real/a/b" "$TMP_DIR/root" "$TMP_DIR/outside" "$TMP_DIR/empty-path"
ln -s "$TMP_DIR/real" "$TMP_DIR/link"
ln -s "$TMP_DIR/outside" "$TMP_DIR/root/out"
mkdir -p "$TMP_DIR/real/a/-bad"

parse_args --ro-mount "$TMP_DIR/real/a" workspace
assert_eq "workspace" "$PARSED_WORKSPACE" "--ro-mount preserves workspace"
assert_array_len 1 "${#PARSED_RO_MOUNTS[@]}" "--ro-mount parses separate value"
assert_eq "$TMP_DIR/real/a" "${PARSED_RO_MOUNTS[0]}" "--ro-mount stores resolved separate value"

parse_args --ro-mount="$TMP_DIR/real/a/b" workspace
assert_eq "workspace" "$PARSED_WORKSPACE" "--ro-mount= preserves workspace"
assert_array_len 1 "${#PARSED_RO_MOUNTS[@]}" "--ro-mount= parses value"
assert_eq "$TMP_DIR/real/a/b" "${PARSED_RO_MOUNTS[0]}" "--ro-mount= stores resolved value"

parse_args --opencode --ro-mount "$TMP_DIR/real/a" workspace --cwd b --ro-mount="$TMP_DIR/real/a/b"
assert_eq "opencode" "$PARSED_MODE" "multiple --ro-mount keeps mode"
assert_eq "workspace" "$PARSED_WORKSPACE" "multiple --ro-mount keeps workspace"
assert_eq "b" "$PARSED_CWD" "multiple --ro-mount keeps cwd"
assert_array_len 2 "${#PARSED_RO_MOUNTS[@]}" "multiple --ro-mount values parse"
assert_eq "$TMP_DIR/real/a" "${PARSED_RO_MOUNTS[0]}" "multiple --ro-mount first value stored"
assert_eq "$TMP_DIR/real/a/b" "${PARSED_RO_MOUNTS[1]}" "multiple --ro-mount second value stored"

parse_args --ro-mount "$TMP_DIR/link/a" --ro-mount "$TMP_DIR/real/a" workspace
assert_array_len 1 "${#PARSED_RO_MOUNTS[@]}" "equivalent --ro-mount paths deduplicate"
assert_eq "$TMP_DIR/real/a" "${PARSED_RO_MOUNTS[0]}" "deduplicated --ro-mount path is resolved"

expect_failure "--ro-mount missing path fails" "Read-only mount path does not exist" parse_args --ro-mount "$TMP_DIR/missing-mount"

parse_args --rw-mount "$TMP_DIR/real/a" workspace
assert_eq "workspace" "$PARSED_WORKSPACE" "--rw-mount preserves workspace"
assert_array_len 1 "${#PARSED_RW_MOUNTS[@]}" "--rw-mount parses separate value"
assert_eq "$TMP_DIR/real/a" "${PARSED_RW_MOUNTS[0]}" "--rw-mount stores resolved separate value"

parse_args --rw-mount="$TMP_DIR/real/a/b" workspace
assert_eq "workspace" "$PARSED_WORKSPACE" "--rw-mount= preserves workspace"
assert_array_len 1 "${#PARSED_RW_MOUNTS[@]}" "--rw-mount= parses value"
assert_eq "$TMP_DIR/real/a/b" "${PARSED_RW_MOUNTS[0]}" "--rw-mount= stores resolved value"

parse_args --opencode --rw-mount "$TMP_DIR/real/a" workspace --cwd b --rw-mount="$TMP_DIR/real/a/b"
assert_eq "opencode" "$PARSED_MODE" "multiple --rw-mount keeps mode"
assert_eq "workspace" "$PARSED_WORKSPACE" "multiple --rw-mount keeps workspace"
assert_eq "b" "$PARSED_CWD" "multiple --rw-mount keeps cwd"
assert_array_len 2 "${#PARSED_RW_MOUNTS[@]}" "multiple --rw-mount values parse"
assert_eq "$TMP_DIR/real/a" "${PARSED_RW_MOUNTS[0]}" "multiple --rw-mount first value stored"
assert_eq "$TMP_DIR/real/a/b" "${PARSED_RW_MOUNTS[1]}" "multiple --rw-mount second value stored"

parse_args --rw-mount "$TMP_DIR/link/a" --rw-mount "$TMP_DIR/real/a" workspace
assert_array_len 1 "${#PARSED_RW_MOUNTS[@]}" "equivalent --rw-mount paths deduplicate"
assert_eq "$TMP_DIR/real/a" "${PARSED_RW_MOUNTS[0]}" "deduplicated --rw-mount path is resolved"

printf 'not a directory\n' > "$TMP_DIR/not-a-dir"
expect_failure "--rw-mount missing path fails" "Read-write mount path does not exist" parse_args --rw-mount "$TMP_DIR/missing-rw-mount"
expect_failure "--rw-mount non-directory path fails" "Read-write mount path is not a directory" parse_args --rw-mount "$TMP_DIR/not-a-dir"
expect_failure "same path cannot be read-only and read-write" "cannot be both --ro-mount and --rw-mount" parse_args --ro-mount "$TMP_DIR/real/a" --rw-mount "$TMP_DIR/link/a"
expect_failure "same path cannot be read-write and read-only" "cannot be both --ro-mount and --rw-mount" parse_args --rw-mount "$TMP_DIR/link/a" --ro-mount "$TMP_DIR/real/a"

(
  workspace="$TMP_DIR/docker-run-workspace"
  ro_mount="$TMP_DIR/real/a"
  rw_mount="$TMP_DIR/real/a/b"
  mkdir -p "$workspace"
  TOKENS_DIR="$TMP_DIR/docker-run-tokens"
  cname="$(container_name "$workspace")"
  mkdir -p "$TOKENS_DIR"
  printf token > "$TOKENS_DIR/${cname}.github_token"
  printf token > "$TOKENS_DIR/${cname}.gitlab_token"

  container_exists() { return 1; }
  container_running() { return 1; }
  build_image() { return 1; }
  docker() {
    case "$1" in
      info) return 1 ;;
      run) shift; printf '%s\n' "$@" > "$TMP_DIR/docker-run.args" ;;
      exec) return 0 ;;
      *) fail "unexpected docker command in docker run test: $*" ;;
    esac
  }

  cmd_start --ro-mount "$ro_mount" --rw-mount "$rw_mount" "$workspace"
  assert_file_has_line "$TMP_DIR/docker-run.args" "$ro_mount:$ro_mount:ro" "cmd_start docker run read-only mount includes :ro"
  assert_file_has_line "$TMP_DIR/docker-run.args" "$rw_mount:$rw_mount:rw" "cmd_start docker run read-write mount includes :rw"
)

(
  workspace="$TMP_DIR/existing-workspace"
  ro_mount="$TMP_DIR/real/a"
  mkdir -p "$workspace"

  container_exists() { return 0; }
  container_running() { fail "container_running should not be reached when requested read-only mount is absent"; }
  docker() {
    if [[ "$1" == "inspect" && "$2" == "--format" ]]; then
      case "$3" in
        *Config.Labels*) printf '<no value>\n' ;;
        *Mounts*) printf 'bind\t%s\t%s\ttrue\n' "$workspace" "$workspace" ;;
        *) fail "unexpected docker inspect format in missing mount test: $3" ;;
      esac
      return 0
    fi
    fail "unexpected docker command in missing mount test: $*"
  }

  expect_failure "existing container missing requested --ro-mount fails" "Remove and recreate it" cmd_start --ro-mount "$ro_mount" "$workspace"
)

(
  workspace="$TMP_DIR/existing-rw-workspace"
  rw_mount="$TMP_DIR/real/a"
  mkdir -p "$workspace"

  container_exists() { return 0; }
  container_running() { fail "container_running should not be reached when requested read-write mount is absent"; }
  docker() {
    if [[ "$1" == "inspect" && "$2" == "--format" ]]; then
      case "$3" in
        *Config.Labels*) printf '<no value>\n' ;;
        *Mounts*) printf 'bind\t%s\t%s\ttrue\n' "$workspace" "$workspace" ;;
        *) fail "unexpected docker inspect format in missing rw mount test: $3" ;;
      esac
      return 0
    fi
    fail "unexpected docker command in missing rw mount test: $*"
  }

  expect_failure "existing container missing requested --rw-mount fails" "Remove and recreate it" cmd_start --rw-mount "$rw_mount" "$workspace"
)

(
  workspace="$TMP_DIR/restart-existing-workspace"
  ro_mount="$TMP_DIR/real/a"
  mkdir -p "$workspace"

  container_exists() { return 0; }
  cmd_stop() { fail "cmd_restart should validate requested read-only mounts before stop"; }
  cmd_start() { fail "cmd_restart should validate requested read-only mounts before start"; }
  docker() {
    if [[ "$1" == "inspect" && "$2" == "--format" ]]; then
      case "$3" in
        *Config.Labels*) printf '<no value>\n' ;;
        *Mounts*) printf 'bind\t%s\t%s\ttrue\n' "$workspace" "$workspace" ;;
        *) fail "unexpected docker inspect format in restart missing mount test: $3" ;;
      esac
      return 0
    fi
    fail "unexpected docker command in restart missing mount test: $*"
  }

  expect_failure "restart validates missing requested --ro-mount before stop" "Remove and recreate it" cmd_restart --ro-mount "$ro_mount" "$workspace"
)

(
  workspace="$TMP_DIR/restart-existing-rw-workspace"
  rw_mount="$TMP_DIR/real/a"
  mkdir -p "$workspace"

  container_exists() { return 0; }
  cmd_stop() { fail "cmd_restart should validate requested read-write mounts before stop"; }
  cmd_start() { fail "cmd_restart should validate requested read-write mounts before start"; }
  docker() {
    if [[ "$1" == "inspect" && "$2" == "--format" ]]; then
      case "$3" in
        *Config.Labels*) printf '<no value>\n' ;;
        *Mounts*) printf 'bind\t%s\t%s\ttrue\n' "$workspace" "$workspace" ;;
        *) fail "unexpected docker inspect format in restart missing rw mount test: $3" ;;
      esac
      return 0
    fi
    fail "unexpected docker command in restart missing rw mount test: $*"
  }

  expect_failure "restart validates missing requested --rw-mount before stop" "Remove and recreate it" cmd_restart --rw-mount "$rw_mount" "$workspace"
)

start_direct="$(validate_opencode_start_dir "$TMP_DIR/link/a/b" "")"
start_cwd="$(validate_opencode_start_dir "$TMP_DIR/link/a" "b")"
id_direct="$(opencode_workspace_id_for_start_dir "$start_direct")"
id_cwd="$(opencode_workspace_id_for_start_dir "$start_cwd")"
assert_eq "$start_cwd" "$start_direct" "direct and -cwd start dirs canonicalize identically"
assert_eq "$id_cwd" "$id_direct" "direct and -cwd workspace IDs match"

(
  # Intentionally hide realpath/readlink to exercise resolve_path's pure-bash fallback.
  # shellcheck disable=SC2123
  PATH="$TMP_DIR/empty-path"

  parse_args --opencode "$TMP_DIR/link/a/b"
  fallback_workspace_direct="$(resolve_path "${PARSED_WORKSPACE:-$PWD}")"
  fallback_start_direct="$(validate_opencode_start_dir "$fallback_workspace_direct" "$PARSED_CWD")"
  assert_eq "$fallback_start_direct" "$fallback_workspace_direct" "pure-bash resolve_path existing workspace is physical"

  parse_args --opencode "$TMP_DIR/link/a" -cwd b
  fallback_workspace_cwd="$(resolve_path "${PARSED_WORKSPACE:-$PWD}")"
  fallback_start_cwd="$(validate_opencode_start_dir "$fallback_workspace_cwd" "$PARSED_CWD")"

  assert_eq "$fallback_start_cwd" "$fallback_start_direct" "pure-bash resolve_path direct and -cwd start dirs match"

  fallback_missing_before="$(resolve_path "$TMP_DIR/link/a/new-workspace")"
  fallback_missing_start_before="$(validate_opencode_start_dir "$fallback_missing_before" "")"
  assert_eq "$fallback_missing_before" "$fallback_missing_start_before" "pure-bash missing workspace start matches resolved path"
  PATH="$ORIGINAL_PATH" mkdir -p "$TMP_DIR/link/a/new-workspace"
  fallback_missing_after="$(resolve_path "$TMP_DIR/link/a/new-workspace")"
  assert_eq "$fallback_missing_after" "$fallback_missing_before" "pure-bash missing workspace remains stable after creation"
)

missing_workspace="$TMP_DIR/missing/workspace"
start_missing="$(validate_opencode_start_dir "$missing_workspace" "")"
assert_eq "$missing_workspace" "$start_missing" "missing no-cwd workspace is preserved"

start_dash_dir="$(validate_opencode_start_dir "$TMP_DIR/real/a" "./-bad")"
assert_eq "$TMP_DIR/real/a/-bad" "$start_dash_dir" "equals cwd can target dash-prefixed directory"

expect_failure "symlink cwd escape is rejected" "resolves outside the workspace" validate_opencode_start_dir "$TMP_DIR/root" out

mkdir -p "$TMP_DIR/git-parent/.git/objects" "$TMP_DIR/git-parent/.git/worktrees/leaf" "$TMP_DIR/git-parent/sub/worktree"
printf 'gitdir: %s\n' "$TMP_DIR/git-parent/.git/worktrees/leaf" > "$TMP_DIR/git-parent/sub/worktree/.git"
printf '../..\n' > "$TMP_DIR/git-parent/.git/worktrees/leaf/commondir"
printf '%s\n' "$TMP_DIR/git-parent/sub/worktree/.git" > "$TMP_DIR/git-parent/.git/worktrees/leaf/gitdir"

direct_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/git-parent/sub/worktree" "$TMP_DIR/git-parent/sub/worktree")"
assert_eq "$TMP_DIR/git-parent/.git" "$direct_git_mounts" "direct linked worktree mounts common git metadata"

direct_git_mount_args="$(opencode_git_metadata_mount_args "$TMP_DIR/git-parent/sub/worktree" "$TMP_DIR/git-parent/sub/worktree")"
assert_eq $'-v\n'"$TMP_DIR/git-parent/.git:$TMP_DIR/git-parent/.git" "$direct_git_mount_args" "direct linked worktree uses read-write same-path docker mount"

parent_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/git-parent" "$TMP_DIR/git-parent/sub/worktree")"
assert_eq "" "$parent_git_mounts" "parent workspace does not duplicate covered git metadata mount"

mkdir -p "$TMP_DIR/git-relative/.git/objects" "$TMP_DIR/git-relative/.git/worktrees/leaf" "$TMP_DIR/git-relative/worktree"
printf 'gitdir: ../.git/worktrees/leaf\n' > "$TMP_DIR/git-relative/worktree/.git"
printf '../..\n' > "$TMP_DIR/git-relative/.git/worktrees/leaf/commondir"
printf '../../../worktree/.git\n' > "$TMP_DIR/git-relative/.git/worktrees/leaf/gitdir"

relative_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/git-relative/worktree" "$TMP_DIR/git-relative/worktree")"
assert_eq "$TMP_DIR/git-relative/.git" "$relative_git_mounts" "relative linked worktree gitdir resolves to common metadata mount"

mkdir -p "$TMP_DIR/git-no-backlink/.git/objects" "$TMP_DIR/git-no-backlink/.git/worktrees/leaf" "$TMP_DIR/git-no-backlink/worktree"
printf 'gitdir: %s\n' "$TMP_DIR/git-no-backlink/.git/worktrees/leaf" > "$TMP_DIR/git-no-backlink/worktree/.git"
printf '../..\n' > "$TMP_DIR/git-no-backlink/.git/worktrees/leaf/commondir"
no_backlink_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/git-no-backlink/worktree" "$TMP_DIR/git-no-backlink/worktree")"
assert_eq "" "$no_backlink_mounts" "linked worktree without gitdir backlink gets no metadata mount"

mkdir -p "$TMP_DIR/git-wrong-backlink/.git/objects" "$TMP_DIR/git-wrong-backlink/.git/worktrees/leaf" "$TMP_DIR/git-wrong-backlink/worktree"
printf 'gitdir: %s\n' "$TMP_DIR/git-wrong-backlink/.git/worktrees/leaf" > "$TMP_DIR/git-wrong-backlink/worktree/.git"
printf '../..\n' > "$TMP_DIR/git-wrong-backlink/.git/worktrees/leaf/commondir"
printf '%s\n' "$TMP_DIR/other-worktree/.git" > "$TMP_DIR/git-wrong-backlink/.git/worktrees/leaf/gitdir"
wrong_backlink_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/git-wrong-backlink/worktree" "$TMP_DIR/git-wrong-backlink/worktree")"
assert_eq "" "$wrong_backlink_mounts" "linked worktree with wrong gitdir backlink gets no metadata mount"

mkdir -p "$TMP_DIR/separate-gitdir/.git/modules/sub/objects" "$TMP_DIR/separate-worktree"
printf 'gitdir: %s\n' "$TMP_DIR/separate-gitdir/.git/modules/sub" > "$TMP_DIR/separate-worktree/.git"
printf 'ref: refs/heads/main\n' > "$TMP_DIR/separate-gitdir/.git/modules/sub/HEAD"
printf '[core]\n\tworktree = %s\n' "$TMP_DIR/separate-worktree" > "$TMP_DIR/separate-gitdir/.git/modules/sub/config"
separate_gitdir_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/separate-worktree" "$TMP_DIR/separate-worktree")"
assert_eq "$TMP_DIR/separate-gitdir/.git/modules/sub" "$separate_gitdir_mounts" "separate gitdir with matching core.worktree mounts minimal metadata"

mkdir -p "$TMP_DIR/normal-repo/.git"
normal_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/normal-repo" "$TMP_DIR/normal-repo")"
assert_eq "" "$normal_git_mounts" "normal repo with in-workspace .git directory needs no metadata mount"

mkdir -p "$TMP_DIR/not-git"
non_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/not-git" "$TMP_DIR/not-git")"
assert_eq "" "$non_git_mounts" "non-git directory needs no metadata mount"

mkdir -p "$TMP_DIR/malicious-worktree" "$TMP_DIR/outside-home"
printf 'gitdir: %s\n' "$TMP_DIR/outside-home" > "$TMP_DIR/malicious-worktree/.git"
malicious_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/malicious-worktree" "$TMP_DIR/malicious-worktree")"
assert_eq "" "$malicious_git_mounts" "bogus outside gitdir target gets no metadata mount"

mkdir -p "$TMP_DIR/unrelated-worktree" "$TMP_DIR/external-repo/.git/objects"
printf 'gitdir: %s\n' "$TMP_DIR/external-repo/.git" > "$TMP_DIR/unrelated-worktree/.git"
printf 'ref: refs/heads/main\n' > "$TMP_DIR/external-repo/.git/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n' > "$TMP_DIR/external-repo/.git/config"
unrelated_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/unrelated-worktree" "$TMP_DIR/unrelated-worktree")"
assert_eq "" "$unrelated_git_mounts" "plausible unrelated external gitdir gets no metadata mount"

mkdir -p "$TMP_DIR/fake-local-worktree/local-gitdir" "$TMP_DIR/external-common/.git/objects"
printf 'gitdir: local-gitdir\n' > "$TMP_DIR/fake-local-worktree/.git"
printf 'ref: refs/heads/main\n' > "$TMP_DIR/fake-local-worktree/local-gitdir/HEAD"
printf '%s\n' "$TMP_DIR/fake-local-worktree/.git" > "$TMP_DIR/fake-local-worktree/local-gitdir/gitdir"
printf '%s\n' "$TMP_DIR/external-common/.git" > "$TMP_DIR/fake-local-worktree/local-gitdir/commondir"
printf 'ref: refs/heads/main\n' > "$TMP_DIR/external-common/.git/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n' > "$TMP_DIR/external-common/.git/config"
fake_local_common_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/fake-local-worktree" "$TMP_DIR/fake-local-worktree")"
assert_eq "" "$fake_local_common_mounts" "workspace-local fake gitdir cannot mount unrelated external commondir"

mkdir -p "$TMP_DIR/symlink-target/.git/objects" "$TMP_DIR/symlink-target/.git/worktrees/leaf" "$TMP_DIR/symlink-target/worktree" "$TMP_DIR/symlink-git-worktree"
printf 'gitdir: %s\n' "$TMP_DIR/symlink-target/.git/worktrees/leaf" > "$TMP_DIR/symlink-target/worktree/.git"
printf '../..\n' > "$TMP_DIR/symlink-target/.git/worktrees/leaf/commondir"
printf '%s\n' "$TMP_DIR/symlink-target/worktree/.git" > "$TMP_DIR/symlink-target/.git/worktrees/leaf/gitdir"
ln -s "$TMP_DIR/symlink-target/worktree/.git" "$TMP_DIR/symlink-git-worktree/.git"
symlink_git_mounts="$(opencode_git_metadata_mount_paths "$TMP_DIR/symlink-git-worktree" "$TMP_DIR/symlink-git-worktree")"
assert_eq "" "$symlink_git_mounts" "symlink .git file gets no metadata mount"

(
  TOKENS_DIR="$TMP_DIR/tokens"
  mkdir -p "$TOKENS_DIR"
  : > "$TOKENS_DIR/opencode.jsonc"

  # Invoked indirectly by ensure_opencode_mounts.
  # shellcheck disable=SC2329
  docker() {
    if [[ "${1:-}" != "inspect" || "${2:-}" != "--format" ]]; then
      return 1
    fi

    case "${3:-}" in
      *'.Type }} {{ .Destination }}'*)
        printf '%s\n' \
          'bind /home/node/.config/opencode' \
          'bind /home/node/.local/share/opencode' \
          'bind /home/node/.cache/opencode' \
          'bind /home/node/.local/state/opencode' \
          'bind /etc/opencode/opencode.jsonc'
        ;;
      *'.Type }}{{ "\t" }}'*)
        printf 'bind\t%s\t/etc/opencode/opencode.jsonc\tfalse\n' "$TOKENS_DIR/opencode.jsonc"
        ;;
      *)
        return 1
        ;;
    esac
  }

  expect_failure "existing OpenCode direct worktree requires git metadata mount" \
    "$TMP_DIR/git-parent/.git" \
    ensure_opencode_mounts "aind-test" "$TMP_DIR/git-parent/sub/worktree" "$TMP_DIR/git-parent/sub/worktree"
)
