#!/usr/bin/env bash
# ============================================================================
# 00-setup-aks.sh  -  set up Crossplane + an AKS cluster from scratch on a fresh Linux VM
#
#   ./00-setup-aks.sh crossplane-aks-all-in-one.yaml              # full setup, creates the AKS stack, fetches kubeconfig
#   ./00-setup-aks.sh --kubeconfig                                # (re)fetch ~/aks.kubeconfig from the cluster secret
#   ./00-setup-aks.sh crossplane-aks-all-in-one.yaml --destroy    # delete all Azure resources (add --delete-cluster for kind too)
#
# Steps: install docker/kubectl/kind/helm -> kind -> Crossplane -> Azure providers -> credentials + ProviderConfig
#        -> pick a supported AKS version -> apply your YAML -> wait for the cluster -> write ~/aks.kubeconfig.
#
# Needs: the YAML in the same folder, ~4GB RAM, 30GB disk (Ubuntu/Debian or Amazon Linux/RHEL, x86_64 or ARM),
#        and an Azure service principal with Contributor on the subscription (see below).
#
# Create the service principal once (Azure Cloud Shell or any machine with az):
#   az ad sp create-for-rbac --name crossplane-aks --role Contributor --scopes /subscriptions/<SUBSCRIPTION_ID>
#   -> appId = AZURE_CLIENT_ID, password = AZURE_CLIENT_SECRET, tenant = AZURE_TENANT_ID
#
# SECURITY: this file holds Azure secrets once you paste them. Never commit it with secrets; rotate them afterwards.
# ============================================================================
set -euo pipefail

# ---------------------------- EDIT THESE (or export as env vars) ----------------------------
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-<PASTE_CLIENT_ID_HERE>}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-<PASTE_CLIENT_SECRET_HERE>}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-<PASTE_TENANT_ID_HERE>}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-<PASTE_SUBSCRIPTION_ID_HERE>}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"          # Azure region, e.g. eastus, westeurope, centralindia
K8S_VERSION="${K8S_VERSION:-}"                      # empty = latest patch of the default AKS version; "1.32" = latest patch of 1.32; "1.32.7" = exact
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"               # node size (2 vCPU / 8 GB)
NODE_COUNT="${NODE_COUNT:-2}"
CLUSTER_NAME="${CLUSTER_NAME:-crossplane-demo}"     # local kind cluster name
PROVIDER_VERSION="${PROVIDER_VERSION:-v2.6.0}"      # Upbound Azure provider version (check marketplace.upbound.io)
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/aks.kubeconfig}"
GENERATED="${GENERATED:-./crossplane-aks.generated.yaml}"
# ---------------------------------------------------------------------------------------------

MANIFEST=""; DO_DESTROY=0; DO_KUBECONFIG=0; DELETE_CLUSTER=0
for arg in "$@"; do
  case "$arg" in
    --destroy)        DO_DESTROY=1 ;;
    --kubeconfig)     DO_KUBECONFIG=1 ;;
    --delete-cluster) DELETE_CLUSTER=1 ;;
    -h|--help)        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               echo "unknown option: $arg"; exit 1 ;;
    *)                MANIFEST="$arg" ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ prerequisites
detect_system() {
  [ "$(uname -s)" = "Linux" ] || die "run this on a Linux VM."
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) die "unsupported CPU architecture $(uname -m)" ;;
  esac
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
    SUDO="sudo"
  fi
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else die "unsupported package manager (need apt, dnf or yum)"; fi
}

pkg_install() {
  case "$PKG" in
    apt) $SUDO apt-get update -y && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) $SUDO dnf install -y "$@" ;;
    yum) $SUDO yum install -y "$@" ;;
  esac
}

preflight_resources() {
  local free_gb mem_mb
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  if [ "${free_gb:-0}" -lt 15 ] && [ -z "${SKIP_PREFLIGHT:-}" ]; then
    echo "ERROR: only ${free_gb}GB free on / . Docker + kind + the provider images need ~15GB free (30GB+ recommended)."
    echo "       Grow the root volume, or set SKIP_PREFLIGHT=1 to ignore."
    exit 1
  fi
  if [ "${mem_mb:-0}" -lt 3500 ]; then warn "only ${mem_mb}MB RAM; 4GB+ recommended."; fi
}

install_prerequisites() {
  log "0/7 Installing prerequisites (docker, kubectl, kind, helm, python3)"
  command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates
  command -v python3 >/dev/null 2>&1 || pkg_install python3

  if ! command -v docker >/dev/null 2>&1; then
    echo "    installing docker"
    if [ "$PKG" = apt ]; then pkg_install docker.io; else pkg_install docker; fi
    $SUDO systemctl enable --now docker
    if [ -n "$SUDO" ]; then $SUDO usermod -aG docker "$USER" || true; fi
  fi
  $SUDO systemctl start docker >/dev/null 2>&1 || true

  # not yet in the docker group in this shell? re-run the script inside it (once)
  if ! docker info >/dev/null 2>&1; then
    if [ -z "${_SETUP_RELAUNCHED:-}" ] && [ "$(id -u)" -ne 0 ]; then
      echo "    re-running with the docker group applied"
      export _SETUP_RELAUNCHED=1
      exec sg docker -c "$(printf '%q ' "$0" "$@")"
    fi
    die "cannot talk to docker. Log out/in (or run 'newgrp docker') and re-run."
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "    installing kubectl"
    local kver; kver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kver}/bin/linux/${ARCH}/kubectl"
    $SUDO install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm -f /tmp/kubectl
  fi
  if ! command -v kind >/dev/null 2>&1; then
    echo "    installing kind"
    curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH}"
    $SUDO install -m 0755 /tmp/kind /usr/local/bin/kind && rm -f /tmp/kind
  fi
  if ! command -v helm >/dev/null 2>&1; then
    echo "    installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash
  fi
}

# ------------------------------------------------------------------ Azure credentials + AKS version
check_credentials_set() {
  local v
  for v in "$AZURE_CLIENT_ID" "$AZURE_CLIENT_SECRET" "$AZURE_TENANT_ID" "$AZURE_SUBSCRIPTION_ID"; do
    if [[ "$v" == *"<PASTE"* ]]; then
      die "fill in AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID at the top of this script (or export them)."
    fi
  done
}

azure_token() {
  curl -fsS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" --data-urlencode "client_secret=${AZURE_CLIENT_SECRET}" \
    -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
}

# Prints the exact AKS version to use. Also proves the service principal can log in and read the subscription.
pick_k8s_version() {
  local token json
  token="$(azure_token)" || die "Azure login failed. Check AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID."
  json="$(curl -fsS -H "Authorization: Bearer ${token}" \
    "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.ContainerService/locations/${AZURE_LOCATION}/kubernetesVersions?api-version=2024-02-01")" \
    || die "could not list AKS versions for '${AZURE_LOCATION}'. Check AZURE_SUBSCRIPTION_ID, the location name and that the service principal has access (Contributor/Reader)."
  printf '%s' "$json" | python3 -c '
import sys, json
want = sys.argv[1]
vals = json.load(sys.stdin)["values"]
key = lambda s: [int(x) for x in s.split(".")]
if want.count(".") == 2:            # exact patch version
    print(want); sys.exit(0)
if not want:
    d = [v for v in vals if v.get("isDefault")]
    v = d[0] if d else sorted(vals, key=lambda v: key(v["version"]))[-1]
else:
    m = [v for v in vals if v["version"] == want]
    if not m:
        sys.exit("AKS version %s is not available in this region. Available: %s" % (want, ", ".join(sorted(x["version"] for x in vals))))
    v = m[0]
print(sorted(v["patchVersions"].keys(), key=key)[-1])
' "$K8S_VERSION"
}

# ------------------------------------------------------------------ kind + Crossplane + providers
use_kind_context() {
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1 \
    || die "kind cluster '$CLUSTER_NAME' not found. Run the full setup first."
}

create_kind_cluster() {
  log "1/7 kind cluster ($CLUSTER_NAME)"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "    already exists, reusing"
  else
    kind create cluster --name "$CLUSTER_NAME"
  fi
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
}

install_crossplane() {
  log "2/7 Crossplane (Helm)"
  helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait --timeout 10m
}

provider_diagnostics() {
  echo; echo "---------- DIAGNOSTICS ----------"
  kubectl get providers.pkg.crossplane.io || true; echo
  kubectl get pods -n crossplane-system || true; echo
  for p in $(kubectl get providers.pkg.crossplane.io -o name 2>/dev/null); do
    echo "### $p"
    kubectl describe "$p" 2>/dev/null | sed -n '/Conditions:/,/Events:/p;/Events:/,$p' | head -40
  done
  echo "---------------------------------"
}

install_providers() {
  log "3/7 Azure providers (family, network, containerservice) ${PROVIDER_VERSION}"
  cat <<PROVIDERS_EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-azure
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:${PROVIDER_VERSION}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-network
spec:
  package: xpkg.upbound.io/upbound/provider-azure-network:${PROVIDER_VERSION}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-containerservice
spec:
  package: xpkg.upbound.io/upbound/provider-azure-containerservice:${PROVIDER_VERSION}
PROVIDERS_EOF

  local deadline=$((SECONDS + 900)) all_ok h p
  while true; do
    echo "    $(date +%T) provider status:"
    kubectl get providers.pkg.crossplane.io --no-headers 2>/dev/null \
      | awk '{printf "      %-34s INSTALLED=%s HEALTHY=%s\n", $1, $2, $3}' || true
    all_ok=1
    for p in upbound-provider-family-azure provider-azure-network provider-azure-containerservice; do
      h="$(kubectl get provider.pkg.crossplane.io "$p" -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || true)"
      [ "$h" = "True" ] || all_ok=0
    done
    if kubectl get providers.pkg.crossplane.io -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Healthy")].status}{"\n"}{end}' 2>/dev/null | grep -qv '^True$'; then
      all_ok=0
    fi
    [ "$all_ok" = 1 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "ERROR: providers are not healthy after 15 minutes."
      echo "       If a package says 'not found', that provider version does not exist: try PROVIDER_VERSION=<another tag>."
      provider_diagnostics; exit 1
    fi
    sleep 15
  done
}

configure_provider() {
  log "4/7 ProviderConfig + Azure credentials secret"
  until kubectl get crd providerconfigs.azure.upbound.io >/dev/null 2>&1; do sleep 5; done
  kubectl wait --for=condition=Established crd/providerconfigs.azure.upbound.io --timeout=5m

  local creds_tmp; creds_tmp="$(mktemp)"          # mode 600, removed right after use
  python3 - "$AZURE_CLIENT_ID" "$AZURE_CLIENT_SECRET" "$AZURE_SUBSCRIPTION_ID" "$AZURE_TENANT_ID" > "$creds_tmp" <<'PY_EOF'
import json, sys
c, s, sub, t = sys.argv[1:5]
print(json.dumps({"clientId": c, "clientSecret": s, "subscriptionId": sub, "tenantId": t}))
PY_EOF
  kubectl create secret generic azure-secret -n crossplane-system \
    --from-file=creds="$creds_tmp" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$creds_tmp"

  cat <<PC_EOF | kubectl apply -f -
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: azure-secret
      key: creds
PC_EOF
}

# ------------------------------------------------------------------ the AKS stack
generate_manifest() {   # $1 = resolved Kubernetes version (may be empty if the YAML already has a real one)
  cp "$MANIFEST" "$GENERATED"
  if [ "$AZURE_LOCATION" != "eastus" ]; then
    sed -i "s/location: eastus/location: ${AZURE_LOCATION}/" "$GENERATED"
  fi
  sed -i "s/vmSize: .*/vmSize: ${VM_SIZE}/" "$GENERATED"
  sed -i "s/nodeCount: .*/nodeCount: ${NODE_COUNT}/" "$GENERATED"
  if [ -n "${1:-}" ]; then
    if grep -q 'REPLACE_K8S_VERSION' "$GENERATED"; then
      sed -i "s/REPLACE_K8S_VERSION/${1}/g" "$GENERATED"
    elif [ -n "$K8S_VERSION" ]; then          # explicit override of versions already in the YAML
      sed -i -E "s/^( *(kubernetesVersion|orchestratorVersion): ).*/\1\"${1}\"/" "$GENERATED"
    fi
  fi
}

apply_stack() {
  log "5/7 Applying the AKS stack"
  local ver=""
  if grep -q 'REPLACE_K8S_VERSION' "$MANIFEST" || [ -n "$K8S_VERSION" ]; then
    ver="$(pick_k8s_version)" || exit 1
    echo "    AKS version: $ver  (region: $AZURE_LOCATION)"
  else
    echo "    using the Kubernetes version already set in $MANIFEST"
    pick_k8s_version >/dev/null || exit 1     # still verifies the Azure login / subscription access
  fi
  generate_manifest "$ver"
  echo "    manifest written to $GENERATED ($(grep -c '^kind:' "$GENERATED") resources)"
  # --validate=false: the providers install many CRDs, so kubectl's OpenAPI download can time out on small VMs.
  # The API server still validates every object.
  local attempt
  for attempt in 1 2 3 4 5; do
    if kubectl apply --validate=false -f "$GENERATED"; then break; fi
    [ "$attempt" = 5 ] && die "apply failed 5 times"
    echo "    apply failed (attempt $attempt/5), retrying in 20s..."; sleep 20
  done
}

wait_ready() {
  log "6/7 Waiting for the resources to become READY (AKS takes ~5-15 min)"
  local total deadline all notready nr
  total="$(grep -c '^kind:' "$GENERATED")"
  deadline=$((SECONDS + 2700))
  while true; do
    all="$(kubectl get managed --no-headers 2>/dev/null | grep -c . || true)"
    notready="$(kubectl get managed --no-headers 2>/dev/null | awk '!($2=="True" && $3=="True") {print $1}' || true)"
    nr="$(printf '%s' "$notready" | grep -c . || true)"
    echo "    $(date +%T)  ready $((all - nr))/${total}"
    if [ -n "$notready" ]; then printf '%s\n' "$notready" | head -4 | sed 's|^|        waiting: |'; fi
    if [ "$all" -ge "$total" ] && [ "$nr" -eq 0 ]; then echo "    all resources are READY"; return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "WARNING: not everything is ready after 45 minutes. Still waiting for:"; printf '%s\n' "$notready"
      echo "Inspect one with: kubectl describe <kind> <name> | tail -20   (e.g. kubectl describe kubernetescluster demo-aks)"
      return 1
    fi
    sleep 30
  done
}

fetch_kubeconfig() {
  local key data
  for key in kubeconfig kube_config_raw attribute.kube_config_raw; do
    data="$(kubectl get secret demo-aks-kubeconfig -n crossplane-system -o "jsonpath={.data.${key//./\\.}}" 2>/dev/null || true)"
    if [ -n "$data" ]; then
      ( umask 077; printf '%s' "$data" | base64 -d > "$KUBECONFIG_OUT" )
      echo "    kubeconfig written to $KUBECONFIG_OUT"
      return 0
    fi
  done
  warn "the kubeconfig secret is not available yet (the cluster may still be creating). Keys present:"
  kubectl get secret demo-aks-kubeconfig -n crossplane-system -o jsonpath='{.data}' 2>/dev/null | python3 -c 'import sys,json; print(" ", ", ".join(json.load(sys.stdin).keys()))' 2>/dev/null || echo "  (secret not found)"
  return 1
}

print_summary() {
  log "7/7 Done"
  if KUBECONFIG="$KUBECONFIG_OUT" timeout 60 kubectl get nodes -o wide 2>/dev/null; then :; else
    warn "could not list AKS nodes yet (nodes can take a minute). Try again with the command below."
  fi
  cat <<SUMMARY_EOF

Use kubectl against AKS from this VM (separate kubeconfig, so the kind context Crossplane needs is kept):
  export KUBECONFIG=${KUBECONFIG_OUT}
  kubectl get nodes -o wide        # node IPs 10.0.1.x
  kubectl get pods -A -o wide      # pod IPs 10.244.x.x (overlay)
  kubectl get svc -A               # service IPs 172.20.x.x
  unset KUBECONFIG                 # back to the kind cluster (kubectl get managed)

Upgrade Kubernetes: change BOTH kubernetesVersion and orchestratorVersion in the YAML to the next minor, or run
  K8S_VERSION=1.xx ./00-setup-aks.sh crossplane-aks-all-in-one.yaml
Delete everything: ./00-setup-aks.sh crossplane-aks-all-in-one.yaml --destroy [--delete-cluster]
Reminder: the Azure secret lives in the kind cluster (secret azure-secret). Rotate/delete it when finished.
SUMMARY_EOF
}

destroy_all() {
  use_kind_context
  [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || die "usage: ./00-setup-aks.sh crossplane-aks-all-in-one.yaml --destroy"
  log "Deleting all Azure resources created by Crossplane"
  generate_manifest ""
  kubectl delete -f "$GENERATED" --ignore-not-found --wait=false || true
  local deadline=$((SECONDS + 2400)) left
  while true; do
    left="$(kubectl get managed --no-headers 2>/dev/null | grep -c . || true)"
    echo "    $(date +%T)  ${left} resource(s) remaining"
    [ "$left" -eq 0 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then warn "still deleting. Check: kubectl get managed   (do NOT delete the kind cluster yet)"; exit 1; fi
    sleep 30
  done
  echo "    all Azure resources deleted"
  if [ "$DELETE_CLUSTER" = 1 ]; then kind delete cluster --name "$CLUSTER_NAME"; fi
}

main() {
  if [ "$DO_KUBECONFIG" = 1 ]; then
    use_kind_context; fetch_kubeconfig; return
  fi
  if [ "$DO_DESTROY" = 1 ]; then
    check_credentials_set; destroy_all; return
  fi

  [ -n "$MANIFEST" ] || die "usage: ./00-setup-aks.sh crossplane-aks-all-in-one.yaml"
  [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found (run from the folder that contains it)."
  check_credentials_set
  detect_system
  preflight_resources
  install_prerequisites "$@"
  create_kind_cluster
  install_crossplane
  install_providers
  configure_provider
  apply_stack
  if wait_ready; then
    fetch_kubeconfig || true
    print_summary
  else
    echo "Setup applied, but the cluster is not ready yet. When it is, run: ./00-setup-aks.sh --kubeconfig"
    exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
