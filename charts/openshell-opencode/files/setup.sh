#!/usr/bin/env bash
# Bootstrap through the OpenShell CLI; no Kubernetes API access.
set -Eeuo pipefail
umask 077

# Resolve modules beside the entrypoint, including when CONFIG is overridden.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/setup-common.sh"
initialize_setup
trap 'fail "Setup command failed at ${BASH_SOURCE[0]}:$LINENO; inspect the Job logs."' ERR
source "$SCRIPT_DIR/setup-bootstrap.sh"
source "$SCRIPT_DIR/setup-sandbox.sh"
source "$SCRIPT_DIR/setup-configuration.sh"

install_cli
register_gateway
# Verify ownership and static settings before changing provider or sandbox state.
verify_existing_sandbox
reconcile_provider
ensure_sandbox
reconcile_network_policy
configure_opencode
smoke_test
log "Sandbox $name is ready"
