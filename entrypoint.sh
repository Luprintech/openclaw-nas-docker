#!/bin/sh
set -e

VENV_DIR="/home/node/.openclaw/python-venv"

if [ ! -d "$VENV_DIR" ]; then
  echo "[openclaw] Creating Python venv at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

exec "$@"
