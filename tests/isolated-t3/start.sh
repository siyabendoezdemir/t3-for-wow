#!/usr/bin/env bash
# Start a THROWAWAY, ISOLATED T3 Code server for contract tests.
#   * fresh temp HOME and T3CODE_HOME (no access to the owner's real T3 data, credentials or providers)
#   * env -i: no inherited T3CODE_* variables from a surrounding T3 session
#   * loopback only, no browser, telemetry/OTEL off, no provider CLIs on PATH (any turn fails
#     fast instead of spending a model subscription)
# Usage: tests/isolated-t3/start.sh <t3-binary> <workdir>   -> prints "PORT=<n>" once healthy.
set -euo pipefail
T3=${1:?t3 binary}; WORK=${2:?workdir}
mkdir -p "$WORK/home" "$WORK/base" "$WORK/project"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
( cd "$WORK/project" && { [ -d .git ] || git init -q .; } )
env -i HOME="$WORK/home" PATH=/usr/bin:/bin TMPDIR="$WORK/home" \
  T3CODE_TELEMETRY_ENABLED=false T3CODE_OTEL_SDK_DISABLED=true DO_NOT_TRACK=1 \
  "$T3" serve --base-dir "$WORK/base" --host 127.0.0.1 --port "$PORT" --no-browser --mode web \
  "$WORK/project" >"$WORK/server.log" 2>&1 &
echo $! >"$WORK/server.pid"
echo "$PORT" >"$WORK/port"
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/.well-known/oauth-protected-resource/mcp" >/dev/null 2>&1; then
    echo "PORT=$PORT"; exit 0; fi
  sleep 0.5
done
echo "server did not become healthy; log tail:" >&2; tail -40 "$WORK/server.log" >&2; exit 1
