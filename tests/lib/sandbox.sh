#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds a throwaway $INSTALL_DIR that satisfies every check performed by
# `b2b-platform doctor`, plus stub docker/curl/id binaries on a private
# bin directory.
#
# Usage:
#   . tests/lib/sandbox.sh
#   sandbox_create v0.1.7      # sets SANDBOX and STUB_BIN
#
# sandbox_create deliberately does NOT export INSTALL_DIR or mutate PATH.
# The caller passes them per-invocation, so tests that need a real docker
# are never affected by the stubs.
#
# Requires REPO_ROOT to be set by the caller.

sandbox_create() {
  local old_version=${1:?sandbox_create needs the pre-upgrade version} key

  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/b2b-sandbox.XXXXXX")
  STUB_BIN=$SANDBOX/bin
  mkdir -p "$STUB_BIN"

  # Install the real committed artefacts, the same way update.sh does, so
  # the tests exercise the shipped scripts rather than a fixture copy.
  install -m 0755 "$REPO_ROOT/b2b-platform" "$SANDBOX/b2b-platform"
  install -m 0755 "$REPO_ROOT/update.sh"    "$SANDBOX/update.sh"
  install -m 0644 "$REPO_ROOT/compose.yml"  "$SANDBOX/compose.yml"
  install -m 0644 "$REPO_ROOT/Caddyfile.ip" "$SANDBOX/Caddyfile.ip"
  install -m 0644 "$REPO_ROOT/Caddyfile.ip" "$SANDBOX/Caddyfile"

  # tenant_encryption_check() requires the active key to base64-decode to
  # exactly 32 bytes. 32 zero bytes is a test constant, not a secret, and
  # is useless against any real deployment.
  key=$(head -c 32 /dev/zero | base64 | tr -d '\n')

  cat > "$SANDBOX/.env" <<EOF
APP_VERSION=$old_version
DEPLOYMENT_MODE=ip
PUBLIC_HOST=127.0.0.1
PUBLIC_HTTP_PORT=51267
PUBLIC_HTTPS_HOST=127.0.0.1
PUBLIC_HTTPS_PORT=44443
PUBLIC_ORIGIN=http://127.0.0.1:51267
SESSION_COOKIE_SECURE=false
POSTGRES_DB=b2b_platform
POSTGRES_USER=b2b_platform_admin
POSTGRES_PASSWORD=test-not-a-secret
POSTGRES_APP_USER=b2b_platform_app
POSTGRES_APP_PASSWORD=test-not-a-secret
MINIO_ROOT_USER=b2b_minio
MINIO_ROOT_PASSWORD=test-not-a-secret
BACKUP_SERVICE_TOKEN=test-not-a-secret
BACKUP_ENCRYPTION_KEY=test-not-a-secret
TENANT_SETTINGS_ENCRYPTION_KEYS=v1:$key
TENANT_SETTINGS_ACTIVE_KEY_ID=v1
AUTH_EMAIL_FROM=
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=true
SMTP_USER=
SMTP_PASSWORD=
EOF

  # doctor() asserts the mode is exactly 600.
  chmod 0600 "$SANDBOX/.env"

  local stub
  for stub in docker curl id; do
    install -m 0755 "$REPO_ROOT/tests/stubs/$stub" "$STUB_BIN/$stub"
  done
}

sandbox_destroy() {
  [[ -n ${SANDBOX:-} && -d ${SANDBOX:-} ]] && rm -rf "$SANDBOX"
  return 0
}

# Convenience wrapper: run a control script against the sandbox with the
# stubs in front of PATH.
#
# BOOTSTRAP_BASE defaults to the repository working tree, so the scripts
# under test "download" the artefacts of the current commit. Set
# SANDBOX_BOOTSTRAP_BASE to point at a fixture directory instead, for tests
# that need release metadata the repository does not carry.
sandbox_run() {
  local script=$1; shift
  (
    cd "$SANDBOX" || exit 1
    INSTALL_DIR=$SANDBOX \
    BOOTSTRAP_BASE=${SANDBOX_BOOTSTRAP_BASE:-$REPO_ROOT} \
    STUB_OLD_VERSION=$STUB_OLD_VERSION \
    STUB_DOCKER_LOG=$SANDBOX/docker.log \
    PATH=$STUB_BIN:$PATH \
      "$script" "$@" 2>&1
  )
}
