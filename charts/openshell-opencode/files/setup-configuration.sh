#!/usr/bin/env bash
# Sourced by setup.sh; functions share its configuration and workflow state.

reconcile_provider() {
  local providers
  log 'Reconciling model profile and credentials'
  if cli profile export "$provider" -o json >"$WORK/profile.json"; then
    jq --slurpfile old "$WORK/profile.json" '.resource_version = $old[0].resource_version' \
      "$CONFIG/provider.json" >"$WORK/provider.json"
    cli profile update "$provider" -f "$WORK/provider.json" >/dev/null
  elif grep -Eqi 'not found|notfound' "$WORK/error"; then
    cli profile import -f "$CONFIG/provider.json" >/dev/null
  else
    fail 'Cannot inspect provider profile'
  fi
  providers=$(objects provider providers)
  if jq -es --arg name "$provider" 'add | any(.name == $name)' <<<"$providers" >/dev/null; then
    LLM_API_KEY=$KEY cli provider update "$provider" --credential LLM_API_KEY >/dev/null
  else
    LLM_API_KEY=$KEY cli provider create --name "$provider" --type "$provider" --credential LLM_API_KEY >/dev/null
  fi
}

reconcile_network_policy() {
  local revision
  # Start from the base policy to preserve runtime-added filesystem paths and
  # exclude provider-composed rules. Helm owns the complete network rule map.
  log 'Reconciling sandbox network policy'
  cli policy get "$name" --base -o json >"$WORK/base-policy.json"
  jq -e '.policy_source == "sandbox" and (.policy | type == "object")' \
    "$WORK/base-policy.json" >/dev/null || fail 'Cannot reconcile a missing or global policy.'
  jq --slurpfile desired "$CONFIG/policy.json" \
    '.policy | .network_policies = ($desired[0].network_policies // {})' \
    "$WORK/base-policy.json" >"$WORK/policy.json"
  cli policy set "$name" --policy "$WORK/policy.json" --wait --timeout 60 >/dev/null
  # The pinned CLI can return success for a superseded or unchanged revision.
  # Verify the exact revision reported by set, not merely the latest revision.
  revision=$(sed -nE 's/.*Policy (version|unchanged \(version) ([0-9]+).*/\2/p' "$WORK/error")
  [[ $revision =~ ^[0-9]+$ ]] || fail 'Cannot identify submitted policy revision.'
  cli policy get "$name" --rev "$revision" -o json >"$WORK/policy-status.json"
  jq -e --argjson revision "$revision" \
    '.status == "loaded" and .version == $revision and .active_version == $revision' \
    "$WORK/policy-status.json" >/dev/null || fail 'Policy revision is not loaded and active.'
}

configure_opencode() {
  local -a exec_args
  cli sandbox provider attach "$name" "$provider" --wait --timeout 60 >/dev/null
  exec_args=(sandbox exec "$name" --no-tty --no-login-shell --workdir /sandbox)
  cli "${exec_args[@]}" --timeout 30 -- /bin/sh -c \
    'umask 077; cat > /sandbox/opencode.json.new && mv /sandbox/opencode.json.new /sandbox/opencode.json' \
    <"$CONFIG/opencode.json" >/dev/null
  log "$(cli "${exec_args[@]}" --timeout 30 -- opencode --version)"
}

smoke_test() {
  local -a exec_args
  exec_args=(sandbox exec "$name" --no-tty --no-login-shell --workdir /sandbox)
  if [[ $(jq -r '.setup.smokeTest' "$CONFIG/settings.json") == true ]]; then
    log 'Testing a real model request through OpenShell'
    CLI_TIMEOUT=200 cli "${exec_args[@]}" --timeout 180 -- opencode run --format json \
      'Reply with MODEL_OK only. Do not use tools.' >"$WORK/smoke.jsonl"
    jq -Rse '[split("\n")[] | fromjson? | objects] |
      (any(.type == "error") | not) and any(.type == "text" and (.part.text // "" | test("\\S")))' \
      "$WORK/smoke.jsonl" >/dev/null || fail 'OpenCode returned an error or no model text; check endpoint, model, TLS and policy'
    log 'Model smoke test passed'
  else
    log 'Model smoke test disabled; endpoint access has not been verified'
  fi
}
