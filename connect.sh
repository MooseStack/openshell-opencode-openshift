#!/usr/bin/env bash
# Connect to the single-user deployment without manually exporting certificates.
set -euo pipefail
namespace="${1:-openshell-opencode}"
sandbox_name="${2:-opencode}"
local_port="${OPENSHELL_LOCAL_PORT:-8080}"
gateway_name="openshell-opencode-${namespace}"
for command in oc openshell; do
  command -v "$command" >/dev/null || { echo "Install $command first (see README.md)." >&2; exit 1; }
done
[[ "$local_port" =~ ^[0-9]+$ ]] && ((local_port >= 1024 && local_port <= 65535)) || {
  echo "OPENSHELL_LOCAL_PORT must be between 1024 and 65535" >&2; exit 1;
}
umask 077
tls_dir="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/${gateway_name}/mtls"
mkdir -p "$tls_dir"
oc -n "$namespace" extract secret/openshell-client-tls --to="$tls_dir" --confirm >/dev/null
chmod 600 "$tls_dir"/*
forward_log="$(mktemp)"
forward_pid=""
cleanup() {
  if [[ -n "$forward_pid" ]]; then kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true; fi
  rm -f "$forward_log"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
oc -n "$namespace" port-forward --address=127.0.0.1 svc/openshell "${local_port}:8080" >"$forward_log" 2>&1 &
forward_pid=$!
ready=false
for ((attempt=0; attempt<30; attempt++)); do
  if grep -q 'Forwarding from' "$forward_log"; then ready=true; break; fi
  if ! kill -0 "$forward_pid" 2>/dev/null; then cat "$forward_log" >&2; exit 1; fi
  sleep 1
done
if [[ "$ready" != true ]]; then cat "$forward_log" >&2; echo 'Port-forward timed out' >&2; exit 1; fi
endpoint="https://127.0.0.1:${local_port}"
if ! openshell gateway select "$gateway_name" >/dev/null 2>&1; then
  openshell gateway add "$endpoint" --local --name "$gateway_name"
fi
# Keep the cluster certificates authoritative after local gateway registration.
oc -n "$namespace" extract secret/openshell-client-tls --to="$tls_dir" --confirm >/dev/null
chmod 600 "$tls_dir"/*
# An existing registration may refer to a different local forwarding port.
openshell -g "$gateway_name" --gateway-endpoint "$endpoint" sandbox exec "$sandbox_name" --tty --workdir /sandbox -- opencode
