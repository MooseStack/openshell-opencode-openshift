#!/usr/bin/env bash
# Sourced by setup.sh; functions share its configuration and workflow state.

install_cli() {
  local version arch checksum
  version=$(setting '.setup.cliVersion')
  arch=$(uname -m)
  checksum=$(jq -er --arg arch "$arch" '.setup.cliChecksums[$arch]' "$CONFIG/settings.json")
  log "Downloading verified OpenShell $version CLI ($arch)"
  curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 104857600 \
    "https://github.com/NVIDIA/OpenShell/releases/download/v$version/openshell-$arch-unknown-linux-musl.tar.gz" \
    -o "$WORK/cli.tar.gz"
  printf '%s  %s\n' "$checksum" "$WORK/cli.tar.gz" | sha256sum -c - >/dev/null
  # Write only the named member to stdout; never extract archive paths into the filesystem.
  tar -xOzf "$WORK/cli.tar.gz" openshell >"$CLI"
  [[ -s $CLI ]] || fail 'CLI archive contains no binary'
  chmod 700 "$CLI"
  log "$(cli --version)"
}

register_gateway() {
  local tls_dir file attempt
  log 'Waiting 30 seconds for the gateway to become ready'
  sleep 30

  log 'Registering gateway with mTLS'
  tls_dir=$XDG_CONFIG_HOME/openshell/gateways/openshift/mtls
  mkdir -p "$tls_dir"
  for file in ca.crt tls.crt tls.key; do
    cp "$TLS/$file" "$tls_dir/$file"
    chmod 600 "$tls_dir/$file"
  done
  cli gateway add "$(setting '.gateway')" --local --name openshift >/dev/null
  for ((attempt=1; attempt<=12; attempt++)); do
    if existing=$(objects sandbox sandboxes); then break; fi
    ((attempt < 12)) || fail 'Cannot list sandboxes'
    sleep 5
  done
}
