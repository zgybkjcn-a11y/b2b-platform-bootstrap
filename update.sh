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
# Caddy 模板与 DEPLOYMENT_MODE 解耦：tunnel 只改 TLS 终止位置（Cloudflare 边缘终止、
# Caddy 在容器 80 上服务明文 HTTP），应用侧语义仍然是 domain。旧安装没有这个键，
# 默认沿用 DEPLOYMENT_MODE，行为与升级前逐字节一致。
template=$(env_get CADDY_TEMPLATE)
template=${template:-$mode}
[[ $template == domain || $template == ip || $template == tunnel ]] || fail "invalid CADDY_TEMPLATE: $template"
[[ $template != tunnel || $mode == domain ]] || fail "CADDY_TEMPLATE=tunnel requires DEPLOYMENT_MODE=domain"
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

# 新增控制文件时只改这一处。`--ignore-missing` 让还没升级的旧 update.sh 不会因为
# SHA256SUMS 里多出它没下载的文件而整体失败；下面逐个确认本次下载的文件都真的被
# SHA256SUMS 覆盖，避免被裁剪过的清单静默跳过校验。
CONTROL_FILES=(b2b-platform update.sh install.sh compose.yml Caddyfile.ip Caddyfile.domain Caddyfile.tunnel SHA256SUMS)
for file in "${CONTROL_FILES[@]}"; do
  curl -fsSL "$BOOTSTRAP_BASE/$file" -o "$tmp/$file" || fail "cannot download $file"
done
for file in "${CONTROL_FILES[@]}"; do
  [[ $file == SHA256SUMS ]] && continue
  grep -qE "[[:space:]]\*?${file//./\\.}\$" "$tmp/SHA256SUMS" || fail "SHA256SUMS does not cover $file"
done
(
  cd "$tmp"
  sha256sum -c --ignore-missing SHA256SUMS
) || fail "bootstrap file integrity check failed"

for file in "${CONTROL_FILES[@]}"; do
  if [[ -e "$INSTALL_DIR/$file" ]]; then cp -p "$INSTALL_DIR/$file" "$control_backup/$file"; fi
done
[[ -e "$INSTALL_DIR/Caddyfile" ]] && cp -p "$INSTALL_DIR/Caddyfile" "$control_backup/Caddyfile"
[[ -e "$INSTALL_DIR/.env" ]] && cp -p "$INSTALL_DIR/.env" "$control_backup/.env"

install_control_files() {
  local file mode_bits
  for file in "${CONTROL_FILES[@]}"; do
    mode_bits=0644
    [[ $file == b2b-platform || $file == update.sh || $file == install.sh ]] && mode_bits=0755
    install -m "$mode_bits" "$tmp/$file" "$INSTALL_DIR/$file.new"
    mv -f "$INSTALL_DIR/$file.new" "$INSTALL_DIR/$file"
  done
  # Caddyfile 始终由模板生成，模板由 CADDY_TEMPLATE 选择；不要手工改 Caddyfile，
  # 它每次 update 都会被覆盖。要改就改模板并发布新版本。
  # 这里必须用 cp（原地截断、保留 inode）而不是 install/mv：Caddyfile 是以单文件
  # bind mount 挂进 caddy 容器的，换掉 inode 会让容器继续读旧文件。
  cp "$tmp/Caddyfile.$template" "$INSTALL_DIR/Caddyfile"
  chmod 0644 "$INSTALL_DIR/Caddyfile"
}

restore_control_files() {
  local file mode_bits
  for file in "${CONTROL_FILES[@]}" Caddyfile .env; do
    [[ -e "$control_backup/$file" ]] || continue
    mode_bits=0644
    [[ $file == b2b-platform || $file == update.sh || $file == install.sh ]] && mode_bits=0755
    [[ $file == .env ]] && mode_bits=0600
    install -m "$mode_bits" "$control_backup/$file" "$INSTALL_DIR/$file"
  done
}

restore_and_restart_caddy() {
  restore_control_files
  local restored_compose=(docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/compose.yml")
  "${restored_compose[@]}" up -d api worker dispatcher backup web caddy || true
}

install_control_files

new_compose=(docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/compose.yml")
if ! "${new_compose[@]}" config -q; then
  restore_and_restart_caddy
  fail "new control files failed Compose validation; restored control files"
fi
"$INSTALL_DIR/b2b-platform" doctor || {
  restore_and_restart_caddy
  fail "post-control-file health check failed; restored control files"
}

# Caddy 只在模板内容真的变了时才强制重建：bind mount 的文件内容变化不会让
# `up -d` 重建容器，不强制重建的话新模板永远不会生效。
apply_caddy_template() {
  local caddy_up=()
  if ! cmp -s "$control_backup/Caddyfile" "$INSTALL_DIR/Caddyfile"; then
    caddy_up=(--force-recreate)
    echo "Caddy template changed; recreating the proxy"
  fi
  "${new_compose[@]}" up -d "${caddy_up[@]}" caddy
}

if $same_version; then
  apply_caddy_template || {
    restore_and_restart_caddy
    fail "new control files could not start Caddy; restored control files"
  }
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
      restore_and_restart_caddy
      fail "GHCR login failed; restored control files"
    fi
    unset gh_token
    run_upgrade || true
  fi
fi

if ! grep -q "Upgraded to $RELEASE_VERSION" "$upgrade_log"; then
  restore_and_restart_caddy
  "${new_compose[@]}" up -d api worker dispatcher backup web caddy || true
  fail "update failed; restored control files and attempted to restore the previous application version $previous"
fi

# Start the proxy only after the application image upgrade has completed.
# Starting Caddy before `b2b-platform upgrade` would evaluate the new Web
# healthcheck against the previous Web image and can reject every update.
if ! apply_caddy_template; then
  restore_and_restart_caddy
  fail "new control files could not start Caddy after application upgrade; restored control files"
fi

echo "Updated from $previous to $RELEASE_VERSION"
