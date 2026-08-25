#!/usr/bin/env bash
#
# `docker compose config -q` on compose.yml.
#
# Catches YAML errors, bad service references and unresolvable variable
# interpolation before they reach a deployment. update.sh runs the same
# check against the freshly installed control files and rolls back if it
# fails, so a broken compose.yml blocks all updates.
#
# Requires docker; skips otherwise.

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

require_docker

env_file=$(mktemp "${TMPDIR:-/tmp}/b2b-compose-env.XXXXXX")
trap 'rm -f "$env_file"' EXIT

# Placeholder values only -- config validation never connects to anything.
cat > "$env_file" <<'EOF'
APP_VERSION=v0.0.0-test
DEPLOYMENT_MODE=ip
PUBLIC_HOST=127.0.0.1
PUBLIC_HTTP_PORT=51267
PUBLIC_HTTPS_HOST=127.0.0.1
PUBLIC_HTTPS_PORT=44443
PUBLIC_ORIGIN=http://127.0.0.1:51267
SESSION_COOKIE_SECURE=false
POSTGRES_DB=b2b_platform
POSTGRES_USER=b2b_platform_admin
POSTGRES_PASSWORD=placeholder
POSTGRES_APP_USER=b2b_platform_app
POSTGRES_APP_PASSWORD=placeholder
MINIO_ROOT_USER=b2b_minio
MINIO_ROOT_PASSWORD=placeholder
BACKUP_SERVICE_TOKEN=placeholder
BACKUP_ENCRYPTION_KEY=placeholder
TENANT_SETTINGS_ENCRYPTION_KEYS=v1:placeholder
TENANT_SETTINGS_ACTIVE_KEY_ID=v1
EOF

status=0
out=$(docker compose \
  --project-directory "$REPO_ROOT" \
  --env-file "$env_file" \
  -f "$REPO_ROOT/compose.yml" \
  config -q 2>&1) || status=$?

if ((status != 0)); then
  printf '  FAIL - compose.yml failed validation\n' >&2
  printf '%s\n' "$out" | sed 's/^/           /' >&2
  exit 1
fi
ok "compose.yml passes docker compose config"

# The ordering regression only exists because caddy gates on web being
# healthy. Pin both halves of that contract so a future edit that drops
# either one is caught here rather than in production.
rendered=$(docker compose \
  --project-directory "$REPO_ROOT" \
  --env-file "$env_file" \
  -f "$REPO_ROOT/compose.yml" \
  config 2>/dev/null)

assert_contains "$rendered" "service_healthy" \
  "compose.yml still uses service_healthy conditions"

printf '%s' "$rendered" | grep -A20 '^  web:' | grep -q 'healthcheck' \
  || fail "the web service lost its healthcheck -- update ordering depends on it"
ok "the web service declares a healthcheck"
