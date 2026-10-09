#!/usr/bin/env bash
#
# Safe OpenClaw maintenance for NAS bind mounts.
#
# OpenClaw state is owned by UID 1000 inside the container.  NAS users can
# therefore be unable to copy or rewrite config files directly over SSH.  This
# helper performs backups and migrations through Docker, which has access to
# the bind mount through the daemon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BACKUP_ROOT="${OPENCLAW_BACKUP_ROOT:-$PROJECT_DIR}"

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
}

compose() {
  docker compose --profile https-local "$@"
}

gateway_container() {
  compose ps -aq openclaw-gateway
}

nginx_container() {
  compose ps -q nginx
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

configure_gateway_proxy() {
  local container proxy_ip
  container="$(nginx_container)"
  [[ -n "$container" ]] || error "Nginx container is not running"
  proxy_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
  [[ "$proxy_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "Could not determine Nginx container IP"

  compose run --rm --no-deps -e "OPENCLAW_PROXY_IP=$proxy_ip" --entrypoint node openclaw-gateway -e \
    'const fs=require("fs");const p="/home/node/.openclaw/openclaw.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));c.gateway=c.gateway||{};c.gateway.trustedProxies=[process.env.OPENCLAW_PROXY_IP];fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n");console.log("trustedProxies:",JSON.stringify(c.gateway.trustedProxies));' \
    OPENCLAW_PROXY_IP="$proxy_ip"
}

repair_runtime_ownership() {
  # Older releases could leave persisted files owned by root. Restore the
  # runtime tree to the unprivileged node user so plugin installation can
  # safely apply its final file modes.
  if compose run --rm --no-deps --user 0 \
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
  compose run --rm --no-deps --entrypoint node openclaw-gateway -e '
    const fs = require("fs");
    const JSON5 = require("json5");
    const path = "/home/node/.openclaw/openclaw.json";
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
    fs.writeFileSync(path, JSON.stringify(config, null, 2) + "\n");
    if (repairedTrailingLiteral) console.log("Repaired a trailing literal backslash-n sequence.");
    console.log("Removed legacy config keys:", removed.length ? removed.join(", ") : "none");
  '
}

run_migrations() {
  local container backup_dir
  container="$(gateway_container)"
  [[ -n "$container" ]] || error "OpenClaw gateway container is not available for backup"

  backup_dir="$(backup_state "$container")"
  printf 'Backup created: %s\n' "$backup_dir"

  compose stop openclaw-gateway >/dev/null
  repair_runtime_ownership
  normalize_legacy_config

  # --fix performs the general state migrations.  On NAS bind mounts it may
  # report EPERM from fchmod after committing some migrations; the dedicated
  # session import below is still required and has its own validation output.
  compose run --rm --no-deps openclaw-gateway openclaw doctor --fix || \
    warn "General doctor repair reported an error; continuing with session import."

  compose run --rm --no-deps openclaw-gateway \
    openclaw doctor --session-sqlite import --session-sqlite-all-agents --non-interactive || \
    warn "Session SQLite import reported an error; continuing with gateway startup."
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
  compose stop openclaw-gateway >/dev/null || true
  configure_gateway_proxy
  compose up -d openclaw-gateway >/dev/null
  wait_for_gateway
  compose restart nginx >/dev/null
}

upgrade() {
  local container
  container="$(gateway_container)"
  [[ -n "$container" ]] || error "OpenClaw gateway container is not running; start the stack before updating."

  run_migrations
  configure_proxy
  printf 'OpenClaw maintenance completed. Verify with: docker compose ps\n'
}

case "${1:-upgrade}" in
  configure-proxy)
    configure_proxy
    ;;
  upgrade)
    upgrade
    ;;
  *)
    error "Usage: scripts/migrate-openclaw.sh {upgrade|configure-proxy}"
    ;;
esac
