#!/usr/bin/env bash
# install.sh embeds full copies of some repository files so that a single
# downloaded script can install the stack. This check fails when an embedded
# copy and its source file drift apart.
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

check_copy() {
  local file="$1" marker="$2" embedded

  embedded="$(mktemp)"
  awk -v m="$marker" '
    found && $0 == m { exit }
    found { print }
    index($0, "<< '\''" m "'\''") { found = 1 }
  ' install.sh > "$embedded"

  if [ ! -s "$embedded" ]; then
    echo "FAIL $file: marker $marker not found in install.sh"
    status=1
  elif diff -u --label "install.sh ($marker)" --label "$file" "$embedded" "$file"; then
    echo "OK   $file"
  else
    echo "FAIL $file: differs from the copy embedded in install.sh"
    status=1
  fi

  rm -f "$embedded"
}

check_copy docker-compose.yml COMPOSE_EOF
check_copy nginx/nginx.conf NGINX_EOF
check_copy openclaw OPENCLAW_EOF

exit "$status"
