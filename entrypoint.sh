#!/bin/sh
# PandaFactor Zeabur entrypoint: Basic Auth setup + run uvicorn & nginx.
#
# PANDAFACTOR_AUTH must be set to "username:password" (no colon inside the password).
# It is set in the Zeabur dashboard -> Variables; the plaintext is
# hashed here at container start and never written to the repo or an image layer.
#
# MongoDB connection comes from Zeabur Variables (MONGO_URI, MONGO_USER,
# MONGO_PASSWORD, MONGO_DB, MONGO_AUTH_DB, MONGO_TYPE); panda_common's
# config.py lets env vars override config.yaml keys. Empty DB is fine:
# pages open, API returns empty until data is loaded.
set -eu

if [ -z "${PANDAFACTOR_AUTH:-}" ]; then
  echo "ERROR: PANDAFACTOR_AUTH is not set. Set it to \"username:password\" in the Zeabur dashboard -> Variables." >&2
  exit 1
fi
auth_user="${PANDAFACTOR_AUTH%%:*}"
auth_pass="${PANDAFACTOR_AUTH#*:}"
if [ -z "$auth_user" ] || [ -z "$auth_pass" ] || [ "$auth_user" = "$PANDAFACTOR_AUTH" ]; then
  echo "ERROR: PANDAFACTOR_AUTH must look like \"username:password\" (password must not contain ':')." >&2
  exit 1
fi
auth_hash="$(openssl passwd -apr1 "$auth_pass")"
printf '%s:%s\n' "$auth_user" "$auth_hash" > /etc/nginx/.htpasswd
# nginx worker runs as non-root; htpasswd must be readable (644, same as BeefTV).
# apr1 hash is one-way; 644 is the conventional practice.
chmod 644 /etc/nginx/.htpasswd
unset auth_pass PANDAFACTOR_AUTH

# Backend first: FastAPI serves /api/v1 + /llm + frontend at /factor.
cd /app/panda_factor_server
uvicorn panda_factor_server.__main__:app --host 127.0.0.1 --port 8111 &
backend_pid=$!

# nginx in background so we can supervise both processes.
nginx -g 'daemon off;' &
nginx_pid=$!

_term() {
  kill -TERM "$backend_pid" 2>/dev/null || true
  kill -TERM "$nginx_pid" 2>/dev/null || true
}
trap _term TERM INT

# If either process dies, shut the other down and exit non-zero
# so Zeabur restarts the container.
while true; do
  if ! kill -0 "$backend_pid" 2>/dev/null; then
    echo "backend exited unexpectedly" >&2
    _term
    exit 1
  fi
  if ! kill -0 "$nginx_pid" 2>/dev/null; then
    echo "nginx exited unexpectedly" >&2
    _term
    exit 1
  fi
  sleep 5
done
