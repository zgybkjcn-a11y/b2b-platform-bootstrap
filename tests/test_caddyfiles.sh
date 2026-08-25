#!/usr/bin/env bash
#
# `caddy validate` on both Caddyfile templates.
#
# This guards a defect that has already bitten once: a template whose block
# was written on a single line ("handle @api { reverse_proxy api:31001 }")
# is rejected by Caddy 2.10 with "Unexpected next token after '{' on same
# line", which put the proxy into a restart loop and failed installation.
#
# Requires docker; skips otherwise.

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

require_docker

for template in Caddyfile.ip Caddyfile.domain; do
  status=0
  out=$(docker run --rm \
    -e PUBLIC_HOST=example.test \
    -v "$REPO_ROOT/$template:/etc/caddy/Caddyfile:ro" \
    caddy:2.10-alpine \
    caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile 2>&1) || status=$?

  if ((status != 0)); then
    printf '  FAIL - %s is not a valid Caddyfile\n' "$template" >&2
    printf '%s\n' "$out" | sed 's/^/           /' >&2
    exit 1
  fi
  ok "$template passes caddy validate"
done
