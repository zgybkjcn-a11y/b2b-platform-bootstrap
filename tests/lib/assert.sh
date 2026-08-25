#!/usr/bin/env bash
# shellcheck shell=bash
#
# Minimal assertion helpers shared by tests/test_*.sh.
#
# Exit-code contract for a test script:
#   0  -> passed
#   77 -> skipped (autotools convention; used when docker is unavailable)
#   *  -> failed

SKIP_EXIT=77

ok()   { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s\n' "$1" >&2; exit 1; }
skip() { printf '  SKIP - %s\n' "$1"; exit "$SKIP_EXIT"; }

assert_contains() {
  local haystack=$1 needle=$2 desc=$3
  case $haystack in
    *"$needle"*) ok "$desc" ;;
    *)
      printf '  FAIL - %s\n' "$desc" >&2
      printf '         expected to find: %s\n' "$needle" >&2
      printf '         actual output:\n' >&2
      printf '%s\n' "$haystack" | sed 's/^/           /' >&2
      exit 1
      ;;
  esac
}

assert_equals() {
  local actual=$1 expected=$2 desc=$3
  if [[ $actual == "$expected" ]]; then
    ok "$desc"
  else
    printf '  FAIL - %s\n' "$desc" >&2
    printf '         expected: %s\n' "$expected" >&2
    printf '         actual:   %s\n' "$actual" >&2
    exit 1
  fi
}

# Tests that drive real containers call this first so the suite degrades to
# SKIP rather than FAIL on machines without docker.
require_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker is not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon is not reachable"
}
