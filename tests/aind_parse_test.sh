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
