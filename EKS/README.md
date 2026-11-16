# Crossplane on kind: create an EKS cluster on AWS from YAML

Run **Crossplane** on a local **kind** cluster and use it to create a private network, a private EC2 host (reached through SSM) and an **EKS** cluster on AWS, all from one YAML file.

| File | Purpose |
|---|---|
| `00-setup.sh` | Installs the tools, kind, Crossplane and the AWS providers, applies the YAML, then brings SSM up |
| `crossplane-eks-private-all-in-one.yaml` | All AWS resources (VPC, NAT, SSM endpoints, EC2, EKS, node group) |

---

## Table of contents

1. [What is Crossplane?](#1-what-is-crossplane)
2. [What it creates](#2-what-it-creates)
3. [Requirements](#3-requirements)
4. [Before you run](#4-before-you-run)
5. [Run](#5-run)
6. [Connect](#6-connect)
7. [Upgrade Kubernetes](#7-upgrade-kubernetes)
8. [Delete](#8-delete)
9. [Manual install (without the script)](#9-manual-install-without-the-script)
10. [Security and cost notes](#10-security-and-cost-notes)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. What is Crossplane?

[Crossplane](https://www.crossplane.io) is an open-source CNCF project that turns Kubernetes into a universal control plane. You describe cloud resources as Kubernetes objects, and Crossplane creates them through the cloud APIs and keeps them in the declared state.

- **Kubernetes-native:** infrastructure is YAML applied with `kubectl`, and works with GitOps and RBAC.
- **Continuous reconciliation:** controllers correct drift automatically.
- **No state file:** the Kubernetes API is the source of truth, so there is no Terraform state to store or lock.

Key terms:

- **Provider:** a package that adds support for a cloud (for example `provider-aws-ec2`).
- **ProviderConfig:** tells a provider how to authenticate.
- **Managed resource:** a Kubernetes object that maps 1:1 to a cloud resource (`VPC`, `Instance`, `Cluster`, ...).
- **References** (`...Ref`): fields such as `vpcIdRef` that point to another resource by name, so Crossplane resolves the real IDs.

---

## 2. What it creates

Region comes from the YAML (default `us-east-1`).

| Area | Details |
|---|---|
| Node network | VPC `10.0.0.0/16`, 2 private node subnets (2 AZs), private EC2 subnet |
| Pod network | Secondary VPC CIDR `100.64.0.0/16`, one pod subnet per AZ (VPC CNI custom networking) |
| Service network | `172.20.0.0/16` (virtual, set on the cluster) |
| Outbound | Internet gateway + NAT gateway for the private subnets |
| EC2 | Private instance, no public IP, Amazon Linux 2023, reached through **SSM Session Manager** |
| SSM | VPC endpoints for `ssm`, `ssmmessages` and `ec2messages` |
| EKS | Cluster with **public + private** API endpoint, `vpc-cni` add-on, access entry for the EC2 role |
| Nodes | One managed node group, `t2.large`, min 1 / desired 2 / max 3 |
| Versions | `version: "1.33"` on both the cluster and the node group |

The EC2 instance runs a startup script that waits for the cluster, creates the `ENIConfig` objects for the pod CIDR and restarts the CNI. Its log is `/var/log/eks-bootstrap.log` and it ends with `Bootstrap complete`.

---

## 3. Requirements

| Item | Needed |
|---|---|
| VM | Linux (Ubuntu/Debian or Amazon Linux/RHEL), x86_64 or ARM, **4 GB RAM (8 GB is comfortable), 30 GB disk**, `sudo` or root |
| Network | Outbound internet (Docker Hub, `xpkg.upbound.io`, AWS APIs) |
| AWS | An IAM user and access key |

The script installs docker, kubectl, kind, helm, the AWS CLI and the Session Manager plugin itself. It stops early if the disk has less than 15 GB free.

**IAM permissions.** For a demo, `AdministratorAccess` is the simplest. If you narrow it, it must allow VPC, EC2, EKS and IAM actions, including `iam:PassRole`, `iam:CreateRole` and `iam:CreateInstanceProfile`.

---

## 4. Before you run

1. **Keys.** Open `00-setup.sh` and paste the keys at the top, or export them:

   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   ```

2. **AMI.** The YAML has an Amazon Linux 2023 AMI ID. AMI IDs are per region and go out of date. Put the current one in the `ami:` line of the `Instance`:

   ```bash
   aws ssm get-parameter --region us-east-1 \
     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
     --query Parameter.Value --output text
   ```

3. **Region (optional).** To use another region, replace `us-east-1` everywhere in the YAML. The script reads the region from the YAML.

   ```bash
   sed -i 's/us-east-1/ap-south-1/g' crossplane-eks-private-all-in-one.yaml
   ```

   Check that `t2.large` and `t3.micro` exist in both AZs, and use an AMI from that region.

4. **API access.** `publicAccessCidrs` is `0.0.0.0/0` by default (any IP with valid AWS credentials). For anything beyond a test, replace it with your own `x.x.x.x/32`.

---

## 5. Run

Put the script and the YAML in the same folder:

```bash
chmod 700 00-setup.sh
./00-setup.sh crossplane-eks-private-all-in-one.yaml
```

Steps: tools, kind, Crossplane, providers (EC2, EKS, IAM), credentials secret, `ProviderConfig`, apply the YAML, then **enable SSM**:

- it waits for the EC2 instance;
- it attaches the IAM instance profile if it is missing;
- it reboots the instance, if needed, to restart the SSM agent and all services (only when the startup script survives a reboot, which it checks first);
- it waits until Session Manager shows `Online`.

Re-run only the SSM step any time:

```bash
./00-setup.sh --ssm-only
```

Creating the cluster and node group takes about 20-25 minutes. Watch progress (it prints nothing when everything is ready):

```bash
kubectl get managed --no-headers | grep -v "True *True"
```

---

## 6. Connect

**EC2 host (Session Manager)**

```bash
INSTANCE=$(kubectl get instance demo-ec2-instance -o jsonpath='{.status.atProvider.id}')
aws ssm start-session --target "$INSTANCE" --region us-east-1
# inside the session
sudo -i
tail -n 5 /var/log/eks-bootstrap.log
kubectl get nodes -o wide        # node IPs 10.0.x.x
kubectl get pods -A -o wide      # pod IPs 100.64.x.x
```

**From the setup VM** (the endpoint is public). Use a separate kubeconfig so the kind context Crossplane needs is kept:

```bash
aws eks update-kubeconfig --name demo-eks --region us-east-1 --kubeconfig ~/eks.kubeconfig
KUBECONFIG=~/eks.kubeconfig kubectl get nodes -o wide
```

---

## 7. Upgrade Kubernetes

The cluster and the node group each have a `version` line. Change both to the next minor version, one minor at a time:

```bash
sed -i 's/^\( *version: \)"1.33"/\1"1.34"/' crossplane-eks-private-all-in-one.yaml
kubectl apply --validate=false -f crossplane-eks-private-all-in-one.yaml
```

- The control plane must be upgraded first. If both change together, the node group retries until the control plane is done.
- EKS cannot be downgraded. To roll back, create a new cluster or node group on the older version.
- Check the `vpc-cni` add-on supports the new version.
- kubectl on the EC2 host is v1.33. It works within one minor version, so update it after upgrading.

---

## 8. Delete

```bash
kubectl delete -f crossplane-eks-private-all-in-one.yaml
kubectl get managed          # wait until empty
kind delete cluster --name crossplane-demo
```

Do not delete the kind cluster before the resources are gone, or the AWS resources stay behind and keep costing money.

---

## 9. Manual install (without the script)

```bash
# 1. kind cluster
kind create cluster --name crossplane-demo

# 2. Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

# 3. Providers. Pin the family provider to the SAME version as the others,
#    otherwise it resolves to the newest release and the versions mismatch.
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: upbound-provider-family-aws}
spec: {package: "xpkg.upbound.io/upbound/provider-family-aws:v1.14.0"}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: provider-aws-ec2}
spec: {package: "xpkg.upbound.io/upbound/provider-aws-ec2:v1.14.0"}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: provider-aws-eks}
spec: {package: "xpkg.upbound.io/upbound/provider-aws-eks:v1.14.0"}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: provider-aws-iam}
spec: {package: "xpkg.upbound.io/upbound/provider-aws-iam:v1.14.0"}
EOF
kubectl get providers          # wait until all show INSTALLED=True HEALTHY=True

# 4. Credentials
cat > aws-credentials.txt <<'EOF'
[default]
aws_access_key_id = <KEY>
aws_secret_access_key = <SECRET>
EOF
kubectl create secret generic aws-secret -n crossplane-system --from-file=creds=./aws-credentials.txt

# 5. ProviderConfig (only after the providers are healthy; the type does not exist before that)
kubectl apply -f - <<'EOF'
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata: {name: default}
spec:
  credentials:
    source: Secret
    secretRef: {namespace: crossplane-system, name: aws-secret, key: creds}
EOF

# 6. Create the stack
kubectl apply --validate=false -f crossplane-eks-private-all-in-one.yaml
```

---

## 10. Security and cost notes

- **Keys in the script.** `00-setup.sh` holds your keys once you paste them. Never commit it with real values. Commit the placeholders only, use a dedicated IAM user, and delete or rotate the keys when you finish. The credentials also live in the kind cluster as a secret, so deleting the cluster removes them.
- **Public API endpoint.** The cluster is reachable from the internet (with AWS authentication). Restrict `publicAccessCidrs` to your IP.
- **Cost.** The EKS control plane (about $0.10/hour), the NAT gateway, two `t2.large` nodes and three SSM interface endpoints bill continuously. Delete test stacks when you are done.
- **kubectl validation.** The providers install thousands of CRDs, which can make kubectl's schema download time out on small VMs. The script uses `--validate=false`, so a misspelled field name is dropped silently and not rejected. If a resource behaves oddly, compare it with `kubectl get <kind> <name> -o yaml`.

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ImagePullBackOff`, "no space left on device" | The VM disk is too small. Grow the root volume to 30 GB or more (`growpart`, `resize2fs`), delete the kind cluster and re-run. |
| `failed to download openapi ... timeout` | Use `kubectl apply --validate=false -f <file>`. The script already does. |
| A provider is not `HEALTHY` | `kubectl describe provider <name>`. Check disk and memory first. If the package is "not found", use another provider version. |
| Providers on mixed versions (family `v2.x`, others `v1.14.0`) | Pin the family provider to the same version as the others (see section 9). |
| `no matches for kind ProviderConfig` | The `ProviderConfig` was applied before the providers were healthy. Wait for them, then apply it again. |
| `yaml: control characters are not allowed` | A stray terminal character got into the file, often from pasting over SSH. Find it with `grep -nP '[\x00-\x08\x0B-\x1F\x7F]' <file> \| cat -A`, remove it, or get the file with `curl` or `git clone` instead of pasting. |
| Resources stuck at `SYNCED=False` | Often just waiting on a dependency. If it lasts over 10 minutes, `kubectl describe <kind> <name> \| tail -20` shows the real error. |
| `InvalidAMIID.NotFound` | The AMI is not valid in this region. Use the AMI lookup in section 4. |
| `TargetNotConnected` / SSM "Not connected" | The instance has no IAM profile, a wrong AMI (must be Amazon Linux 2023) or no network path to SSM. Run `./00-setup.sh --ssm-only`. It attaches the profile, restarts the instance and waits for Online. |
| `UnauthorizedOperation` / `AccessDenied` | The IAM user is missing permissions, usually `iam:PassRole` or `iam:CreateRole`. |
| `Unsupported instance type` | `t2.large` or `t3.micro` is not available in that AZ. Change the type or AZ. |

Useful commands:

```bash
kubectl get providers
kubectl get managed
kubectl get pods -n crossplane-system
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-ec2
kubectl get events --sort-by=.lastTimestamp
```

---

## References

- Crossplane docs: https://docs.crossplane.io
- Upbound AWS EC2 provider: https://marketplace.upbound.io/providers/upbound/provider-aws-ec2
- kind: https://kind.sigs.k8s.io
