#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR=${INSTALL_DIR:-/opt/b2b-platform}
BOOTSTRAP_BASE=${BOOTSTRAP_BASE:-https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main}
RELEASE_VERSION=""
while (($#)); do case "$1" in --version) RELEASE_VERSION=${2:?missing version}; shift 2;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail "run with sudo"
compose=(docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/compose.yml")
wait_for_healthy() {
  local service=$1 timeout=${2:-240} elapsed=0 container status
  while (( elapsed < timeout )); do
    container=$("${compose[@]}" ps -q "$service" 2>/dev/null | head -1)
    if [[ -n $container ]]; then
      status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)
      [[ $status == healthy ]] && return 0
      case $status in unhealthy|exited|dead) break;; esac
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  "${compose[@]}" logs --tail=100 "$service" >&2 || true
  fail "$service did not become healthy within ${timeout}s"
}
[[ $(uname -m) == x86_64 ]] || fail "only amd64 is supported"
source /etc/os-release
[[ ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ]] || fail "Ubuntu 22.04/24.04 is required"
if [[ -f $INSTALL_DIR/.env && -x $INSTALL_DIR/b2b-platform ]]; then
  if [[ -n $RELEASE_VERSION ]]; then exec "$INSTALL_DIR/b2b-platform" upgrade "$RELEASE_VERSION"; fi
  echo "Existing installation found; running diagnostics instead of overwriting configuration."
  exec "$INSTALL_DIR/b2b-platform" doctor
fi
(( $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) >= 1900 )) || fail "at least 2 GB RAM is required"
(( $(df -Pm /opt 2>/dev/null | awk 'NR==2{print $4}' || df -Pm / | awk 'NR==2{print $4}') >= 10240 )) || fail "at least 10 GB free disk is required"

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  read -r -p "Install Docker Engine from Docker's official Ubuntu repository? [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]] || fail "Docker is required"
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

install -d -m 0700 "$INSTALL_DIR"
curl -fsSL "$BOOTSTRAP_BASE/compose.yml" -o "$INSTALL_DIR/compose.yml"
curl -fsSL "$BOOTSTRAP_BASE/Caddyfile.domain" -o "$INSTALL_DIR/Caddyfile.domain"
curl -fsSL "$BOOTSTRAP_BASE/Caddyfile.ip" -o "$INSTALL_DIR/Caddyfile.ip"
curl -fsSL "$BOOTSTRAP_BASE/b2b-platform" -o "$INSTALL_DIR/b2b-platform"
curl -fsSL "$BOOTSTRAP_BASE/SHA256SUMS" -o "$INSTALL_DIR/SHA256SUMS"
curl -fsSL "$BOOTSTRAP_BASE/update.sh" -o "$INSTALL_DIR/update.sh"
curl -fsSL "$BOOTSTRAP_BASE/install.sh" -o "$INSTALL_DIR/install.sh"
chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/update.sh"
(cd "$INSTALL_DIR" && sha256sum -c SHA256SUMS)
chmod 0755 "$INSTALL_DIR/b2b-platform"
ln -sf "$INSTALL_DIR/b2b-platform" /usr/local/bin/b2b-platform

if [[ -z $RELEASE_VERSION ]]; then RELEASE_VERSION=$(curl -fsSL "$BOOTSTRAP_BASE/stable.json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'); fi
[[ $RELEASE_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid release version"
read -r -p "GitHub username: " GH_USER
read -r -s -p "GHCR token (read:packages only): " GH_TOKEN; echo
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin
unset GH_TOKEN
read -r -p "Deployment mode [domain/ip]: " MODE
[[ $MODE == domain || $MODE == ip ]] || fail "mode must be domain or ip"
if [[ $MODE == domain ]]; then
  read -r -p "Domain (example: app.example.com): " HOST
  [[ $HOST =~ ^[A-Za-z0-9.-]+$ && $HOST == *.* ]] || fail "invalid domain"
  HTTP_PORT=80; HTTPS_HOST=0.0.0.0; HTTPS_PORT=443; ORIGIN="https://$HOST"; COOKIE=true
  for port in 80 443; do ss -H -ltn "sport = :$port" | grep -q . && fail "port $port is already in use" || true; done
else
  HOST=$(hostname -I | awk '{print $1}')
  read -r -p "Public server IP [$HOST]: " entered; HOST=${entered:-$HOST}
  [[ $HOST =~ ^[0-9a-fA-F:.]+$ ]] || fail "invalid IP"
  read -r -p "Public HTTP port [8080]: " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-8080}
  [[ $HTTP_PORT =~ ^[0-9]+$ ]] && (( HTTP_PORT >= 1024 && HTTP_PORT <= 65535 )) || fail "IP mode port must be between 1024 and 65535"
  ss -H -ltn "sport = :$HTTP_PORT" | grep -q . && fail "port $HTTP_PORT is already in use" || true
  HTTPS_HOST=127.0.0.1; HTTPS_PORT=44443; ORIGIN="http://$HOST:$HTTP_PORT"; COOKIE=false
fi
read -r -p "First platform administrator email: " ADMIN_EMAIL
[[ $ADMIN_EMAIL == *@*.* ]] || fail "invalid email"
secret() { openssl rand -base64 32 | tr -d '\n'; }
cat > "$INSTALL_DIR/.env" <<EOF
APP_VERSION=$RELEASE_VERSION
DEPLOYMENT_MODE=$MODE
PUBLIC_HOST=$HOST
PUBLIC_HTTP_PORT=$HTTP_PORT
PUBLIC_HTTPS_HOST=$HTTPS_HOST
PUBLIC_HTTPS_PORT=$HTTPS_PORT
PUBLIC_ORIGIN=$ORIGIN
SESSION_COOKIE_SECURE=$COOKIE
POSTGRES_DB=b2b_platform
POSTGRES_USER=b2b_platform_admin
POSTGRES_PASSWORD=$(secret)
POSTGRES_APP_USER=b2b_platform_app
POSTGRES_APP_PASSWORD=$(secret)
MINIO_ROOT_USER=b2b_minio
MINIO_ROOT_PASSWORD=$(secret)
BACKUP_SERVICE_TOKEN=$(secret)
BACKUP_ENCRYPTION_KEY=$(secret)
TENANT_SETTINGS_ENCRYPTION_KEYS=v1:$(secret)
TENANT_SETTINGS_ACTIVE_KEY_ID=v1
AUTH_EMAIL_FROM=
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=true
SMTP_USER=
SMTP_PASSWORD=
EOF
chmod 0600 "$INSTALL_DIR/.env"
cp "$INSTALL_DIR/Caddyfile.$MODE" "$INSTALL_DIR/Caddyfile"
cd "$INSTALL_DIR"
"${compose[@]}" pull
"${compose[@]}" up -d postgres redis minio
"${compose[@]}" run --rm migrate
"${compose[@]}" up -d api worker dispatcher backup web caddy
wait_for_healthy web
ADMIN_RESULT=$("${compose[@]}" exec -T api node apps/api/dist/bootstrapPlatformAdmin.js "$ADMIN_EMAIL")
ADMIN_RESULT_FILE="$INSTALL_DIR/bootstrap-admin-result.json"
printf '%s\n' "$ADMIN_RESULT" > "$ADMIN_RESULT_FILE"
chmod 0600 "$ADMIN_RESULT_FILE"
for _ in {1..30}; do curl -fsS "$ORIGIN/health" >/dev/null && break; sleep 2; done
if ! curl -fsS "$ORIGIN/health" >/dev/null; then
  fail "health check failed; run b2b-platform logs; administrator credentials are in $ADMIN_RESULT_FILE (mode 600)"
fi
echo "Installed $RELEASE_VERSION at $ORIGIN"
echo "One-time administrator credentials (this will not be stored again):"
cat "$ADMIN_RESULT_FILE"
rm -f "$ADMIN_RESULT_FILE"
[[ $MODE == ip ]] && echo "WARNING: HTTP IP:$HTTP_PORT mode is unencrypted. Limit access at the router/firewall and run b2b-platform configure domain when available."
echo "SMTP is not configured. Password reset and email alerts are unavailable until: b2b-platform configure smtp"
