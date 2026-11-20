#!/usr/bin/env bash
#
# OpenClaw NAS Docker installer — self-contained.
#
# Install without cloning the repository:
#   bash <(curl -fsSL https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main/install.sh) <NAS_IP>
#
# Or run from a cloned repo:
#   ./install.sh <NAS_IP>
#
# This script generates all required deployment files on first run
# (docker-compose.yml, nginx/nginx.conf, openclaw wrapper) and then
# proceeds with the full installation: certs, validation, stack startup.

set -euo pipefail

# Resolve working directory — works for both direct execution and curl|bash.
# When piped (curl | bash) BASH_SOURCE[0] is /dev/stdin or -, and with process
# substitution (bash <(curl ...)) it is /dev/fd/N. Use $PWD in those cases.
_src="${BASH_SOURCE[0]:-$0}"
if [[ "$_src" == "/dev/stdin" || "$_src" == "-" || "$_src" == /dev/fd/* || "$_src" == /proc/* ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
fi
unset _src
cd "$SCRIPT_DIR"

ENV_FILE=".env"
CERTS_DIR="certs"
DEFAULT_HTTPS_PORT="8443"
RAW_BASE_URL="${OPENCLAW_RAW_BASE_URL:-https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'
if [[ ! -t 1 ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ─── Output helpers ───────────────────────────────────────────────────────────

print_banner() {
  printf '%b\n' "$RED"
  echo "╔═════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                         ║"
  echo "║   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗  ║"
  echo "║  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║  ║"
  echo "║  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║  ║"
  echo "║  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║  ║"
  echo "║  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝  ║"
  echo "║   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝   ║"
  echo "║                                                                         ║"
  echo "║                   NAS Docker Installer by Luprintech                    ║"
  echo "║                                                                         ║"
  echo "╚═════════════════════════════════════════════════════════════════════════╝"
  printf '%b\n' "$NC"
}

usage() {
  cat <<'USAGE'
Usage:
  bash <(curl -fsSL <installer-url>) <NAS_IP>
  ./install.sh <NAS_IP>

Example:
  ./install.sh 192.168.1.50

This installer:
  1. Checks Docker and Docker Compose v2.
  2. Writes docker-compose.yml, nginx/nginx.conf, the ./openclaw command and .env.
  3. Creates a local HTTPS certificate for the NAS IP.
  4. Downloads and starts OpenClaw, then configures access.

It shows one line per step. The detailed output goes to logs/install-<date>.log;
set OPENCLAW_VERBOSE=1 to print everything instead.

Operational commands after install:
  ./openclaw onboard
  ./openclaw dashboard
  ./openclaw devices
  ./openclaw approve <request_id>
  ./openclaw status
  ./openclaw logs
USAGE
}

section() {
  printf '\n%b==> %s%b\n' "$BLUE$BOLD" "$1" "$NC"
}

success() {
  printf '%b✓ %s%b\n' "$GREEN" "$1" "$NC"
}

warn() {
  printf '%b⚠ %s%b\n' "$YELLOW" "$1" "$NC"
  [[ -n "${WARN_FILE:-}" ]] && printf '%s\n' "$1" >> "$WARN_FILE"
  return 0
}

# Detail for the log only; not repeated in the final summary.
note() {
  printf '  %s\n' "$1"
}

VERBOSE="${OPENCLAW_VERBOSE:-0}"
LOG_FILE=""
WARN_FILE=""
STEP_NUM=0
STEP_TOTAL=5

format_elapsed() {
  local seconds="$1"
  if (( seconds >= 60 )); then
    printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
  else
    printf '%ds' "$seconds"
  fi
}

setup_install_log() {
  WARN_FILE="$(mktemp)"
  trap 'rm -f "$WARN_FILE"' EXIT
  [[ "$VERBOSE" == "1" ]] && return 0
  mkdir -p logs
  chmod 700 logs 2>/dev/null || true
  LOG_FILE="logs/install-$(date +%Y%m%d-%H%M%S).log"
  (umask 077 && : > "$LOG_FILE")
}

# Keep color codes out of the log: functions called from here see the local,
# empty values.
run_without_colors() {
  local RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
  "$@"
}

# Shortens a live progress label to the terminal width. A line that wraps
# cannot be redrawn with \r, so on narrow terminals (a phone or tablet SSH
# client) every redraw would leave another copy of the line behind.
fit_to_terminal() {
  local text="$1" reserve="$2" cols max
  cols="$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)" || cols=""
  [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols=80
  max=$((cols - reserve))
  if (( max > 10 && ${#text} > max )); then
    text="${text:0:max}"
  fi
  printf '%s' "$text"
}

# run_step <label> <command...>: one status line instead of the full output.
# Steps are never called as `run_step ... || handler`: inside an || list bash
# ignores `set -e`, also in the background job, so a failing command would
# not fail the step. The step calls its failure handler itself instead.
run_step() {
  local label="$1"
  shift
  STEP_NUM=$((STEP_NUM + 1))
  local prefix="[$STEP_NUM/$STEP_TOTAL] $label"

  if [[ "$VERBOSE" == "1" || -z "$LOG_FILE" ]]; then
    printf '\n%b==> %s%b\n' "$BLUE$BOLD" "$prefix" "$NC"
    "$@"
    return
  fi

  printf '\n==> %s\n' "$prefix" >> "$LOG_FILE"
  local start=$SECONDS pid rc=0
  run_without_colors "$@" < /dev/null >> "$LOG_FILE" 2>&1 &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[K%s... %s' "$(fit_to_terminal "$prefix" 12)" "$(format_elapsed $((SECONDS - start)))"
      sleep 1
    done
  else
    printf '%s... ' "$prefix"
  fi
  wait "$pid" || rc=$?

  local took
  took="$(format_elapsed $((SECONDS - start)))"
  local result="${GREEN}done${NC}"
  [[ "$rc" -eq 0 ]] || result="${RED}failed${NC}"
  if [[ -t 1 ]]; then
    printf '\r\033[K%s... %b (%s)\n' "$prefix" "$result" "$took"
  else
    printf '%b (%s)\n' "$result" "$took"
  fi
  [[ "$rc" -eq 0 ]] || install_failed
}

install_failed() {
  printf '\n%b✗ The installation did not finish.%b\n' "$RED" "$NC" >&2
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '  Last lines of the log:\n\n' >&2
    tail -n 25 "$LOG_FILE" | sed 's/^/    /' >&2
    printf '\n  Full log: %s\n' "$LOG_FILE" >&2
  fi
  printf '  Fix the problem above and run ./install.sh again. See "Troubleshooting" in the README.\n' >&2
  exit 1
}

error() {
  printf '%bERROR: %s%b\n' "$RED" "$1" "$NC" >&2
  exit 1
}

validation_fail() {
  printf '%bERROR: %s%b\n' "$RED" "$1" "$NC" >&2
}

need_command() {
  if command -v "$1" >/dev/null 2>&1; then
    success "Found $1"
  else
    error "Missing required command: $1"
  fi
}

# ─── Env helpers ──────────────────────────────────────────────────────────────

env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$ENV_FILE"
}

env_set() {
  local key="$1"
  local value="$2"

  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { FS=OFS="=" }
      $1 == key { print key, value; next }
      { print }
    ' "$ENV_FILE" > "${ENV_FILE}.tmp"
  else
    cp "$ENV_FILE" "${ENV_FILE}.tmp"
    printf '\n%s=%s\n' "$key" "$value" >> "${ENV_FILE}.tmp"
  fi

  mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  elif command -v python >/dev/null 2>&1; then
    python - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  else
    error "Cannot generate token. Install openssl or python."
  fi
}

detect_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  fi
  [[ -z "$tz" && -f /etc/timezone ]] && tz="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
  fi
  # Reject known-invalid values from Synology DSM
  [[ "$tz" == "Etc/Unknown" || "$tz" == "localtime" || -z "$tz" ]] && tz="UTC"
  printf '%s' "$tz"
}

detect_nas_ip() {
  local arg_ip="${1:-}"
  if [[ -n "$arg_ip" ]]; then
    printf '%s' "$arg_ip"
    return
  fi

  local env_ip
  env_ip="$(env_get NAS_IP | tr -d '[:space:]')"
  if [[ -n "$env_ip" ]]; then
    printf '%s' "$env_ip"
    return
  fi

  error "NAS IP is required the first time. Use: ./install.sh <your-nas-lan-ip>"
}

# ─── IP / port validation ─────────────────────────────────────────────────────

valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

# ─── Certificate generation ───────────────────────────────────────────────────

run_mkcert_local() {
  local nas_ip="$1"
  shift
  local extra_names=("$@")
  local cert_names=("$nas_ip" localhost 127.0.0.1 "${extra_names[@]}")
  local mkcert_caroot="$CERTS_DIR/mkcert-ca"

  mkdir -p "$mkcert_caroot"

  # Do not run `mkcert -install` on Synology — it may mutate the system trust store.
  # We only need a project-local CA and the exported rootCA.pem for client devices.
  printf 'Using project-local mkcert CA: %s\n' "$mkcert_caroot"
  printf 'Generating certificate for: %s\n' "${cert_names[*]}"

  CAROOT="$mkcert_caroot" mkcert \
    -cert-file "$CERTS_DIR/openclaw-local.pem" \
    -key-file "$CERTS_DIR/openclaw-local-key.pem" \
    "${cert_names[@]}"

  if [[ -f "$mkcert_caroot/rootCA.pem" ]]; then
    cp "$mkcert_caroot/rootCA.pem" "$CERTS_DIR/rootCA.pem"
  else
    printf 'WARN: rootCA.pem not found at %s/rootCA.pem\n' "$mkcert_caroot" >&2
    return 1
  fi
}

generate_with_openssl() {
  local nas_ip="$1"
  shift
  local extra_names=("$@")
  local ca_key="$CERTS_DIR/rootCA-key.pem"
  local ca_cert="$CERTS_DIR/rootCA.pem"
  local server_key="$CERTS_DIR/openclaw-local-key.pem"
  local server_csr="$CERTS_DIR/openclaw-local.csr"
  local server_cert="$CERTS_DIR/openclaw-local.pem"
  local san_conf="$CERTS_DIR/openssl-san.cnf"
  local ca_serial="$CERTS_DIR/rootCA.srl"
  local index=3
  local name

  command -v openssl >/dev/null 2>&1 || error "Neither mkcert nor openssl is available. Install one of them first."

  mkdir -p "$CERTS_DIR"

  # Installations created with mkcert keep their CA, so devices that already
  # trust it do not need to install a new one.
  if [[ ! -f "$ca_key" && -f "$CERTS_DIR/mkcert-ca/rootCA-key.pem" && -f "$CERTS_DIR/mkcert-ca/rootCA.pem" ]]; then
    ca_key="$CERTS_DIR/mkcert-ca/rootCA-key.pem"
    cp "$CERTS_DIR/mkcert-ca/rootCA.pem" "$ca_cert"
    printf 'Reusing the existing mkcert root CA.\n'
  fi

  if [[ ! -f "$ca_key" || ! -f "$ca_cert" ]]; then
    printf 'Creating local OpenClaw root CA with OpenSSL...\n'
    openssl genrsa -out "$ca_key" 4096
    openssl req -x509 -new -nodes \
      -key "$ca_key" \
      -sha256 \
      -days 3650 \
      -out "$ca_cert" \
      -subj "/CN=OpenClaw Local Root CA"
  else
    printf 'Reusing existing local OpenClaw root CA.\n'
  fi

  cat > "$san_conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $nas_ip

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = $nas_ip
IP.2 = 127.0.0.1
DNS.1 = localhost
EOF

  for name in "${extra_names[@]}"; do
    if [[ "$name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf 'IP.%s = %s\n' "$index" "$name" >> "$san_conf"
    else
      printf 'DNS.%s = %s\n' "$index" "$name" >> "$san_conf"
    fi
    index=$((index + 1))
  done

  printf 'Generating OpenClaw server certificate with OpenSSL...\n'
  openssl genrsa -out "$server_key" 2048
  openssl req -new -key "$server_key" -out "$server_csr" -config "$san_conf"
  openssl x509 -req \
    -in "$server_csr" \
    -CA "$ca_cert" \
    -CAkey "$ca_key" \
    -CAserial "$ca_serial" \
    -CAcreateserial \
    -out "$server_cert" \
    -days 825 \
    -sha256 \
    -extensions req_ext \
    -extfile "$san_conf"

  rm -f "$server_csr" "$san_conf" "$ca_serial"
  chmod 600 "$ca_key" "$server_key" 2>/dev/null || true
}

generate_https_certs_if_needed() {
  local nas_ip="$1"

  section "Generating local HTTPS certificates"
  mkdir -p "$CERTS_DIR"

  # mkcert is used only when it is already installed; the installer never
  # installs software on the NAS. OpenSSL is the default.
  if command -v mkcert >/dev/null 2>&1; then
    printf 'mkcert found: %s\n' "$(mkcert -version 2>/dev/null || echo installed)"
    if ! run_mkcert_local "$nas_ip"; then
      printf 'mkcert generation failed. Falling back to OpenSSL local CA.\n' >&2
      generate_with_openssl "$nas_ip"
    fi
  else
    printf 'mkcert not available. Using OpenSSL local CA.\n'
    generate_with_openssl "$nas_ip"
  fi

  cp "$CERTS_DIR/rootCA.pem" "$CERTS_DIR/rootCA.cer"
  success "Generated local HTTPS certificates for $nas_ip"
  note "Install certs/rootCA.pem (rootCA.cer on Windows) on every device that will open https://$nas_ip"
}

# ─── Environment validation ───────────────────────────────────────────────────

validate_env_inline() {
  section "Validating setup"
  local _errors=0

  local token
  token="$(env_get OPENCLAW_GATEWAY_TOKEN | tr -d '[:space:]')"
  if [[ -z "$token" ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN is empty"
    _errors=$((_errors + 1))
  elif [[ ${#token} -lt 32 ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN too short (${#token} chars, need 32+)"
    _errors=$((_errors + 1))
  elif [[ ! "$token" =~ ^[A-Za-z0-9-]+$ ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN contains unsafe characters (use letters, numbers, hyphens only)"
    _errors=$((_errors + 1))
  fi

  local nas_ip
  nas_ip="$(env_get NAS_IP | tr -d '[:space:]')"
  if ! valid_ipv4 "$nas_ip" 2>/dev/null; then
    validation_fail "NAS_IP='$nas_ip' is not a valid IPv4 address"
    _errors=$((_errors + 1))
  fi

  local host_bind
  host_bind="$(env_get OPENCLAW_HOST_BIND | tr -d '[:space:]')"
  if [[ "$host_bind" != "127.0.0.1" ]]; then
    validation_fail "OPENCLAW_HOST_BIND must be 127.0.0.1 (got '$host_bind')"
    _errors=$((_errors + 1))
  fi

  local https_mode
  https_mode="$(env_get OPENCLAW_HTTPS_MODE | tr -d '[:space:]')"
  if [[ "$https_mode" != "local" ]]; then
    validation_fail "OPENCLAW_HTTPS_MODE must be local (got '$https_mode')"
    _errors=$((_errors + 1))
  fi

  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  [[ -z "$https_port" ]] && https_port="$DEFAULT_HTTPS_PORT"
  if ! valid_port "$https_port"; then
    validation_fail "OPENCLAW_HTTPS_PORT='$https_port' is not a valid port"
    _errors=$((_errors + 1))
  fi

  if [[ ! -f "certs/openclaw-local.pem" || ! -f "certs/openclaw-local-key.pem" ]]; then
    validation_fail "TLS certificates missing in certs/ — cert generation may have failed"
    _errors=$((_errors + 1))
  fi

  local tz
  tz="$(env_get TZ | tr -d '[:space:]')"
  [[ -z "$tz" ]] && warn "TZ is not set. Consider adding TZ=<your/timezone> to .env"

  if [[ $_errors -gt 0 ]]; then
    printf '%bValidation failed: %s error(s)%b\n' "$RED" "$_errors" "$NC" >&2
    exit 1
  fi

  success "Environment validation passed"
}

# ─── Config file generation ───────────────────────────────────────────────────
# docker-compose.yml is always regenerated — it is fully managed by install.sh.
# nginx.conf and the openclaw wrapper are written only on first install.
# Files use quoted heredocs ('DELIM') to prevent bash variable expansion —
# docker-compose and nginx interpret their own ${VAR} syntax at runtime.

write_docker_compose() {
  section "Generating docker-compose.yml"
  cat > docker-compose.yml << 'COMPOSE_EOF'
# OpenClaw Gateway Stack for NAS.
#
# Target architecture:
#   LAN browser -> https://NAS_IP:8443 -> Nginx TLS proxy -> OpenClaw Gateway
#
# Public exposure policy:
#   Do NOT port-forward this service from the router.
#   Do NOT expose 18789/443/8443 from the router.

services:
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    profiles:
      - https-local
    ports:
      - "${OPENCLAW_PROXY_BIND:-127.0.0.1}:${OPENCLAW_HTTPS_PORT:-8443}:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    networks:
      - openclaw-net
    depends_on:
      - openclaw-gateway

  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-ghcr.io/luprintech/openclaw-nas-docker:latest}
    restart: unless-stopped
    init: true
    # Give the gateway time to release its state lock. If Docker has to kill
    # it after the default 10 seconds, the next doctor run cannot enter
    # maintenance and the update skips the data migration.
    stop_grace_period: 60s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

    networks:
      - openclaw-net

    # HTTPS-only mode: OPENCLAW_HOST_BIND=127.0.0.1 and nginx publishes HTTPS.
    # Never expose this port through router port-forwarding.
    ports:
      - "${OPENCLAW_HOST_BIND:?Set OPENCLAW_HOST_BIND=127.0.0.1 in .env}:${OPENCLAW_GATEWAY_PORT:-18789}:18789"

    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      NPM_CONFIG_PREFIX: /home/node/.npm-global
      FORCE_COLOR: "1"
      CI: "false"
      OPENCLAW_SHOW_DEVICE_CODE: "true"
      # Keep Claude Code login, settings, memory and history across container
      # re-creation. Stored under ./config, which is already persisted.
      CLAUDE_CONFIG_DIR: /home/node/.openclaw/claude
      # Provider API keys from .env. They are passed with a prefix so an empty
      # value never hides a key stored in config/.env; entrypoint.sh exports
      # only the non-empty ones under their real names.
      OPENCLAW_NAS_ENV_ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      OPENCLAW_NAS_ENV_OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENCLAW_NAS_ENV_GEMINI_API_KEY: ${GEMINI_API_KEY:-}
      OPENCLAW_NAS_ENV_OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENCLAW_NAS_ENV_MISTRAL_API_KEY: ${MISTRAL_API_KEY:-}
      OPENCLAW_NAS_ENV_GROQ_API_KEY: ${GROQ_API_KEY:-}
      OPENCLAW_NAS_ENV_COHERE_API_KEY: ${COHERE_API_KEY:-}

    volumes:
      - ./config:/home/node/.openclaw
      - ./workspace:/home/node/.openclaw/workspace

    entrypoint: ["/home/node/entrypoint.sh"]
    command: ["node", "dist/index.js", "gateway", "--allow-unconfigured", "--bind", "lan", "--port", "18789"]

    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:18789/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  openclaw-cli:
    image: ${OPENCLAW_IMAGE:-ghcr.io/luprintech/openclaw-nas-docker:latest}
    profiles:
      - cli
    # Export the provider keys first (see entrypoint.sh), then hand over to
    # the image's own entrypoint.
    entrypoint: ["/home/node/entrypoint.sh", "tini", "-s", "--", "node", "/app/docker-entrypoint.mjs"]
    init: true
    networks:
      - openclaw-net
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      NPM_CONFIG_PREFIX: /home/node/.npm-global
      FORCE_COLOR: "1"
      CI: "false"
      OPENCLAW_SHOW_DEVICE_CODE: "true"
      # Keep Claude Code login, settings, memory and history across container
      # re-creation. Stored under ./config, which is already persisted.
      CLAUDE_CONFIG_DIR: /home/node/.openclaw/claude
      # Provider API keys from .env. They are passed with a prefix so an empty
      # value never hides a key stored in config/.env; entrypoint.sh exports
      # only the non-empty ones under their real names.
      OPENCLAW_NAS_ENV_ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      OPENCLAW_NAS_ENV_OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENCLAW_NAS_ENV_GEMINI_API_KEY: ${GEMINI_API_KEY:-}
      OPENCLAW_NAS_ENV_OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:-}
      OPENCLAW_NAS_ENV_MISTRAL_API_KEY: ${MISTRAL_API_KEY:-}
      OPENCLAW_NAS_ENV_GROQ_API_KEY: ${GROQ_API_KEY:-}
      OPENCLAW_NAS_ENV_COHERE_API_KEY: ${COHERE_API_KEY:-}

    volumes:
      - ./config:/home/node/.openclaw
      - ./workspace:/home/node/.openclaw/workspace

networks:
  openclaw-net:
    driver: bridge
COMPOSE_EOF
  success "Generated docker-compose.yml"
}

write_nginx_conf_if_missing() {
  [[ -f "nginx/nginx.conf" ]] && return 0
  section "Generating nginx/nginx.conf"
  mkdir -p nginx
  cat > nginx/nginx.conf << 'NGINX_EOF'
# Nginx configuration for OpenClaw local HTTPS.
#
# Enabled only with the Docker Compose profile "https-local".
# Terminates TLS and proxies to the OpenClaw gateway over the Docker network.

worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 50m;

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name _;

        ssl_certificate     /etc/nginx/certs/openclaw-local.pem;
        ssl_certificate_key /etc/nginx/certs/openclaw-local-key.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        # No HSTS for local IP-based services. HSTS can trap browsers into
        # hard failures when a local CA/certificate changes.
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location /health {
            access_log off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass http://openclaw-gateway:18789;
            proxy_http_version 1.1;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            # Rebuild this header from the socket peer. Never preserve a
            # client-supplied X-Forwarded-For value before trusting the proxy.
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $http_host;
            proxy_set_header X-Forwarded-Port $server_port;

            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 300s;
            proxy_buffering off;
            proxy_request_buffering off;
        }
    }
}
NGINX_EOF
  success "Generated nginx/nginx.conf"
}

write_openclaw_wrapper_if_missing() {
  [[ -f "openclaw" ]] && return 0
  section "Generating openclaw CLI wrapper"
  cat > openclaw << 'OPENCLAW_EOF'
#!/usr/bin/env bash
#
# OpenClaw Docker command wrapper.
#
# Use this instead of:
#   docker compose exec openclaw-gateway node dist/index.js ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  ./openclaw <command> [args...]

OpenClaw:
  onboard               Run OpenClaw onboarding
  dashboard             Print dashboard URL / pairing flow
  devices               List pending/known devices
  approve <request_id>  Approve a device pairing request
  doctor                Run OpenClaw doctor
  claude                Open Claude Code interactive TUI
  message <args>        Send a message (e.g. message send --target foo --message "hi")
  agent <args>          Talk to the assistant (e.g. agent --message "hi")
  update-version        Maintainers only (Git clone): bump .last-openclaw-version
  update [--verbose]    Update the stack and the image, back up and migrate your data
  pip <args>            Run pip inside the gateway container (e.g. pip install requests)

Stack:
  start                 Start Docker Compose stack
  stop                  Stop Docker Compose stack
  restart               Restart Docker Compose stack
  status                Show container status
  logs [service]        Follow logs
  shell                 Open shell inside CLI container

Raw CLI:
  Any unknown command is passed to OpenClaw inside Docker.

Examples:
  ./openclaw onboard
  ./openclaw dashboard
  ./openclaw devices
  ./openclaw approve abc123
  ./openclaw config get gateway.bind
USAGE
}

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

need_docker() {
  command -v docker >/dev/null 2>&1 || error "docker is required"
}

compose() {
  need_docker
  docker compose "$@"
}

compose_up() {
  compose --profile https-local up -d "$@"
}

compose_restart() {
  compose --profile https-local restart "$@"
}

# Update notice. Once a day, in the background, the wrapper asks the GitHub API
# for the latest stable release and caches the answer. Commands only read the
# cache, so the check never slows them down and never fails them.
# Disable it with OPENCLAW_NO_UPDATE_CHECK=1 in .env or in the environment.
UPDATE_CHECK_FILE=".update-check"
UPDATE_CHECK_URL="https://api.github.com/repos/luprintech/openclaw-nas-docker/releases/latest"
UPDATE_CHECK_INTERVAL=86400
DEFAULT_IMAGE="ghcr.io/luprintech/openclaw-nas-docker:latest"

update_check_disabled() {
  [[ "${OPENCLAW_NO_UPDATE_CHECK:-}" == "1" ]] && return 0
  [[ -f .env ]] && grep -qE '^OPENCLAW_NO_UPDATE_CHECK=1[[:space:]]*$' .env && return 0
  return 1
}

configured_image() {
  local image=""
  [[ -f .env ]] && image="$(sed -n 's/^OPENCLAW_IMAGE=//p' .env | tail -n 1 | tr -d "\"'[:space:]")"
  printf '%s\n' "${image:-$DEFAULT_IMAGE}"
}

refresh_update_cache() {
  local now checked=0 previous=""
  now="$(date +%s)"
  if [[ -f "$UPDATE_CHECK_FILE" ]]; then
    read -r checked previous < "$UPDATE_CHECK_FILE" || true
  fi
  [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
  (( now - checked < UPDATE_CHECK_INTERVAL )) && return 0
  command -v curl >/dev/null 2>&1 || return 0

  (
    latest="$(curl -fsS --max-time 5 -H 'Accept: application/vnd.github+json' "$UPDATE_CHECK_URL" |
      grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 |
      sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')" || latest=""
    # Keep the last known answer when GitHub cannot be reached.
    [[ "$latest" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || latest="$previous"
    printf '%s %s\n' "$now" "$latest" > "${UPDATE_CHECK_FILE}.tmp.$$"
    mv "${UPDATE_CHECK_FILE}.tmp.$$" "$UPDATE_CHECK_FILE"
  ) >/dev/null 2>&1 &
}

print_update_notice() {
  local latest="" installed image newest
  if [[ -f "$UPDATE_CHECK_FILE" ]]; then
    read -r _ latest < "$UPDATE_CHECK_FILE" || true
  fi
  [[ -n "$latest" ]] || return 0

  image="$(configured_image)"
  installed="$(docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image" 2>/dev/null)" || return 0
  [[ -n "$installed" && "$installed" != "$latest" ]] || return 0

  # Only announce versions newer than the installed one (edge may be ahead).
  newest="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -n 1)"
  [[ "$newest" == "$latest" ]] || return 0

  printf 'A new stable version of OpenClaw NAS Docker is available: %s (installed: %s).\n' \
    "$latest" "$installed" >&2
  if [[ "$image" != "$DEFAULT_IMAGE" ]]; then
    printf 'Your .env pins OPENCLAW_IMAGE=%s. Clear it to follow the stable channel, then run: ./openclaw update\n\n' \
      "$image" >&2
  else
    printf 'To install it, run: ./openclaw update\n\n' >&2
  fi
}

check_for_update() {
  [[ -t 2 ]] || return 0
  update_check_disabled && return 0
  command -v docker >/dev/null 2>&1 || return 0
  print_update_notice || true
  refresh_update_cache || true
}

normalize_legacy_image_override() {
  local current version backup_file temp_file

  [[ -f ".env" ]] || return 0

  # docker-compose.yml follows the latest published image only while
  # OPENCLAW_IMAGE is empty. Older installers wrote version pins that froze
  # every future update:
  #   - local image names (openclaw-nas-docker:...) cannot be pulled at all,
  #     so they are always cleared;
  #   - GHCR version pins are cleared once. OPENCLAW_IMAGE_PIN_MIGRATED=1
  #     records that, so a pin the user sets afterwards is respected.
  # Custom image names, :latest and :edge are kept.
  local migrated=false
  grep -q '^OPENCLAW_IMAGE_PIN_MIGRATED=1' .env && migrated=true

  current="$(sed -n 's/^OPENCLAW_IMAGE=//p' .env | head -n 1 | tr -d '\r')"
  case "$current" in
    openclaw-nas-docker:synology-*)
      version="${current#openclaw-nas-docker:synology-}"
      ;;
    openclaw-nas-docker:202*)
      version="${current#openclaw-nas-docker:}"
      ;;
    ghcr.io/luprintech/openclaw-nas-docker:202*)
      version="${current#ghcr.io/luprintech/openclaw-nas-docker:}"
      [[ "$migrated" == "true" ]] && version=""
      ;;
    *)
      version=""
      ;;
  esac

  if [[ "$migrated" != "true" ]]; then
    printf '\nOPENCLAW_IMAGE_PIN_MIGRATED=1\n' >> .env
  fi

  [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || return 0

  backup_file=".env.before-image-migration.$(date +%Y%m%d-%H%M%S)"
  temp_file=".env.tmp.$$"
  cp -p .env "$backup_file"
  awk '
    BEGIN { replaced = 0 }
    /^OPENCLAW_IMAGE=/ && !replaced {
      print "OPENCLAW_IMAGE="
      replaced = 1
      next
    }
    { print }
  ' .env > "$temp_file"
  mv "$temp_file" .env
  printf 'Removed the image version pin (%s) so updates follow the latest published image (backup: %s).\n' \
    "$current" "$backup_file"
}

print_update_banner() {
  if [[ -t 1 ]]; then printf '\033[0;31m'; fi
  echo "╔═════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                         ║"
  echo "║   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗  ║"
  echo "║  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║  ║"
  echo "║  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║  ║"
  echo "║  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║  ║"
  echo "║  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝  ║"
  echo "║   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝   ║"
  echo "║                                                                         ║"
  echo "║                    NAS Docker Updater by Luprintech                     ║"
  echo "║                                                                         ║"
  echo "╚═════════════════════════════════════════════════════════════════════════╝"
  if [[ -t 1 ]]; then printf '\033[0m'; fi
  printf '\n'
}

# ─── Update ───────────────────────────────────────────────────────────────────
# `./openclaw update` prints one line per step and writes the detailed output to
# logs/update-<date>.log. `./openclaw update --verbose` (or OPENCLAW_VERBOSE=1)
# prints everything instead. scripts/migrate-openclaw.sh continues the same
# numbered sequence.

UPDATE_TOTAL_STEPS=6

format_elapsed() {
  local seconds="$1"
  if (( seconds >= 60 )); then
    printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
  else
    printf '%ds' "$seconds"
  fi
}

# Shortens a live progress label to the terminal width. A line that wraps
# cannot be redrawn with \r, so on narrow terminals (a phone or tablet SSH
# client) every redraw would leave another copy of the line behind.
fit_to_terminal() {
  local text="$1" reserve="$2" cols max
  cols="$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)" || cols=""
  [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols=80
  max=$((cols - reserve))
  if (( max > 10 && ${#text} > max )); then
    text="${text:0:max}"
  fi
  printf '%s' "$text"
}

# update_step <step> <label> <command...>
# Steps are never called as `run_step ... || handler`: inside an || list bash
# ignores `set -e`, also in the background job, so a failing command would
# not fail the step. The step calls its failure handler itself instead.
update_step() {
  local step="$1" label="$2"
  shift 2
  local prefix="[$step/$UPDATE_TOTAL_STEPS] $label"

  if [[ "${OPENCLAW_VERBOSE:-0}" == "1" ]]; then
    printf '\n==> %s\n' "$prefix"
    "$@"
    return
  fi

  printf '\n==> %s\n' "$prefix" >> "$OPENCLAW_UPDATE_LOG"
  local start=$SECONDS pid rc=0
  "$@" < /dev/null >> "$OPENCLAW_UPDATE_LOG" 2>&1 &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[K%s... %s' "$(fit_to_terminal "$prefix" 12)" "$(format_elapsed $((SECONDS - start)))"
      sleep 1
    done
  else
    printf '%s... ' "$prefix"
  fi
  wait "$pid" || rc=$?

  local took
  took="$(format_elapsed $((SECONDS - start)))"
  local result="done"
  [[ "$rc" -eq 0 ]] || result="failed"
  if [[ -t 1 ]]; then
    printf '\r\033[K%s... %s (%s)\n' "$prefix" "$result" "$took"
  else
    printf '%s (%s)\n' "$result" "$took"
  fi
  [[ "$rc" -eq 0 ]] || update_failed
}

start_update_log() {
  [[ "${OPENCLAW_VERBOSE:-0}" == "1" ]] && return 0
  mkdir -p logs
  chmod 700 logs 2>/dev/null || true
  OPENCLAW_UPDATE_LOG="logs/update-$(date +%Y%m%d-%H%M%S).log"
  (umask 077 && : > "$OPENCLAW_UPDATE_LOG")
  export OPENCLAW_UPDATE_LOG
}

update_failed() {
  printf '\nThe update stopped before changing your data.\n' >&2
  if [[ -n "${OPENCLAW_UPDATE_LOG:-}" && -f "$OPENCLAW_UPDATE_LOG" ]]; then
    printf 'Last lines of the log:\n\n' >&2
    tail -n 20 "$OPENCLAW_UPDATE_LOG" | sed 's/^/    /' >&2
    printf '\nFull log: %s\n' "$OPENCLAW_UPDATE_LOG" >&2
  fi
  exit 1
}

# Download every stack file first, check it, then replace the old files. The
# running wrapper is replaced with mv, so this process keeps reading the old
# file instead of a half-written one.
sync_stack_files() {
  if [[ -d ".git" ]]; then
    command -v git >/dev/null 2>&1 || error "git is required to update a cloned repo"
    git pull --ff-only
    return
  fi

  local base="https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main"
  local files=(install.sh docker-compose.yml openclaw scripts/migrate-openclaw.sh)
  local tmp file
  tmp="$(mktemp -d .update-download.XXXXXX)"

  for file in "${files[@]}"; do
    mkdir -p "$tmp/$(dirname "$file")"
    if ! curl -fsSL "$base/$file" -o "$tmp/$file"; then
      rm -rf "$tmp"
      error "Could not download $file from GitHub. Check the NAS internet connection."
    fi
  done
  for file in install.sh openclaw scripts/migrate-openclaw.sh; do
    if ! bash -n "$tmp/$file"; then
      rm -rf "$tmp"
      error "The downloaded $file is not valid. Nothing was changed; try again later."
    fi
  done

  chmod +x "$tmp/install.sh" "$tmp/openclaw" "$tmp/scripts/migrate-openclaw.sh"
  mkdir -p scripts
  for file in "${files[@]}"; do
    mv -f "$tmp/$file" "$file"
  done
  rm -rf "$tmp"
  printf 'Stack files updated.\n'
}

cmd_update() {
  [[ "${1:-}" == "--verbose" ]] && export OPENCLAW_VERBOSE=1
  print_update_banner
  # The freshly downloaded wrapper re-enters below; do not repeat the banner.
  export OPENCLAW_UPDATE_BANNER_SHOWN=1
  start_update_log
  update_step 1 "Downloading the latest version of this stack" sync_stack_files

  # Re-enter the freshly downloaded wrapper so an older installed wrapper
  # still receives the migration workflow on its first update.
  exec "$SCRIPT_DIR/openclaw" __update_after_sync "$@"
}

cmd_update_after_sync() {
  [[ "${1:-}" == "--verbose" ]] && export OPENCLAW_VERBOSE=1
  [[ -n "${OPENCLAW_UPDATE_BANNER_SHOWN:-}" ]] || print_update_banner
  # An older wrapper downloaded the files without opening a log.
  [[ -n "${OPENCLAW_UPDATE_LOG:-}" ]] || start_update_log

  normalize_legacy_image_override
  update_step 2 "Downloading the OpenClaw image (can take a few minutes)" \
    compose --profile https-local pull --quiet

  # The backup is taken from the gateway container, so it must exist. Someone
  # who runs update wants OpenClaw running: start it instead of failing.
  if [[ -z "$(compose --profile https-local ps -aq openclaw-gateway 2>/dev/null)" ]]; then
    printf 'OpenClaw was not running; starting it before updating.\n'
    compose_up >> "${OPENCLAW_UPDATE_LOG:-/dev/null}" 2>&1 || update_failed
  fi

  OPENCLAW_UPDATE_STEP=2 OPENCLAW_UPDATE_TOTAL="$UPDATE_TOTAL_STEPS" \
    bash scripts/migrate-openclaw.sh upgrade
}

openclaw_cli() {
  # Go through entrypoint.sh so the command sees the provider keys from .env.
  compose exec openclaw-gateway /home/node/entrypoint.sh node dist/index.js "$@"
}

cmd_onboard() {
  openclaw_cli onboard --mode local --no-install-daemon "$@"
}

cmd_dashboard() {
  openclaw_cli dashboard --no-open "$@"
}

cmd_devices() {
  local subcommand="${1:-list}"
  if [[ "$subcommand" == "approve" ]]; then
    shift
    cmd_approve "$@"
  else
    openclaw_cli devices list "$@"
  fi
}

cmd_approve() {
  local request_id="${1:-}"
  [[ -n "$request_id" ]] || error "Missing request id. Use: ./openclaw approve <request_id>"
  openclaw_cli devices approve "$request_id"
}

cmd_claude() {
  compose --profile cli run --rm -it openclaw-cli claude "$@"
}

cmd_update_version() {
  [[ -x scripts/update-openclaw-version.sh ]] ||
    error "update-version is a maintainer command that needs a Git clone of the repository. To update your NAS, run: ./openclaw update"
  scripts/update-openclaw-version.sh "$@"
}

cmd_pip() {
  compose exec openclaw-gateway pip "$@"
}

main() {
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift || true

  case "$command" in
    help|-h|--help|update|__update_after_sync|update-version) ;;
    *) check_for_update ;;
  esac

  case "$command" in
    onboard) cmd_onboard "$@" ;;
    dashboard) cmd_dashboard "$@" ;;
    devices) cmd_devices "$@" ;;
    approve) cmd_approve "$@" ;;
    doctor) openclaw_cli doctor "$@" ;;
    claude) cmd_claude "$@" ;;
    message) openclaw_cli message "$@" ;;
    agent) openclaw_cli agent "$@" ;;
    update-version) cmd_update_version "$@" ;;
    update) cmd_update "$@" ;;
    __update_after_sync) cmd_update_after_sync "$@" ;;
    pip) cmd_pip "$@" ;;
    start|up) compose_up "$@" ;;
    stop|down) compose down "$@" ;;
    restart) compose_restart "$@" ;;
    status|ps) compose ps "$@" ;;
    logs) compose logs -f "$@" ;;
    shell) compose --profile cli run --rm -it openclaw-cli sh ;;
    help|-h|--help) usage ;;
    *) openclaw_cli "$command" "$@" ;;
  esac
}

main "$@"
OPENCLAW_EOF
  chmod +x openclaw
  success "Generated openclaw CLI wrapper"
}

generate_files_if_missing() {
  write_docker_compose
  write_nginx_conf_if_missing
  write_openclaw_wrapper_if_missing
}

# ─── Installation steps ───────────────────────────────────────────────────────

check_tools() {
  section "Checking required tools"
  need_command docker
  need_command awk
  need_command grep
  need_command cp
  need_command mv

  if docker compose version >/dev/null 2>&1; then
    success "Docker Compose v2 is available"
  else
    error "Docker Compose v2 is required. Expected: docker compose version"
  fi
}

check_legacy_containers() {
  section "Checking for legacy fixed-name containers"

  local legacy_names found
  legacy_names="openclaw-gateway openclaw-cli openclaw-nginx"
  found=false

  for name in $legacy_names; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      warn "Found existing container: $name"
      found=true
    fi
  done

  if [[ "$found" == "true" ]]; then
    cat <<'EOF'

Legacy OpenClaw containers were found. This usually means an older install used
fixed Docker container names.

Inspect them:
  docker ps -a --filter name=openclaw

If they belong to this old OpenClaw install and you want to replace them:
  docker stop openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true
  docker rm openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true

Then rerun:
  ./install.sh <your-nas-lan-ip>

EOF
    error "Stop here and remove/rename the legacy containers before continuing."
  fi

  success "No legacy fixed-name OpenClaw containers found"
}

prepare_runtime_dirs() {
  section "Preparing runtime directories"

  mkdir -p config workspace certs

  # The OpenClaw image runs as user node (UID/GID 1000). Most NAS systems create
  # bind-mount directories as the SSH user, which causes EACCES when
  # OpenClaw writes openclaw.json or workspace files.
  if chmod -R u+rwX config workspace 2>/dev/null; then
    success "Adjusted OpenClaw runtime directory permissions"
  else
    note "Could not chmod config/workspace as the current user; Docker repairs it next."
  fi

  if chown -R 1000:1000 config workspace 2>/dev/null; then
    success "Adjusted config/workspace ownership to UID/GID 1000"
  else
    note "Could not chown config/workspace as the current user; Docker repairs it next."
  fi

  if chmod -R u+rwX certs 2>/dev/null; then
    success "Adjusted certificate directory permissions"
  else
    note "Could not chmod certs as the current user."
  fi

  success "Ensured ./config exists"
  success "Ensured ./workspace exists"
  success "Ensured ./certs exists"
}

prepare_env() {
  local nas_ip="$1"

  section "Preparing environment"

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" << 'ENV_EOF'
# OpenClaw NAS configuration — generated by install.sh
TZ=
OPENCLAW_GATEWAY_TOKEN=
NAS_IP=
OPENCLAW_HOST_BIND=
OPENCLAW_GATEWAY_PORT=
OPENCLAW_PROXY_BIND=
OPENCLAW_HTTPS_PORT=
OPENCLAW_HTTPS_MODE=
OPENCLAW_IMAGE=
OPENCLAW_IMAGE_PIN_MIGRATED=1
# Optional AI provider keys. Onboarding can configure providers instead.
# After editing, apply them with: ./openclaw stop && ./openclaw start
# A non-empty ANTHROPIC_API_KEY makes Claude Code use API billing instead of
# an account login.
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
GEMINI_API_KEY=
OPENROUTER_API_KEY=
MISTRAL_API_KEY=
GROQ_API_KEY=
COHERE_API_KEY=
ENV_EOF
    success "Created .env"
  else
    success ".env already exists"
  fi

  local token
  token="$(env_get OPENCLAW_GATEWAY_TOKEN | tr -d '[:space:]')"
  if [[ -z "$token" ]]; then
    env_set OPENCLAW_GATEWAY_TOKEN "$(generate_token)"
    success "Generated OPENCLAW_GATEWAY_TOKEN"
  else
    success "OPENCLAW_GATEWAY_TOKEN already configured"
  fi

  local tz
  tz="$(env_get TZ | tr -d '[:space:]')"
  if [[ -z "$tz" || "$tz" == "Etc/Unknown" ]]; then
    tz="$(detect_timezone)"
    env_set TZ "$tz"
    success "Configured TZ=$tz"
    [[ "$tz" == "UTC" ]] && warn "Could not detect NAS timezone — defaulted to UTC. Edit TZ in .env if needed."
  else
    success "TZ=$tz already configured"
  fi

  env_set NAS_IP "$nas_ip"
  success "Configured NAS_IP=$nas_ip"

  env_set OPENCLAW_HTTPS_MODE "local"
  env_set OPENCLAW_HOST_BIND "127.0.0.1"
  env_set OPENCLAW_PROXY_BIND "$nas_ip"

  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  if [[ -z "$https_port" ]]; then
    env_set OPENCLAW_HTTPS_PORT "$DEFAULT_HTTPS_PORT"
    https_port="$DEFAULT_HTTPS_PORT"
  fi

  success "Configured HTTPS-only local access"
  success "OpenClaw raw gateway bound to 127.0.0.1:18789"
  success "Nginx HTTPS proxy bound to $nas_ip:$https_port"
}

repair_runtime_ownership() {
  section "Repairing OpenClaw runtime ownership"

  # Synology SSH users may not be able to chown a bind mount. Use the Docker
  # daemon with only the capabilities needed for this one-off ownership repair.
  if docker compose run --rm --no-deps --user 0 \
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH \
    --cap-add FOWNER \
    --entrypoint sh openclaw-gateway -lc \
    'chown -R 1000:1000 /home/node/.openclaw && chmod -R u+rwX /home/node/.openclaw' >/dev/null; then
    success "Adjusted OpenClaw runtime ownership through Docker"
  else
    error "Could not adjust OpenClaw runtime ownership through Docker"
  fi
}

pre_configure_gateway() {
  local nas_ip="$1"
  local https_port="$2"
  local config_file="config/openclaw.json"

  # Only pre-write on first install (file does not exist yet).
  # On re-installs the gateway has already initialized its config.
  [[ -f "$config_file" ]] && return 0

  section "Pre-configuring gateway"
  mkdir -p config

  printf '{\n  "gateway": {\n    "controlUi": {\n      "allowedOrigins": ["https://%s:%s"],\n      "dangerouslyAllowHostHeaderOriginFallback": false\n    }\n  }\n}\n' \
    "$nas_ip" "$https_port" > "$config_file"

  chown 1000:1000 "$config_file" 2>/dev/null || true
  chmod 644 "$config_file" 2>/dev/null || true

  success "Pre-configured gateway: https://${nas_ip}:${https_port}"
}

start_stack() {
  repair_runtime_ownership
  section "Starting OpenClaw Docker stack"
  docker compose --profile https-local up -d
  success "Docker stack started"
}

configure_gateway() {
  local nas_ip="$1"
  local https_port="$2"
  section "Configuring gateway"

  local allowed_origins="[\"https://${nas_ip}:${https_port}\"]"

  printf 'Waiting for gateway to be ready'
  local i=0
  until docker compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      printf '\n'
      warn "Gateway not ready after 60s. Run this manually when it's up:"
      warn "  docker compose exec openclaw-gateway node dist/index.js config set gateway.controlUi.allowedOrigins '${allowed_origins}'"
      return
    fi
    printf '.'
    sleep 2
  done
  printf '\n'
  success "Gateway is ready"

  # Wait for OpenClaw to finish internal config initialization.
  # healthz passes before config init completes on first boot.
  printf 'Waiting for gateway config initialization'
  sleep 10
  printf '\n'

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 15 node dist/index.js plugins disable bonjour 2>/dev/null' || true

  if docker compose exec -T openclaw-gateway \
    node dist/index.js config set gateway.controlUi.allowedOrigins "${allowed_origins}"; then
    success "Applied allowed origins: ${allowed_origins}"
  else
    warn "Could not apply allowed origins"
  fi

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 10 node dist/index.js config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback false' || true

  printf 'Restarting gateway to apply configuration'
  docker compose restart openclaw-gateway

  local j=0
  until docker compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    j=$((j + 1))
    if [[ $j -ge 30 ]]; then
      printf '\n'
      warn "Gateway did not come back healthy after restart. Check: docker compose logs openclaw-gateway"
      return
    fi
    printf '.'
    sleep 2
  done
  printf '\n'

  # Verify the config survived the restart
  local actual_origins
  actual_origins="$(docker compose exec -T openclaw-gateway node dist/index.js config get gateway.controlUi.allowedOrigins 2>/dev/null || echo '')"
  if echo "$actual_origins" | grep -q "https://${nas_ip}"; then
    success "Gateway restarted and configuration is active"
  else
    note "Config was reset after restart; applying it again."
    docker compose exec -T openclaw-gateway \
      node dist/index.js config set gateway.controlUi.allowedOrigins "${allowed_origins}" 2>/dev/null || true
    sleep 3
    docker compose restart openclaw-gateway
    sleep 10
    success "Gateway restarted with forced configuration"
  fi
}

ensure_migration_helper() {
  mkdir -p scripts
  if [[ -f "scripts/migrate-openclaw.sh" ]]; then
    chmod +x scripts/migrate-openclaw.sh
    return
  fi

  section "Installing NAS migration helper"
  curl -fsSL "$RAW_BASE_URL/scripts/migrate-openclaw.sh" -o scripts/migrate-openclaw.sh
  chmod +x scripts/migrate-openclaw.sh
  success "Installed migration helper"
}

print_next_steps() {
  local nas_ip="$1"
  local https_port warnings
  https_port="$(install_https_port)"
  warnings="$(grep -c . "$WARN_FILE" 2>/dev/null || true)"

  if [[ "${warnings:-0}" -gt 0 ]]; then
    printf '\n%b! OpenClaw is installed and running, with %s warning(s):%b\n' "$YELLOW" "$warnings" "$NC"
    sed 's/^/  - /' "$WARN_FILE"
  else
    printf '\n%b✓ OpenClaw is installed and running.%b\n' "$GREEN" "$NC"
  fi

  printf '\n  Open: %bhttps://%s:%s%b\n' "$BOLD" "$nas_ip" "$https_port" "$NC"

  printf '\n%bNext steps%b\n' "$BOLD" "$NC"
  printf '  1. Trust the certificate on every device that will open OpenClaw:\n'
  printf '       Windows:                       %s/certs/rootCA.cer\n' "$SCRIPT_DIR"
  printf '       macOS, iPhone, Android, Linux: %s/certs/rootCA.pem\n' "$SCRIPT_DIR"
  printf '  2. Set up your AI provider:  %b./openclaw onboard%b\n' "$BLUE" "$NC"
  printf '  3. Pair your browser:        %b./openclaw dashboard%b, then %b./openclaw devices%b and %b./openclaw approve <request_id>%b\n' \
    "$BLUE" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"

  printf '\n%bEveryday commands%b\n' "$BOLD" "$NC"
  printf '  %b./openclaw status%b   container status\n' "$BLUE" "$NC"
  printf '  %b./openclaw update%b   update OpenClaw safely\n' "$BLUE" "$NC"
  printf '  %b./openclaw help%b     all commands\n' "$BLUE" "$NC"

  [[ -n "$LOG_FILE" ]] && printf '\n  Install log: %s\n' "$LOG_FILE"
  printf '\n%bKeep OpenClaw LAN-only: do not port-forward it on your router.%b\n' "$YELLOW" "$NC"
  printf '\n⭐ Useful? Star the project so other NAS users can find it:\n'
  printf '   https://github.com/Luprintech/openclaw-nas-docker\n\n'
}

# ─── Entry point ──────────────────────────────────────────────────────────────

NAS_IP_ARG=""
WRAPPER_ONLY=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --wrapper-only)
        WRAPPER_ONLY=true
        shift
        ;;
      --*)
        error "Unknown option: $1"
        ;;
      *)
        if [[ -n "$NAS_IP_ARG" ]]; then
          error "Unexpected extra argument: $1"
        fi
        NAS_IP_ARG="$1"
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "$WRAPPER_ONLY" == "true" ]]; then
    rm -f openclaw
    write_openclaw_wrapper_if_missing
    exit 0
  fi

  local nas_ip
  nas_ip="$(detect_nas_ip "$NAS_IP_ARG")"

  print_banner
  printf 'Installing OpenClaw on %s. Access will be HTTPS-only and limited to your LAN.\n' "$nas_ip"

  setup_install_log
  run_step "Checking requirements" step_check
  run_step "Preparing files, configuration and HTTPS certificate" step_prepare "$nas_ip"
  run_step "Downloading OpenClaw (the first time can take several minutes)" step_download
  run_step "Starting OpenClaw" start_stack
  run_step "Configuring access" step_configure "$nas_ip"

  print_next_steps "$nas_ip"
}

install_https_port() {
  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  printf '%s\n' "${https_port:-$DEFAULT_HTTPS_PORT}"
}

step_check() {
  check_tools
  check_legacy_containers
}

step_prepare() {
  generate_files_if_missing
  ensure_migration_helper
  prepare_runtime_dirs
  prepare_env "$1"
  generate_https_certs_if_needed "$1"
  validate_env_inline
  pre_configure_gateway "$1" "$(install_https_port)"
}

step_download() {
  docker compose --profile https-local pull --quiet
}

step_configure() {
  configure_gateway "$1" "$(install_https_port)"
  bash scripts/migrate-openclaw.sh configure-proxy
}

main "$@"
