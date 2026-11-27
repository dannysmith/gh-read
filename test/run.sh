#!/bin/sh
# Runs every case in test/cases.sh against ./gh-read, once for each shell given.
# Needs no network or GitHub auth: gh-read execs test/fake-gh instead of gh.
#
# Usage: test/run.sh [shell ...]
#   test/run.sh                       # /bin/sh only
#   test/run.sh /bin/sh dash bash     # each shell runs gh-read in turn
#   test/run.sh 'busybox sh'          # a shell given as several words
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The caller's own gh settings must not leak into the cases.
unset GH_HOST
export GH_PATH="$root/test/fake-gh"
export FAKE_GH_LOG="$tmp/argv"

case_env=''

# Runs gh-read with the given arguments under $test_sh, recording its exit code
# in $rc, its stdout and stderr in $tmp/out and $tmp/err.
run_gh_read() {
  rm -f "$FAKE_GH_LOG"
  case_desc=$(printf "'%s' " "$@")
  # $case_env and $test_sh are split into words on purpose.
  # shellcheck disable=SC2086
  env $case_env $test_sh "$root/gh-read" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

pass() { passed=$((passed + 1)); }

fail() {
  failed=$((failed + 1))
  printf '\nFAIL (%s): %s\n  gh read %s\n' "$test_sh" "$1" "$case_desc"
  [ -z "$case_env" ] || printf '  env: %s\n' "$case_env"
  [ ! -s "$tmp/err" ] || printf '  stderr: %s\n' "$(cat "$tmp/err")"
  [ ! -s "$tmp/out" ] || printf '  stdout: %s\n' "$(cat "$tmp/out")"
  [ ! -f "$FAKE_GH_LOG" ] || printf '  gh got: %s\n' "$(tr '\0' ' ' <"$FAKE_GH_LOG")"
  [ ! -f "$tmp/want" ] || printf '  wanted: %s\n' "$(tr '\0' ' ' <"$tmp/want")"
}

# Expects gh-read to exit with $1, to have called gh with exactly the arguments
# in $tmp/want, and to have printed nothing of its own.
expect_call() {
  want_rc=$1
  shift
  run_gh_read "$@"
  if [ "$rc" -ne "$want_rc" ]; then
    fail "exit $rc, wanted $want_rc"
  elif [ ! -f "$FAKE_GH_LOG" ]; then
    fail "gh was not called"
  elif ! cmp -s "$tmp/want" "$FAKE_GH_LOG"; then
    fail "gh got the wrong arguments"
  elif [ -s "$tmp/out" ] || [ -s "$tmp/err" ]; then
    fail "gh read printed something itself"
  else
    pass
  fi
  rm -f "$tmp/want"
}

# allow <args>: a REST read. gh gets exactly `api --method GET <args>`.
allow() {
  printf '%s\0' api --method GET "$@" >"$tmp/want"
  expect_call 0 "$@"
}

# allow_graphql <args>: a GraphQL query. gh gets exactly `api <args>`.
allow_graphql() {
  printf '%s\0' api "$@" >"$tmp/want"
  expect_call 0 "$@"
}

# passes_exit_code <code> <args>: an allowed REST read where gh exits with
# <code>, which gh read must pass through.
passes_exit_code() {
  code=$1
  shift
  printf '%s\0' api --method GET "$@" >"$tmp/want"
  saved_env=$case_env
  case_env="$case_env FAKE_GH_EXIT=$code"
  expect_call "$code" "$@"
  case_env=$saved_env
}

# deny <reason> <args>: refused. Exit 2, gh never called, nothing on stdout,
# and one line on stderr starting "gh read: " that contains <reason>.
deny() {
  reason=$1
  shift
  run_gh_read "$@"
  if [ "$rc" -ne 2 ]; then
    fail "exit $rc, wanted 2"
  elif [ -f "$FAKE_GH_LOG" ]; then
    fail "gh was called"
  elif [ -s "$tmp/out" ]; then
    fail "printed to stdout"
  elif [ "$(($(wc -l <"$tmp/err")))" -ne 1 ]; then
    fail "stderr should be exactly one line"
  elif ! grep -q '^gh read: ' "$tmp/err"; then
    fail "stderr should start with 'gh read: '"
  elif ! grep -qF -e "$reason" "$tmp/err"; then
    fail "stderr should contain: $reason"
  else
    pass
  fi
}

# shows_help <args>: prints usage to stdout and exits 0 without calling gh.
shows_help() {
  run_gh_read "$@"
  if [ "$rc" -ne 0 ]; then
    fail "exit $rc, wanted 0"
  elif [ -f "$FAKE_GH_LOG" ]; then
    fail "gh was called"
  elif ! grep -q 'Usage: gh read' "$tmp/out"; then
    fail "stdout should contain 'Usage: gh read'"
  elif [ -s "$tmp/err" ]; then
    fail "printed to stderr"
  else
    pass
  fi
}

# with_env 'NAME=value ...' <helper> <args>: runs one case with extra
# environment variables. Values can't contain spaces.
with_env() {
  case_env=$1
  shift
  "$@"
  case_env=''
}

[ $# -gt 0 ] || set -- /bin/sh

total_failed=0
for test_sh do
  passed=0
  failed=0
  . "$root/test/cases.sh"
  printf '%s: %d passed, %d failed\n' "$test_sh" "$passed" "$failed"
  total_failed=$((total_failed + failed))
done

[ "$total_failed" -eq 0 ]
