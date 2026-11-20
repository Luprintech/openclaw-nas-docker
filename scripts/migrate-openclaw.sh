#!/usr/bin/env bash
#
# Safe OpenClaw maintenance for NAS bind mounts.
#
# OpenClaw state is owned by UID 1000 inside the container.  NAS users can
# therefore be unable to copy or rewrite config files directly over SSH.  This
# helper performs backups and migrations through Docker, which has access to
# the bind mount through the daemon.
#
# `upgrade` shows one line per step and writes the detailed output to
# logs/update-<date>.log. Set OPENCLAW_VERBOSE=1 to print everything instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BACKUP_ROOT="${OPENCLAW_BACKUP_ROOT:-$PROJECT_DIR}"
# Backups kept after a successful update, the new one included. 0 keeps all.
KEEP_BACKUPS="${OPENCLAW_KEEP_BACKUPS:-2}"
# Seconds to wait for a clean gateway shutdown before Docker kills it.
STOP_TIMEOUT="${OPENCLAW_STOP_TIMEOUT:-90}"
VERBOSE="${OPENCLAW_VERBOSE:-0}"
# The wrapper passes its log file and step counter so the update reads as one
# numbered sequence.
LOG_FILE="${OPENCLAW_UPDATE_LOG:-}"
STEP_NUM="${OPENCLAW_UPDATE_STEP:-0}"
STEP_TOTAL="${OPENCLAW_UPDATE_TOTAL:-4}"

STATE_DIR="$(mktemp -d)"
WARN_FILE="$STATE_DIR/warnings"
: > "$WARN_FILE"
trap 'rm -rf "$STATE_DIR"' EXIT

if [[ -t 1 ]]; then
  GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m' BOLD='\033[1m' NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' NC=''
fi

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

# Warnings are collected in a file because steps run in a subshell.
warn() {
  printf 'WARN: %s\n' "$1" >&2
  printf '%s\n' "$1" >> "$WARN_FILE"
}

warning_count() {
  grep -c . "$WARN_FILE" 2>/dev/null || true
}

# ─── Step output ──────────────────────────────────────────────────────────────

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
    printf '\n%b==> %s%b\n' "$BOLD" "$prefix" "$NC"
    "$@"
    return
  fi

  printf '\n==> %s\n' "$prefix" >> "$LOG_FILE"
  local start=$SECONDS pid rc=0
  "$@" < /dev/null >> "$LOG_FILE" 2>&1 &
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
  [[ "$rc" -eq 0 ]] || fail_update
}

setup_log() {
  [[ "$VERBOSE" == "1" || -n "$LOG_FILE" ]] && return 0
  mkdir -p logs
  chmod 700 logs 2>/dev/null || true
  LOG_FILE="logs/update-$(date +%Y%m%d-%H%M%S).log"
  (umask 077 && : > "$LOG_FILE")
}

# Keep the ten most recent update logs. Names contain the date, so the glob is
# already in chronological order.
prune_logs() {
  local logs=(logs/update-*.log)
  [[ -e "${logs[0]}" ]] || return 0
  local extra=$((${#logs[@]} - 10))
  (( extra > 0 )) && rm -f "${logs[@]:0:extra}"
  return 0
}

# Keep the most recent backups after a successful update. Only folders that
# match the exact name the updater creates are touched, and a failed update
# never gets here, so the backup taken before it is always kept.
prune_backups() {
  [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { warn "OPENCLAW_KEEP_BACKUPS must be a number; no backups were removed."; return 0; }
  (( KEEP_BACKUPS > 0 )) || return 0

  local d backups=()
  for d in "$BACKUP_ROOT"/openclaw-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
    [[ -d "$d" && ! -L "$d" ]] && backups+=("$d")
  done

  local extra=$((${#backups[@]} - KEEP_BACKUPS))
  (( extra > 0 )) || return 0
  for d in "${backups[@]:0:extra}"; do
    if rm -rf -- "$d"; then
      [[ -n "$LOG_FILE" ]] && printf 'Removed old backup: %s\n' "$d" >> "$LOG_FILE"
    else
      warn "Could not remove the old backup $d; delete it by hand."
    fi
  done
  return 0
}

# ─── Docker helpers ───────────────────────────────────────────────────────────

compose() {
  docker compose --profile https-local "$@"
}

gateway_container() {
  compose ps -aq openclaw-gateway
}

nginx_container() {
  compose ps -q nginx
}

# Stop the gateway and report when Docker had to kill it: a killed gateway
# leaves its state lock behind and doctor cannot enter maintenance.
stop_gateway() {
  local container exit_code
  container="$(gateway_container)"
  compose stop -t "$STOP_TIMEOUT" openclaw-gateway
  [[ -n "$container" ]] || return 0
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == "true" ]]; then
    error "The gateway is still running after the stop request; the migration was not started."
  fi
  exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$container" 2>/dev/null || true)"
  if [[ "$exit_code" == "137" ]]; then
    warn "The gateway did not stop within ${STOP_TIMEOUT}s and was killed; its state lock may block the migration."
  fi
}

backup_state() {
  local container="$1"
  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_ROOT/openclaw-backup-$stamp"
  mkdir -p "$backup_dir"

  cp -a .env docker-compose.yml nginx "$backup_dir/" 2>/dev/null || true
  docker cp "$container:/home/node/.openclaw" "$backup_dir/openclaw-home" >/dev/null
  printf '%s\n' "$backup_dir"
}

patch_nginx_forwarded_headers() {
  local nginx_file="nginx/nginx.conf"
  [[ -f "$nginx_file" ]] || error "Missing $nginx_file"

  if grep -q "proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" "$nginx_file"; then
    sed -i "s|proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;|proxy_set_header X-Forwarded-For \$remote_addr;|" "$nginx_file"
    printf 'Updated Nginx to overwrite X-Forwarded-For safely.\n'
  fi
}

# Trust only the current Nginx container IP, and set gateway.mode=local when it
# is unset: this stack always runs the gateway locally, and recent OpenClaw
# releases refuse to start a gateway without a mode.
configure_gateway_proxy() {
  local container proxy_ip
  container="$(nginx_container)"
  [[ -n "$container" ]] || error "Nginx container is not running"
  proxy_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
  [[ "$proxy_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "Could not determine Nginx container IP"

  compose run --rm -T --no-deps -e "OPENCLAW_PROXY_IP=$proxy_ip" --entrypoint node openclaw-gateway -e \
    'const fs=require("fs");const p="/home/node/.openclaw/openclaw.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));c.gateway=c.gateway||{};c.gateway.trustedProxies=[process.env.OPENCLAW_PROXY_IP];if(!c.gateway.mode){c.gateway.mode="local";console.log("gateway.mode: local");}fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n");console.log("trustedProxies:",JSON.stringify(c.gateway.trustedProxies));' \
    OPENCLAW_PROXY_IP="$proxy_ip"
}

repair_runtime_ownership() {
  # Older releases could leave persisted files owned by root. Restore the
  # runtime tree to the unprivileged node user so plugin installation can
  # safely apply its final file modes.
  if compose run --rm -T --no-deps --user 0 \
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH \
    --cap-add FOWNER \
    --entrypoint sh openclaw-gateway -lc \
    'chown -R 1000:1000 /home/node/.openclaw && chmod -R u+rwX /home/node/.openclaw' >/dev/null; then
    printf 'Repaired OpenClaw runtime ownership.\n'
  else
    error 'Could not repair OpenClaw runtime ownership; no migrations were applied.'
  fi
}

normalize_legacy_config() {
  # shellcheck disable=SC2016 # Node code is intentionally passed as a literal argument.
  compose run --rm -T --no-deps --entrypoint node openclaw-gateway -e '
    const fs = require("fs");
    const JSON5 = require("json5");
    const path = "/home/node/.openclaw/openclaw.json";
    if (!fs.existsSync(path)) {
      console.log("No openclaw.json yet; nothing to normalize.");
      process.exit(0);
    }
    let raw = fs.readFileSync(path, "utf8");
    const literalBackslashNewline = String.raw`\n`;
    const trimmed = raw.trimEnd();
    const repairedTrailingLiteral = trimmed.endsWith(literalBackslashNewline);
    if (repairedTrailingLiteral) raw = trimmed.slice(0, -literalBackslashNewline.length) + "\n";
    const config = JSON5.parse(raw);
    const removed = [];
    const remove = (object, key, label) => {
      if (object && Object.hasOwn(object, key)) {
        delete object[key];
        removed.push(label);
      }
    };
    remove(config.meta, "lastTouchedAt", "meta.lastTouchedAt");
    remove(config.gateway && config.gateway.controlUi, "allowInsecureAuth", "gateway.controlUi.allowInsecureAuth");
    remove(config.gateway && config.gateway.tailscale, "resetOnExit", "gateway.tailscale.resetOnExit");
    remove(config.gateway && config.gateway.nodes, "denyCommands", "gateway.nodes.denyCommands");
    // This stack always runs the gateway locally; set it before doctor runs so
    // doctor does not report the gateway start as blocked.
    config.gateway = config.gateway || {};
    if (!config.gateway.mode) {
      config.gateway.mode = "local";
      console.log("Set gateway.mode to local.");
    }
    fs.writeFileSync(path, JSON.stringify(config, null, 2) + "\n");
    if (repairedTrailingLiteral) console.log("Repaired a trailing literal backslash-n sequence.");
    console.log("Removed legacy config keys:", removed.length ? removed.join(", ") : "none");
  '
}

# State migrations. The gateway must already be stopped.
migrate_state() {
  repair_runtime_ownership
  normalize_legacy_config

  # The non-interactive repair path is the one OpenClaw's own updater uses. On
  # NAS bind mounts it may report EPERM from fchmod after committing some
  # migrations; the dedicated session import below is still required.
  compose run --rm -T --no-deps openclaw-gateway openclaw doctor --fix --non-interactive || \
    warn "OpenClaw doctor reported an error while repairing your data."

  compose run --rm -T --no-deps openclaw-gateway \
    openclaw doctor --session-sqlite import --session-sqlite-all-agents --non-interactive || \
    warn "The session import reported an error."
}

wait_for_gateway() {
  local i=0
  until compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    i=$((i + 1))
    [[ "$i" -lt 60 ]] || error "Gateway did not become healthy. Check: docker compose logs openclaw-gateway"
    sleep 2
  done
}

configure_proxy() {
  patch_nginx_forwarded_headers
  compose stop -t "$STOP_TIMEOUT" openclaw-gateway || true
  configure_gateway_proxy
  compose up -d openclaw-gateway
  wait_for_gateway
  compose restart nginx
}

# ─── Commands ─────────────────────────────────────────────────────────────────

# Plain output, used by the CI smoke test.
run_migrations() {
  local container backup_dir
  container="$(gateway_container)"
  [[ -n "$container" ]] || error "OpenClaw gateway container is not available for backup"

  backup_dir="$(backup_state "$container")"
  printf 'Backup created: %s\n' "$backup_dir"
  stop_gateway
  migrate_state
}

step_backup() {
  backup_state "$1" > "$STATE_DIR/backup_dir"
  printf 'Backup created: %s\n' "$(cat "$STATE_DIR/backup_dir")"
}

env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1 | tr -d '\r[:space:]'
}

# The actions that OpenClaw doctor lists under "Fix now:" in the log.
doctor_actions() {
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || return 0
  awk '/^Fix now:/ {on=1; next} on && /^(Doctor:|│|└|┌|◇)/ {on=0} on' "$LOG_FILE" \
    | sed 's/\x1b\[[0-9;]*m//g' | awk 'NF'
}

fail_update() {
  local backup_dir=""
  [[ -f "$STATE_DIR/backup_dir" ]] && backup_dir="$(cat "$STATE_DIR/backup_dir")"
  printf '\n%b✗ The update did not finish.%b\n' "$RED" "$NC"
  [[ -n "$backup_dir" ]] && printf '  Your data is backed up in: %s\n' "$backup_dir"
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '  Last lines of the log:\n\n'
    tail -n 25 "$LOG_FILE" | sed 's/^/    /'
    printf '\n  Full log: %s\n' "$LOG_FILE"
  fi
  printf '  Do not restart the gateway repeatedly. See "Troubleshooting" in the README.\n'
  exit 1
}

print_summary() {
  local version url backup_dir warnings actions
  version="$(compose exec -T openclaw-gateway node dist/index.js --version 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
  url="https://$(env_value NAS_IP):$(env_value OPENCLAW_HTTPS_PORT)"
  backup_dir="$(cat "$STATE_DIR/backup_dir" 2>/dev/null || true)"
  warnings="$(warning_count)"

  if [[ "$warnings" -gt 0 ]]; then
    printf '\n%b! OpenClaw is running, but the update finished with %s warning(s):%b\n' "$YELLOW" "$warnings" "$NC"
    sed 's/^/  - /' "$WARN_FILE"
    printf '  Wait a minute and run ./openclaw update again. If the warnings persist, check the log.\n'
  else
    printf '\n%b✓ OpenClaw is up to date and running.%b\n' "$GREEN" "$NC"
  fi

  [[ -n "$version" ]] && printf '  Version: %s\n' "$version"
  printf '  Open:    %s\n' "$url"
  [[ -n "$backup_dir" ]] && printf '  Backup:  %s\n' "$backup_dir"
  [[ -n "$LOG_FILE" ]] && printf '  Log:     %s\n' "$LOG_FILE"

  actions="$(doctor_actions)"
  if [[ -n "$actions" ]]; then
    printf '\n%bOpenClaw doctor recommends:%b\n' "$BOLD" "$NC"
    printf '%s\n' "$actions" | sed 's/^/  /'
  fi
}

upgrade() {
  local container
  container="$(gateway_container)"
  [[ -n "$container" ]] || error "OpenClaw gateway container is not running; start the stack with ./openclaw start, then run ./openclaw update again."

  setup_log
  run_step "Backing up your data" step_backup "$container"
  run_step "Stopping OpenClaw" stop_gateway
  run_step "Updating your data (can take several minutes)" migrate_state
  run_step "Starting OpenClaw" configure_proxy
  prune_backups
  print_summary
  prune_logs
}

case "${1:-upgrade}" in
  migrate)
    # State migrations only, without touching Nginx or starting the gateway.
    # Used by the CI smoke test.
    run_migrations
    ;;
  configure-proxy)
    configure_proxy
    ;;
  upgrade)
    upgrade
    ;;
  *)
    error "Usage: scripts/migrate-openclaw.sh {upgrade|migrate|configure-proxy}"
    ;;
esac
