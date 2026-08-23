#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR=/opt/b2b-platform
BOOTSTRAP_BASE=${BOOTSTRAP_BASE:-https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main}
RELEASE_VERSION=""

usage() {
  cat <<'EOF'
Usage: update.sh [--version vX.Y.Z]

Updates the installed B2B Platform control files and application images.
Without --version, the current stable.json release is used.
EOF
}

while (($#)); do
  case "$1" in
    --version) RELEASE_VERSION=${2:?missing version}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail "run with sudo"
[[ -f $INSTALL_DIR/.env && -f $INSTALL_DIR/compose.yml && -x $INSTALL_DIR/b2b-platform ]] || fail "no existing installation found at $INSTALL_DIR"

env_get() { sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | tail -1; }
mode=$(env_get DEPLOYMENT_MODE)
[[ $mode == domain || $mode == ip ]] || fail "invalid DEPLOYMENT_MODE: $mode"
previous=$(env_get APP_VERSION)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/b2b-platform-update.XXXXXX")
control_backup=$(mktemp -d "$INSTALL_DIR/.update-backup.XXXXXX")
cleanup() { rm -rf "$tmp" "$control_backup"; }
trap cleanup EXIT

if [[ -z $RELEASE_VERSION ]]; then
  stable=$(curl -fsSL "$BOOTSTRAP_BASE/stable.json") || fail "cannot read stable release manifest"
  RELEASE_VERSION=$(printf '%s' "$stable" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p')
fi
[[ $RELEASE_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid release version: $RELEASE_VERSION"
same_version=false
[[ $RELEASE_VERSION == "$previous" ]] && same_version=true

for file in b2b-platform update.sh install.sh compose.yml Caddyfile.ip Caddyfile.domain SHA256SUMS; do
  curl -fsSL "$BOOTSTRAP_BASE/$file" -o "$tmp/$file" || fail "cannot download $file"
done
(
  cd "$tmp"
  sha256sum -c SHA256SUMS
) || fail "bootstrap file integrity check failed"

for file in b2b-platform update.sh install.sh compose.yml Caddyfile.ip Caddyfile.domain SHA256SUMS; do
  [[ -e "$INSTALL_DIR/$file" ]] && cp -p "$INSTALL_DIR/$file" "$control_backup/$file"
done
[[ -e "$INSTALL_DIR/Caddyfile" ]] && cp -p "$INSTALL_DIR/Caddyfile" "$control_backup/Caddyfile"

install_control_files() {
  local file mode_bits
  for file in b2b-platform update.sh install.sh compose.yml Caddyfile.ip Caddyfile.domain SHA256SUMS; do
    mode_bits=0644
    [[ $file == b2b-platform || $file == update.sh || $file == install.sh ]] && mode_bits=0755
    install -m "$mode_bits" "$tmp/$file" "$INSTALL_DIR/$file.new"
    mv -f "$INSTALL_DIR/$file.new" "$INSTALL_DIR/$file"
  done
  install -m 0644 "$tmp/Caddyfile.$mode" "$INSTALL_DIR/Caddyfile.new"
  mv -f "$INSTALL_DIR/Caddyfile.new" "$INSTALL_DIR/Caddyfile"
}

restore_control_files() {
  local file mode_bits
  for file in b2b-platform update.sh install.sh compose.yml Caddyfile.ip Caddyfile.domain SHA256SUMS Caddyfile; do
    [[ -e "$control_backup/$file" ]] || continue
    mode_bits=0644
    [[ $file == b2b-platform || $file == update.sh || $file == install.sh ]] && mode_bits=0755
    install -m "$mode_bits" "$control_backup/$file" "$INSTALL_DIR/$file"
  done
}

install_control_files

new_compose=(docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/compose.yml")
if ! "${new_compose[@]}" config -q || ! "${new_compose[@]}" up -d caddy; then
  restore_control_files
  fail "new control files could not start Caddy; restored control files"
fi
"$INSTALL_DIR/b2b-platform" doctor || {
  restore_control_files
  fail "post-control-file health check failed; restored control files"
}

if $same_version; then
  echo "Control files updated; application already on $RELEASE_VERSION"
  exit 0
fi

upgrade_log=$(mktemp "$tmp/upgrade.XXXXXX")
run_upgrade() { "$INSTALL_DIR/b2b-platform" upgrade "$RELEASE_VERSION" 2>&1 | tee "$upgrade_log"; }

if ! run_upgrade; then
  if grep -Eqi '401|unauthorized|authentication required|denied' "$upgrade_log"; then
    read -r -p "GHCR username [zgybkjcn-a11y]: " gh_user
    gh_user=${gh_user:-zgybkjcn-a11y}
    read -r -s -p "GHCR token (read:packages): " gh_token; echo
    if ! printf '%s' "$gh_token" | docker login ghcr.io -u "$gh_user" --password-stdin; then
      unset gh_token
      restore_control_files
      fail "GHCR login failed; restored control files"
    fi
    unset gh_token
    run_upgrade || true
  fi
fi

if ! grep -q "Upgraded to $RELEASE_VERSION" "$upgrade_log"; then
  restore_control_files
  "${new_compose[@]}" up -d api worker dispatcher backup web caddy || true
  fail "update failed; restored control files and attempted to restore the previous application version $previous"
fi

echo "Updated from $previous to $RELEASE_VERSION"
