#!/bin/sh
set -e

VENV_DIR="/home/node/.openclaw/python-venv"

if [ ! -d "$VENV_DIR" ]; then
  echo "[openclaw] Creating Python venv at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

# docker-compose.yml passes the provider keys from .env as
# OPENCLAW_NAS_ENV_<NAME>, empty when unset. Export only the non-empty ones
# under their real names, so an empty value never hides a key that the user
# stored in ~/.openclaw/.env (config/.env on the NAS).
for name in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
            MISTRAL_API_KEY GROQ_API_KEY COHERE_API_KEY; do
  eval "value=\${OPENCLAW_NAS_ENV_${name}:-}"
  unset "OPENCLAW_NAS_ENV_${name}"
  if [ -n "$value" ]; then
    export "${name}=${value}"
  fi
done
unset name value

exec "$@"
