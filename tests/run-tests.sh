#!/usr/bin/env bash
#
# Runs every tests/test_*.sh in its own process.
#
# Per-test exit-code contract:
#   0  -> passed
#   77 -> skipped (docker unavailable)
#   *  -> failed

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

pass=0
skipped=0
failures=0
failed_names=()

for test_file in "$TEST_DIR"/test_*.sh; do
  [[ -e $test_file ]] || continue
  name=$(basename "$test_file")
  printf '\n== %s\n' "$name"

  bash "$test_file"
  case $? in
    0)  pass=$((pass + 1)) ;;
    77) skipped=$((skipped + 1)) ;;
    *)  failures=$((failures + 1)); failed_names+=("$name") ;;
  esac
done

printf '\n---------------------------------------------------------\n'
printf 'passed %d   skipped %d   failed %d\n' "$pass" "$skipped" "$failures"

if ((failures > 0)); then
  printf 'failing: %s\n' "${failed_names[*]}"
  exit 1
fi
