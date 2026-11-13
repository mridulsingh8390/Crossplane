#!/usr/bin/env bash
# ============================================================
# One-command setup on a fresh Linux VM (Ubuntu/Debian or Amazon Linux/RHEL family):
#   installs docker, kubectl, kind, helm -> kind cluster -> Crossplane -> AWS providers
#   -> AWS credentials secret -> ProviderConfig -> (optional) your EKS manifest
#
# Usage:
#   1. Paste your AWS keys below (or export them as environment variables)
#   2. chmod 700 00-setup.sh
#   3. ./00-setup.sh crossplane-eks-private-all-in-one.yaml
#
# SECURITY: this file now holds secrets. Never commit it to Git or share it.
#           Use a dedicated IAM user and rotate/delete the keys when you are done.
# ============================================================
set -euo pipefail

# ---------- EDIT THESE ----------
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-<PASTE_ACCESS_KEY_ID_HERE>}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-<PASTE_SECRET_ACCESS_KEY_HERE>}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"      # only for temporary credentials
CLUSTER_NAME="${CLUSTER_NAME:-crossplane-demo}"
PROVIDER_VERSION="${PROVIDER_VERSION:-v1.14.0}" # check marketplace.upbound.io for newer
# --------------------------------

EKS_MANIFEST="${1:-}"

# ---------- sanity checks ----------
if [[ "$AWS_ACCESS_KEY_ID" == *"<PASTE"* || "$AWS_SECRET_ACCESS_KEY" == *"<PASTE"* ]]; then
  echo "ERROR: put your AWS access key and secret key at the top of this script first."
  exit 1
fi
if [ -n "$EKS_MANIFEST" ] && [ ! -f "$EKS_MANIFEST" ]; then
  echo "ERROR: manifest '$EKS_MANIFEST' not found (run the script from the folder that contains it)."
  exit 1
fi
if [ "$(uname -s)" != "Linux" ]; then
  echo "ERROR: this script installs Linux binaries; run it on a Linux VM."
  exit 1
fi

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "ERROR: unsupported CPU architecture $(uname -m)"; exit 1 ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo "ERROR: run as root or install sudo"; exit 1; }
  SUDO="sudo"
fi

if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
else echo "ERROR: unsupported package manager"; exit 1; fi

pkg_install() {
  case "$PKG" in
    apt) $SUDO apt-get update -y && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) $SUDO dnf install -y "$@" ;;
    yum) $SUDO yum install -y "$@" ;;
  esac
}

# ---------- 0. prerequisites ----------
echo "==> 0/7 Installing prerequisites (docker, kubectl, kind, helm)"

command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates

if ! command -v docker >/dev/null 2>&1; then
  echo "    installing docker"
  if [ "$PKG" = apt ]; then pkg_install docker.io; else pkg_install docker; fi
  $SUDO systemctl enable --now docker
  [ -n "$SUDO" ] && $SUDO usermod -aG docker "$USER" || true
fi
$SUDO systemctl start docker >/dev/null 2>&1 || true

# if the current shell is not yet in the docker group, re-run this script inside it (once)
if ! docker info >/dev/null 2>&1; then
  if [ -z "${_SETUP_RELAUNCHED:-}" ] && [ "$(id -u)" -ne 0 ]; then
    echo "    re-running with the docker group applied"
    export _SETUP_RELAUNCHED=1
    exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
  echo "ERROR: cannot talk to docker. Log out/in (or run 'newgrp docker') and re-run."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "    installing kubectl"
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
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

# ---------- 1. kind cluster ----------
echo "==> 1/7 kind cluster ($CLUSTER_NAME)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "    already exists, reusing"
else
  kind create cluster --name "$CLUSTER_NAME"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# ---------- 2. Crossplane ----------
echo "==> 2/7 Crossplane (Helm)"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --wait --timeout 10m

# ---------- 3. providers ----------
echo "==> 3/7 AWS providers (ec2, eks, iam) ${PROVIDER_VERSION}"
cat <<PROVIDERS_EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-ec2
spec:
  package: xpkg.upbound.io/upbound/provider-aws-ec2:${PROVIDER_VERSION}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-eks
spec:
  package: xpkg.upbound.io/upbound/provider-aws-eks:${PROVIDER_VERSION}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-iam
spec:
  package: xpkg.upbound.io/upbound/provider-aws-iam:${PROVIDER_VERSION}
PROVIDERS_EOF

for p in provider-aws-ec2 provider-aws-eks provider-aws-iam; do
  kubectl wait "provider.pkg.crossplane.io/$p" --for=condition=Healthy --timeout=10m
done
sleep 10   # the provider-family-aws dependency is installed automatically
kubectl wait provider.pkg.crossplane.io --all --for=condition=Healthy --timeout=10m

# ---------- 4. ProviderConfig CRD ----------
echo "==> 4/7 Waiting for ProviderConfig CRD"
until kubectl get crd providerconfigs.aws.upbound.io >/dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Established crd/providerconfigs.aws.upbound.io --timeout=5m

# ---------- 5. credentials secret ----------
echo "==> 5/7 AWS credentials secret"
CREDS_TMP="$(mktemp)"            # mode 600, removed on exit
trap 'rm -f "$CREDS_TMP"' EXIT
{
  echo "[default]"
  echo "aws_access_key_id = ${AWS_ACCESS_KEY_ID}"
  echo "aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}"
  [ -n "$AWS_SESSION_TOKEN" ] && echo "aws_session_token = ${AWS_SESSION_TOKEN}"
} > "$CREDS_TMP"
kubectl create secret generic aws-secret -n crossplane-system \
  --from-file=creds="$CREDS_TMP" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$CREDS_TMP"

# ---------- 6. ProviderConfig ----------
echo "==> 6/7 ProviderConfig"
cat <<PC_EOF | kubectl apply -f -
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-secret
      key: creds
PC_EOF

echo
echo "Crossplane is ready."

# ---------- 7. EKS stack ----------
if [ -n "$EKS_MANIFEST" ]; then
  echo "==> 7/7 Applying $EKS_MANIFEST"
  kubectl apply -f "$EKS_MANIFEST"
  echo
  echo "Resources are being created (about 20-25 min). Watch with:  kubectl get managed -w"
  echo "EC2 instance id (when ready): kubectl get instance demo-ec2-instance -o jsonpath='{.status.atProvider.id}'"
else
  echo "==> 7/7 No manifest given. Next: kubectl apply -f crossplane-eks-private-all-in-one.yaml"
fi
