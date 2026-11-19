#!/usr/bin/env bash
# Sourced by setup.sh; functions share its configuration and workflow state.

# Version 1 fingerprints used Python JSON spacing and included network rules.
# Reconstruct them without weakening the image/resources/static-policy guard.
legacy_fingerprint() {
  jq -S -a -c --slurpfile policy "$CONFIG/policy.json" --slurpfile network "$1" \
    '{sandbox:(.sandbox | del(.recreate, .filesystemPolicy, .landlock, .process, .networkMiddlewares) | .networkPolicies=$network[0]),
      policy:($policy[0] | .network_policies=$network[0]), layoutVersion:1}' \
    "$CONFIG/settings.json" |
    awk '{ quoted=0; escaped=0; for(i=1;i<=length($0);i++) {
      c=substr($0,i,1); printf "%s",c;
      if(escaped) {escaped=0; continue}
      if(quoted && c=="\\") {escaped=1; continue}
      if(c=="\"") quoted=!quoted;
      if(!quoted && (c=="," || c==":")) printf " ";
    }}' | sha256sum | cut -d' ' -f1
}

# Publishes name, provider, fingerprint, current and recreate for later phases.
verify_existing_sandbox() {
  local stored
  name=$(setting '.sandbox.name')
  provider=$name-llm
  # Only network rules are mutable. Keep all other sandbox/policy settings in
  # the creation fingerprint (policy values are captured in policy.json) so an upgrade cannot silently ignore static changes.
  fingerprint=$(jq -S -a -c --slurpfile policy "$CONFIG/policy.json" \
    '{sandbox:(.sandbox | del(.recreate, .networkPolicies, .filesystemPolicy, .landlock, .process, .networkMiddlewares)),
      policy:($policy[0] | del(.network_policies)), layoutVersion:2}' \
    "$CONFIG/settings.json" | sha256sum | cut -d' ' -f1)

  current=$(jq -sc --arg name "$name" 'add | map(select(.name == $name)) | first // empty' <<<"$existing")
  recreate=$(setting '(.sandbox.recreate // false) | tostring')
  if [[ -n $current && $recreate != true ]]; then
    stored=$(jq -r '.annotations["openshell-opencode/static-config-hash"] // empty' <<<"$current")
    if [[ -n $stored ]]; then
      [[ $stored == "$fingerprint" ]] ||
        fail 'Existing sandbox has different image/resources/static policy. Back up and explicitly recreate it. No sandbox was deleted.'
    else
      stored=$(jq -r '.annotations["openshell-opencode/config-hash"] // empty' <<<"$current")
      [[ -n $stored ]] || fail 'Existing sandbox has no setup ownership fingerprint. No sandbox was changed.'
      jq '.network_policies // {}' "$CONFIG/policy.json" >"$WORK/original-network.json"
      if [[ $stored != "$(legacy_fingerprint "$WORK/original-network.json")" ]]; then
        cli policy get "$name" --rev 1 --base -o json >"$WORK/initial-policy.json"
        jq -e '.policy | objects' "$WORK/initial-policy.json" >/dev/null
        jq '.policy.network_policies // {}' "$WORK/initial-policy.json" >"$WORK/original-network.json"
        [[ $stored == "$(legacy_fingerprint "$WORK/original-network.json")" ]] ||
          fail 'Cannot verify legacy sandbox creation settings (static drift or normalized original rules). Restore original values or back up and explicitly recreate it. No sandbox was changed.'
      fi
    fi
  fi
}

ensure_sandbox() {
  local deadline remaining state phase
  if [[ -n $current && $recreate == true ]]; then
    log 'Recreating sandbox as requested; existing workspace data may be deleted'
    cli sandbox delete "$name" >/dev/null
    deadline=$((SECONDS + 120))
    while :; do
      remaining=$(objects sandbox sandboxes)
      if ! jq -es --arg name "$name" 'add | any(.name == $name)' <<<"$remaining" >/dev/null; then
        break
      fi
      ((SECONDS < deadline)) || fail 'Sandbox deletion did not complete within 120 seconds'
      sleep 3
    done
    current=''
  fi

  if [[ -z $current ]]; then
    log 'Creating persistent OpenCode sandbox'
    CLI_TIMEOUT=400 cli sandbox create --name "$name" --from "$(setting '.sandbox.image')" \
      --provider "$provider" --policy "$CONFIG/policy.json" \
      --cpu "$(setting '.sandbox.cpu')" --memory "$(setting '.sandbox.memory')" \
      --annotation "openshell-opencode/static-config-hash=$fingerprint" \
      --detach --no-tty --no-auto-providers --timeout 360 \
      --env HOME=/sandbox --env XDG_CONFIG_HOME=/sandbox/.config \
      --env XDG_CACHE_HOME=/sandbox/.cache --env XDG_DATA_HOME=/sandbox/.local/share \
      --env XDG_STATE_HOME=/sandbox/.local/state --env OPENCODE_CONFIG=/sandbox/opencode.json \
      --env OPENCODE_DISABLE_AUTOUPDATE=true --env OPENCODE_DISABLE_MODELS_FETCH=true \
      -- /bin/sh -c 'mkdir -p /sandbox/.config /sandbox/.cache /sandbox/.local/share /sandbox/.local/state && exec sleep infinity' >/dev/null
  elif [[ $(jq -r '.phase | ascii_downcase' <<<"$current") == stopped ]]; then
    CLI_TIMEOUT=400 cli sandbox start "$name" >/dev/null
  fi
  deadline=$((SECONDS + 360))
  while :; do
    state=$(cli sandbox get "$name" -o json)
    phase=$(jq -er '.phase | ascii_downcase' <<<"$state")
    case $phase in
      ready|running) break ;;
      error|failed|stopped|terminated|completed|suspended|deleting) fail "Sandbox entered $phase" ;;
    esac
    ((SECONDS < deadline)) || fail 'Sandbox did not become ready within 360 seconds'
    sleep 3
  done
}
