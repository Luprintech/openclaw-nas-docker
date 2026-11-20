#!/usr/bin/env bash
#
# Smoke test de una versión candidata de OpenClaw, pensado para CI (también
# se puede lanzar a mano en cualquier máquina con Docker).
#
# Qué comprueba:
#   1. Instalación limpia: el gateway arranca y Docker lo marca como healthy.
#   2. Actualización: arranca la versión publicada actualmente, la para,
#      ejecuta la misma migración que usa un usuario (scripts/migrate-openclaw.sh)
#      y arranca la candidata sobre el mismo ./config.
#   3. Que el gateway NO queda degradado. /healthz responde "healthy" aunque la
#      base de datos del agente esté sin migrar, así que también se vigilan
#      los logs durante un tiempo de espera.
#   4. Que el CLI de Claude Code incluido en la imagen funciona.
#
# Uso:
#   scripts/smoke-test.sh <imagen-candidata> [imagen-anterior]
#
# Limitación: un runner de CI usa un kernel moderno, así que esto no detecta
# problemas específicos del kernel 4.4 de algunos Synology (sin openat2).

set -euo pipefail

CANDIDATE="${1:?Uso: $0 <imagen-candidata> [imagen-anterior]}"
PREVIOUS="${2:-}"
TIMEOUT="${SMOKE_TIMEOUT:-300}"
SETTLE="${SMOKE_SETTLE:-150}"
PROJECT="openclaw-smoke"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

export OPENCLAW_HOST_BIND=127.0.0.1
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
export TZ=UTC
export COMPOSE_PROJECT_NAME="$PROJECT"
export OPENCLAW_BACKUP_ROOT="${RUNNER_TEMP:-/tmp}/openclaw-smoke-backups"
OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
export OPENCLAW_GATEWAY_TOKEN
# Claves de proveedor ficticias para comprobar entrypoint.sh: una con valor
# debe llegar al contenedor y una vacía no debe existir.
export GROQ_API_KEY="smoke-test-dummy"
export COHERE_API_KEY=""

compose() {
  docker compose -p "$PROJECT" "$@"
}

cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
  local label="$1" cid status elapsed=0
  cid="$(compose ps -q openclaw-gateway)"
  [[ -n "$cid" ]] || { echo "ERROR [$label]: el contenedor no existe"; return 1; }

  while (( elapsed < TIMEOUT )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    case "$status" in
      healthy)
        echo "OK [$label]: gateway healthy tras ${elapsed}s"
        return 0
        ;;
      unhealthy)
        echo "ERROR [$label]: gateway unhealthy"
        compose logs --no-color --tail 200 openclaw-gateway || true
        return 1
        ;;
    esac
    if [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]]; then
      echo "ERROR [$label]: el contenedor se ha parado"
      compose logs --no-color --tail 200 openclaw-gateway || true
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "ERROR [$label]: sin estado healthy tras ${TIMEOUT}s"
  compose logs --no-color --tail 200 openclaw-gateway || true
  return 1
}

# El estado "healthy" no basta: la base de datos del agente se prepara después
# de abrir el puerto y, si no está migrada, el gateway queda degradado con las
# sesiones caídas. Se observan los logs durante SETTLE segundos.
assert_not_degraded() {
  local label="$1" elapsed=0
  while (( elapsed < SETTLE )); do
    if compose logs --no-color openclaw-gateway 2>&1 | grep -qi "remains degraded"; then
      echo "ERROR [$label]: el gateway quedó degradado"
      compose logs --no-color --tail 200 openclaw-gateway | grep -i -B2 -A2 "degraded" || true
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "OK [$label]: sin degradación tras ${SETTLE}s"
}

start_with() {
  local image="$1"
  OPENCLAW_IMAGE="$image" compose up -d openclaw-gateway
}

# ./config y ./workspace los usa el usuario node (UID 1000) dentro del contenedor.
prepare_dirs() {
  rm -rf config workspace
  mkdir -p config workspace
  sudo chown -R 1000:1000 config workspace 2>/dev/null || chown -R 1000:1000 config workspace
}

prepare_dirs
PREVIOUS_RAN=false

# --- Fase 1: actualización desde la versión publicada --------------------
if [[ -n "$PREVIOUS" ]] && docker pull "$PREVIOUS" >/dev/null 2>&1; then
  echo "== Fase 1: versión anterior ($PREVIOUS) =="
  start_with "$PREVIOUS"
  wait_healthy "anterior"
  compose stop openclaw-gateway
  PREVIOUS_RAN=true
else
  echo "AVISO: no se pudo descargar la imagen anterior, se omite la prueba de actualización."
  prepare_dirs
fi

# --- Fase 2: candidata (sobre el estado de la fase 1, si existe) ---------
echo "== Fase 2: candidata ($CANDIDATE) =="
if [[ "$PREVIOUS_RAN" == "true" ]]; then
  echo "== Migración de estado con la imagen candidata =="
  OPENCLAW_IMAGE="$CANDIDATE" bash scripts/migrate-openclaw.sh migrate
fi
start_with "$CANDIDATE"
wait_healthy "candidata"
assert_not_degraded "candidata"

echo "== Comprobando CLI de Claude Code =="
compose exec -T openclaw-gateway claude --version
compose --profile cli run --rm -T openclaw-cli claude --version

echo "== Comprobando el paso de claves de proveedor =="
for svc in gateway cli; do
  if [[ "$svc" == "gateway" ]]; then
    # Entorno del proceso del gateway (un `exec` no pasa por el entrypoint).
    # shellcheck disable=SC2016  # se expande dentro del contenedor
    env_dump="$(compose exec -T openclaw-gateway sh -c '
      for p in /proc/[0-9]*; do
        if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q "dist/index.js gateway"; then
          tr "\0" "\n" < "$p/environ"; break
        fi
      done')"
  else
    env_dump="$(compose --profile cli run --rm -T openclaw-cli env)"
  fi
  grep -qx 'GROQ_API_KEY=smoke-test-dummy' <<<"$env_dump" ||
    { echo "ERROR ($svc): GROQ_API_KEY no llega al contenedor."; exit 1; }
  if grep -q '^COHERE_API_KEY=' <<<"$env_dump"; then
    echo "ERROR ($svc): una clave vacía no debe exportarse."; exit 1
  fi
  if grep -q '^OPENCLAW_NAS_ENV_' <<<"$env_dump"; then
    echo "ERROR ($svc): quedan variables OPENCLAW_NAS_ENV_ sin limpiar."; exit 1
  fi
done

echo "Smoke test superado."
