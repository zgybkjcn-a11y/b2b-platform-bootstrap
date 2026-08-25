#!/usr/bin/env bash
#
# SHA256SUMS is update.sh's integrity gate: it downloads the control files,
# runs `sha256sum -c SHA256SUMS`, and aborts the whole update if the check
# fails. A manifest left stale by an unrelated edit therefore breaks every
# deployment's ability to update -- so keep it in lockstep with the tree.

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

cd "$REPO_ROOT"

status=0
out=$(sha256sum -c SHA256SUMS 2>&1) || status=$?
if ((status != 0)); then
  printf '  FAIL - SHA256SUMS does not match the committed files\n' >&2
  printf '%s\n' "$out" | sed 's/^/           /' >&2
  printf '         regenerate with:\n' >&2
  printf '           sha256sum b2b-platform update.sh install.sh compose.yml \\\n' >&2
  printf '             Caddyfile.domain Caddyfile.ip > SHA256SUMS\n' >&2
  exit 1
fi
ok "SHA256SUMS matches every committed control file"

# Derive the expected file set from update.sh's own download list so the
# two cannot silently drift apart. A control file added to update.sh but
# missing from the manifest would ship unverified.
declared=$(sed -n 's/^for file in \(.*\); do$/\1/p' update.sh | head -1)
[[ -n $declared ]] || fail "could not parse the control-file list out of update.sh"

# SHA256SUMS cannot contain its own hash.
# shellcheck disable=SC2086
want=$(printf '%s\n' $declared | grep -vx SHA256SUMS | sort | tr '\n' ' ')
have=$(awk '{print $2}' SHA256SUMS | sort | tr '\n' ' ')

assert_equals "$have" "$want" \
  "manifest covers exactly the files update.sh verifies"
