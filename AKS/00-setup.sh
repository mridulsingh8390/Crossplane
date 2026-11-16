#!/usr/bin/env bash
# ============================================================================
# 00-setup.sh  -  set up everything from scratch on a fresh Linux VM
#
#   ./00-setup.sh crossplane-eks-private-all-in-one.yaml   # full setup + creates the AWS stack + brings SSM up
#   ./00-setup.sh --ssm-only                               # only enable/repair Session Manager on an existing stack
#
# Steps: install docker/kubectl/kind/helm/aws cli/session-manager-plugin -> kind -> Crossplane -> AWS providers
#        -> credentials + ProviderConfig -> apply your YAML -> ENABLE SSM (attach IAM profile, restart the
#        instance's SSM agent if needed, wait until "Online") -> print how to connect.
#
# Needs: the YAML file in the same folder, ~4GB RAM, 30GB disk (Ubuntu/Debian or Amazon Linux/RHEL, x86_64 or ARM).
# SECURITY: this file holds AWS keys once you paste them. Never commit it with keys; delete/rotate keys afterwards.
# ============================================================================
set -euo pipefail

# ---------------------------- EDIT THESE (or export as env vars) ----------------------------
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-<PASTE_ACCESS_KEY_ID_HERE>}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-<PASTE_SECRET_ACCESS_KEY_HERE>}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"          # only for temporary credentials
CLUSTER_NAME="${CLUSTER_NAME:-crossplane-demo}"     # local kind cluster name
PROVIDER_VERSION="${PROVIDER_VERSION:-v1.14.0}"     # Upbound AWS provider version
AWS_REGION="${AWS_REGION:-}"                        # empty = read from the YAML (default us-east-1)
# ---------------------------------------------------------------------------------------------

SSM_ONLY=0
MANIFEST=""
for arg in "$@"; do
  case "$arg" in
    --ssm-only) SSM_ONLY=1 ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $arg"; exit 1 ;;
    *)          MANIFEST="$arg" ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ prerequisites
detect_system() {
  [ "$(uname -s)" = "Linux" ] || die "run this on a Linux VM."
  case "$(uname -m)" in
    x86_64)  ARCH=amd64; AWS_ARCH=x86_64;  PLUGIN_DEB=ubuntu_64bit; PLUGIN_RPM=linux_64bit ;;
    aarch64) ARCH=arm64; AWS_ARCH=aarch64; PLUGIN_DEB=ubuntu_arm64; PLUGIN_RPM=linux_arm64 ;;
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
    echo "ERROR: only ${free_gb}GB free on / . Docker + kind + the AWS provider images need ~15GB free (30GB+ recommended)."
    echo "       Grow the root volume (EBS -> Modify volume, then growpart + resize2fs), or set SKIP_PREFLIGHT=1 to ignore."
    exit 1
  fi
  if [ "${mem_mb:-0}" -lt 3500 ]; then warn "only ${mem_mb}MB RAM; 4GB+ recommended."; fi
}

install_prerequisites() {
  log "0/8 Installing prerequisites (docker, kubectl, kind, helm, aws cli, session-manager-plugin)"
  command -v curl  >/dev/null 2>&1 || pkg_install curl ca-certificates
  command -v unzip >/dev/null 2>&1 || pkg_install unzip

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
  if ! command -v aws >/dev/null 2>&1; then
    echo "    installing AWS CLI v2"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    $SUDO /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip
  fi
  if ! command -v session-manager-plugin >/dev/null 2>&1; then
    echo "    installing session-manager-plugin"
    if [ "$PKG" = apt ]; then
      curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${PLUGIN_DEB}/session-manager-plugin.deb" -o /tmp/ssm-plugin.deb \
        && $SUDO dpkg -i /tmp/ssm-plugin.deb || warn "could not install session-manager-plugin (only needed for 'aws ssm start-session')"
      rm -f /tmp/ssm-plugin.deb
    else
      $SUDO "$PKG" install -y "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${PLUGIN_RPM}/session-manager-plugin.rpm" \
        || warn "could not install session-manager-plugin (only needed for 'aws ssm start-session')"
    fi
  fi
}

# ------------------------------------------------------------------ credentials / region
check_credentials_set() {
  if [[ "$AWS_ACCESS_KEY_ID" == *"<PASTE"* || "$AWS_SECRET_ACCESS_KEY" == *"<PASTE"* ]]; then
    die "put your AWS access key and secret key at the top of this script (or export them) first."
  fi
}

use_aws_credentials() {
  if [ -z "$AWS_REGION" ]; then
    if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
      AWS_REGION="$(grep -m1 -E '^ +region: ' "$MANIFEST" | awk '{print $2}' | tr -d '[:space:]')"
    fi
    AWS_REGION="${AWS_REGION:-us-east-1}"
  fi
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
  export AWS_DEFAULT_REGION="$AWS_REGION"
  if [ -n "$AWS_SESSION_TOKEN" ]; then export AWS_SESSION_TOKEN; else unset AWS_SESSION_TOKEN; fi
}

# ------------------------------------------------------------------ kind + Crossplane + providers
create_kind_cluster() {
  log "1/8 kind cluster ($CLUSTER_NAME)"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "    already exists, reusing"
  else
    kind create cluster --name "$CLUSTER_NAME"
  fi
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
}

install_crossplane() {
  log "2/8 Crossplane (Helm)"
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
  log "3/8 AWS providers (family, ec2, eks, iam) ${PROVIDER_VERSION}"
  cat <<PROVIDERS_EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-aws
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:${PROVIDER_VERSION}
---
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

  local deadline=$((SECONDS + 900)) all_ok h p
  while true; do
    echo "    $(date +%T) provider status:"
    kubectl get providers.pkg.crossplane.io --no-headers 2>/dev/null \
      | awk '{printf "      %-32s INSTALLED=%s HEALTHY=%s\n", $1, $2, $3}' || true
    all_ok=1
    for p in provider-aws-ec2 provider-aws-eks provider-aws-iam; do
      h="$(kubectl get provider.pkg.crossplane.io "$p" -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || true)"
      [ "$h" = "True" ] || all_ok=0
    done
    if kubectl get providers.pkg.crossplane.io -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Healthy")].status}{"\n"}{end}' 2>/dev/null | grep -qv '^True$'; then
      all_ok=0
    fi
    [ "$all_ok" = 1 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "ERROR: providers are not healthy after 15 minutes."; provider_diagnostics; exit 1
    fi
    sleep 15
  done
}

configure_provider() {
  log "4/8 ProviderConfig + AWS credentials secret"
  until kubectl get crd providerconfigs.aws.upbound.io >/dev/null 2>&1; do sleep 5; done
  kubectl wait --for=condition=Established crd/providerconfigs.aws.upbound.io --timeout=5m

  local creds_tmp; creds_tmp="$(mktemp)"          # mode 600, removed right after use
  {
    echo "[default]"
    echo "aws_access_key_id = ${AWS_ACCESS_KEY_ID}"
    echo "aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}"
    if [ -n "$AWS_SESSION_TOKEN" ]; then echo "aws_session_token = ${AWS_SESSION_TOKEN}"; fi
  } > "$creds_tmp"
  kubectl create secret generic aws-secret -n crossplane-system \
    --from-file=creds="$creds_tmp" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$creds_tmp"

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
}

apply_stack() {
  log "5/8 Applying $MANIFEST"
  # --validate=false: the AWS providers install thousands of CRDs, so kubectl's OpenAPI download can time out on
  # small VMs. The API server still validates every object.
  local attempt
  for attempt in 1 2 3 4 5; do
    if kubectl apply --validate=false -f "$MANIFEST"; then break; fi
    [ "$attempt" = 5 ] && die "apply failed 5 times"
    echo "    apply failed (attempt $attempt/5), retrying in 20s..."; sleep 20
  done
}

# ------------------------------------------------------------------ SSM: enable + restart + verify
INSTANCE=""

get_instance_id() { kubectl get instance demo-ec2-instance -o jsonpath='{.status.atProvider.id}' 2>/dev/null || true; }
ssm_ping() {
  aws ssm describe-instance-information --region "$AWS_REGION" --filters Key=InstanceIds,Values="$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true
}

wait_ssm_online() {   # $1 = seconds to wait
  local deadline=$((SECONDS + $1)) p n=0
  while true; do
    p="$(ssm_ping)"
    if [ "$p" = "Online" ]; then return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then return 1; fi
    if [ $((n % 3)) -eq 0 ]; then echo "    $(date +%T) SSM status: ${p:-not registered yet} ..."; fi
    n=$((n + 1))
    sleep 20
  done
}

# Is it safe to reboot? Only if the instance's startup script runs as a systemd service (survives reboots).
bootstrap_is_reboot_safe() {
  aws ec2 describe-instance-attribute --region "$AWS_REGION" --instance-id "$INSTANCE" --attribute userData \
    --query 'UserData.Value' --output text 2>/dev/null | base64 -d 2>/dev/null | grep -q 'eks-bootstrap.service'
}

restart_instance() {   # reboot = restarts the SSM agent and every service on the instance
  if ! bootstrap_is_reboot_safe && [ -z "${FORCE_REBOOT:-}" ]; then
    warn "not rebooting: this instance was created from an older YAML whose bootstrap script would not resume after a reboot."
    warn "Recreate it from the current YAML instead:  kubectl delete instance demo-ec2-instance && ./00-setup.sh <yaml>   (or set FORCE_REBOOT=1)"
    return 1
  fi
  echo "    rebooting $INSTANCE to restart the SSM agent and all services"
  aws ec2 reboot-instances --region "$AWS_REGION" --instance-ids "$INSTANCE"
  sleep 60
}

ssm_diagnostics() {
  echo; echo "---------- SSM DIAGNOSTICS ----------"
  aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE" \
    --query 'Reservations[0].Instances[0].[State.Name,IamInstanceProfile.Arn,ImageId,SubnetId]' --output text || true
  echo "role policies:"; aws iam list-attached-role-policies --role-name demo-ec2-role --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true
  echo "private default route (State NatGatewayId):"
  aws ec2 describe-route-tables --region "$AWS_REGION" --filters Name=tag:Name,Values=demo-private-rt \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[State,NatGatewayId]' --output text 2>/dev/null || true
  echo "SSM VPC endpoints:"
  aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
    --filters "Name=service-name,Values=com.amazonaws.${AWS_REGION}.ssm,com.amazonaws.${AWS_REGION}.ssmmessages,com.amazonaws.${AWS_REGION}.ec2messages" \
    --query 'VpcEndpoints[].[ServiceName,State]' --output text 2>/dev/null || true
  echo "boot log (ssm / errors):"
  aws ec2 get-console-output --region "$AWS_REGION" --instance-id "$INSTANCE" --latest --output text 2>/dev/null \
    | grep -iE "ssm|failed|error" | tail -8 || true
  echo "-------------------------------------"
}

enable_ssm() {
  log "6/8 Waiting for the EC2 instance to be created"
  local deadline=$((SECONDS + 1500))
  while true; do
    INSTANCE="$(get_instance_id)"
    [ -n "$INSTANCE" ] && break
    [ "$SECONDS" -ge "$deadline" ] && die "the EC2 instance was not created in 25 minutes. Check: kubectl describe instance demo-ec2-instance | tail -20"
    echo "    $(date +%T) waiting for instance id ..."; sleep 20
  done
  echo "    instance: $INSTANCE ($AWS_REGION)"
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE" || true

  log "7/8 Enabling Session Manager (IAM profile -> agent registration -> restart if needed)"
  local prof need_restart=0 restarted=0
  prof="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE" \
          --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text 2>/dev/null || true)"
  if [ -z "$prof" ] || [ "$prof" = "None" ]; then
    echo "    no IAM instance profile attached -> attaching demo-ec2-profile"
    aws ec2 associate-iam-instance-profile --region "$AWS_REGION" --instance-id "$INSTANCE" \
      --iam-instance-profile Name=demo-ec2-profile
    need_restart=1
  else
    echo "    IAM instance profile: $prof"
  fi

  if [ "$need_restart" = 1 ]; then
    sleep 15   # IAM propagation
    if restart_instance; then restarted=1; fi
  fi

  echo "    waiting for the SSM agent to register (up to 10 min)"
  if wait_ssm_online 600; then echo "    Session Manager: Online"; return 0; fi

  if [ "$restarted" = 0 ]; then
    echo "    still not registered -> restarting the instance (restarts the SSM agent and services)"
    if restart_instance; then
      echo "    waiting for the SSM agent to register again (up to 10 min)"
      if wait_ssm_online 600; then echo "    Session Manager: Online"; return 0; fi
    fi
  fi

  warn "Session Manager is still not Online."
  ssm_diagnostics
  return 1
}

print_summary() {
  log "8/8 Done"
  cat <<SUMMARY_EOF

Connect to the private EC2 host (Session Manager):
  aws ssm start-session --target ${INSTANCE} --region ${AWS_REGION}
  # inside the session:
  sudo -i
  tail -n 5 /var/log/eks-bootstrap.log     # ends with "Bootstrap complete" once the EKS cluster is ACTIVE
  kubectl get nodes -o wide
  kubectl get pods -A -o wide

The AWS stack keeps building in the background (EKS takes ~15-25 min). Watch it with:
  kubectl get managed --no-headers | grep -v "True *True"

kubectl against EKS directly from this VM (public endpoint, separate kubeconfig so the kind context is kept):
  aws eks update-kubeconfig --name demo-eks --region ${AWS_REGION} --kubeconfig ~/eks.kubeconfig
  KUBECONFIG=~/eks.kubeconfig kubectl get nodes -o wide

Re-run just the SSM step any time:  ./00-setup.sh --ssm-only
Reminder: the AWS keys live in the kind cluster (secret aws-secret). Delete or rotate them when you are finished.
SUMMARY_EOF
}

main() {
  check_credentials_set
  if [ "$SSM_ONLY" = 1 ]; then
    command -v aws >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 || die "--ssm-only needs aws and kubectl installed (run the full setup once first)."
    kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1 || die "kind cluster '$CLUSTER_NAME' not found."
    use_aws_credentials
    enable_ssm && print_summary
    return
  fi

  [ -n "$MANIFEST" ] || die "usage: ./00-setup.sh crossplane-eks-private-all-in-one.yaml   (or --ssm-only)"
  [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found (run from the folder that contains it)."
  detect_system
  preflight_resources
  install_prerequisites "$@"
  use_aws_credentials
  create_kind_cluster
  install_crossplane
  install_providers
  configure_provider
  apply_stack
  if enable_ssm; then print_summary; else
    echo "Setup finished, but Session Manager needs attention (see the diagnostics above)."; exit 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
