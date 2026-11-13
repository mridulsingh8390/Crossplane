#!/usr/bin/env bash
# One-command setup: kind cluster -> Crossplane -> AWS providers -> credentials -> ProviderConfig
# Usage: ./00-setup.sh [eks-manifest.yaml]
#   If a manifest is given (e.g. crossplane-eks-private-all-in-one.yaml) it is applied at the end.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-crossplane-demo}"
CREDS_FILE="${CREDS_FILE:-./aws-credentials.txt}"
EKS_MANIFEST="${1:-}"

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

if [ ! -f "$CREDS_FILE" ]; then
  cat <<MSG
ERROR: $CREDS_FILE not found. Create it first:

[default]
aws_access_key_id = <YOUR_ACCESS_KEY_ID>
aws_secret_access_key = <YOUR_SECRET_ACCESS_KEY>
MSG
  exit 1
fi

echo "==> 1/6 kind cluster ($CLUSTER_NAME)"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "    already exists, reusing"
else
  kind create cluster --name "$CLUSTER_NAME"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

echo "==> 2/6 Crossplane (Helm)"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --wait

echo "==> 3/6 AWS providers (ec2, eks, iam)"
kubectl apply -f 00-providers.yaml
for p in provider-aws-ec2 provider-aws-eks provider-aws-iam; do
  kubectl wait "provider.pkg.crossplane.io/$p" --for=condition=Healthy --timeout=10m
done
# the provider family dependency is installed automatically; wait for everything
sleep 10
kubectl wait provider.pkg.crossplane.io --all --for=condition=Healthy --timeout=10m

echo "==> 4/6 Waiting for ProviderConfig CRD"
until kubectl get crd providerconfigs.aws.upbound.io >/dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Established crd/providerconfigs.aws.upbound.io --timeout=5m

echo "==> 5/6 AWS credentials secret"
kubectl create secret generic aws-secret \
  -n crossplane-system \
  --from-file=creds="$CREDS_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> 6/6 ProviderConfig"
kubectl apply -f 00-providerconfig.yaml

echo
echo "Crossplane is ready."

if [ -n "$EKS_MANIFEST" ]; then
  echo "==> Applying $EKS_MANIFEST"
  kubectl apply -f "$EKS_MANIFEST"
  echo "Watch progress with: kubectl get managed -w"
else
  echo "Next: kubectl apply -f crossplane-eks-private-all-in-one.yaml"
fi
