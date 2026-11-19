#!/usr/bin/env bash
# Completely remove the default installation and its dedicated project.
# Deletes all application data, including workspace PVCs and model credentials.
# Also removes the Agent Sandbox Operator resources from its prerequisite YAML.
set -euo pipefail

namespace=openshell-opencode
release=openshell-opencode
for command in oc helm; do
  command -v "$command" >/dev/null || { echo "Install $command first." >&2; exit 1; }
done
oc whoami >/dev/null

echo "Removing $release and project $namespace, including all application data."
# Listing first makes repeated cleanup safe without hiding uninstall failures.
installed=$(helm list --namespace "$namespace" --deployed --failed --pending --uninstalling --filter "^${release}$" --short)
if [[ -n "$installed" ]]; then
  helm uninstall "$release" --namespace "$namespace" --wait --timeout 5m
fi

# Helm does not own hook Jobs or CLI-created Sandboxes. Deleting the dedicated
# project removes these, their Pods, and retained Secrets/PVCs as well.
if ! oc delete project "$namespace" --ignore-not-found --wait=true --timeout=10m; then
  echo 'Project cleanup failed or timed out; inspect remaining resources:' >&2
  oc -n "$namespace" get pods,jobs,sandboxes,pvc >&2 || true
  oc describe namespace "$namespace" >&2 || true
  exit 1
fi
remaining=$(oc get namespace "$namespace" --ignore-not-found -o name)
[[ -z "$remaining" ]] || { echo "Project still exists: $remaining" >&2; exit 1; }
oc delete -f ./prerequisites/agent-sandbox-operator.yaml \
  --ignore-not-found --wait=true --timeout=10m
cat <<'EOF'
Deleted or already absent:
  - Helm release: openshell-opencode
  - OpenShift project: openshell-opencode, including Pods, Jobs, Sandboxes,
    PVCs, Secrets, Services, ConfigMaps, and NetworkPolicies
  - Agent Sandbox Operator resources from:
    prerequisites/agent-sandbox-operator.yaml
EOF
echo 'Cleanup complete.'
