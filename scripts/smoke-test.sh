#!/usr/bin/env bash
#
# Smoke test de una versión candidata de OpenClaw, pensado para CI (también
# se puede lanzar a mano en cualquier máquina con Docker).
#
# Qué comprueba:
#   1. Instalación limpia: el gateway arranca y Docker lo marca como healthy.
#   2. Actualización: arranca la versión publicada actualmente, la para y
#      arranca la candidata sobre el mismo ./config (migración de estado).
#   3. Que el CLI de Claude Code incluido en la imagen funciona.
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
PROJECT="openclaw-smoke"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

export OPENCLAW_HOST_BIND=127.0.0.1
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
export TZ=UTC
OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
export OPENCLAW_GATEWAY_TOKEN

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

# --- Fase 1: actualización desde la versión publicada --------------------
if [[ -n "$PREVIOUS" ]] && docker pull "$PREVIOUS" >/dev/null 2>&1; then
  echo "== Fase 1: versión anterior ($PREVIOUS) =="
  start_with "$PREVIOUS"
  wait_healthy "anterior"
  compose stop openclaw-gateway
  compose rm -f openclaw-gateway >/dev/null
else
  echo "AVISO: no se pudo descargar la imagen anterior, se omite la prueba de actualización."
  prepare_dirs
fi

# --- Fase 2: candidata (sobre el estado de la fase 1, si existe) ---------
echo "== Fase 2: candidata ($CANDIDATE) =="
start_with "$CANDIDATE"
wait_healthy "candidata"

echo "== Comprobando CLI de Claude Code =="
compose exec -T openclaw-gateway claude --version

echo "Smoke test superado."
