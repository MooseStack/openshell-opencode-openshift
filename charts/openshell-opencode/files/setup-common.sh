#!/usr/bin/env bash
# Sourced by setup.sh; functions share its configuration and workflow state.

initialize_setup() {
  CONFIG=${CONFIG:-/config}
  WORK=${WORK:-/work}
  TLS=${TLS:-/tls}
  KEY_FILE=${KEY_FILE:-/model-key/api-key}
  CLI=$WORK/openshell
  mkdir -p "$WORK"
  KEY=$(cat "$KEY_FILE")
  [[ -n $KEY ]] || { echo 'SETUP FAILED: empty model API key' >&2; exit 1; }
}

log() { local message=$*; printf '%s\n' "${message//"$KEY"/[REDACTED]}" >&2; }
fail() { log "SETUP FAILED: $*"; exit 1; }
setting() { jq -er "$1" "$CONFIG/settings.json"; }
cli() {
  if timeout "${CLI_TIMEOUT:-120}" "$CLI" "$@" >"$WORK/output" 2>"$WORK/error"; then
    cat "$WORK/output"
  else
    log "OpenShell ${*:1:2} failed: $(cat "$WORK/error" "$WORK/output")"
    return 1
  fi
}
objects() {
  local kind=$1 field=$2 token='' page
  local -a args
  while :; do
    args=("$kind" list -o json)
    [[ -z $token ]] || args+=(--page-token "$token")
    page=$(cli "${args[@]}") || return 1
    jq -ce --arg field "$field" '.[$field]' <<<"$page" || return 1
    token=$(jq -r '.next_page_token // empty' <<<"$page")
    [[ -n $token ]] || break
  done
}
