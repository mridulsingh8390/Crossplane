# Crossplane on kind: Provision AWS Infrastructure from Kubernetes

This guide explains what Crossplane is, how to install it on a local **kind** cluster, and how to provision a demo AWS stack (VPC, public subnet, internet gateway, route table, security group and an EC2 instance) using Crossplane managed resources.

---

## Table of Contents

1. [What is Crossplane?](#1-what-is-crossplane)
2. [Key Concepts](#2-key-concepts)
3. [Prerequisites](#3-prerequisites)
4. [Create a kind Cluster](#4-create-a-kind-cluster)
5. [Install Crossplane](#5-install-crossplane)
6. [Install the AWS Provider](#6-install-the-aws-provider)
7. [Configure AWS Credentials](#7-configure-aws-credentials)
8. [Demo: VPC + EC2 Manifest](#8-demo-vpc--ec2-manifest)
9. [Apply and Verify](#9-apply-and-verify)
10. [Cleanup](#10-cleanup)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. What is Crossplane?

[Crossplane](https://www.crossplane.io) is an open-source, CNCF project that extends Kubernetes into a **universal control plane**. It lets you provision and manage cloud infrastructure (AWS, Azure, GCP and more) using Kubernetes-style YAML and the Kubernetes API, instead of running Terraform or CLI scripts.

**Why use it?**

| Benefit | Description |
|---|---|
| Kubernetes-native | Infrastructure is defined as Kubernetes custom resources and managed with `kubectl`, GitOps (Argo CD / Flux), and RBAC. |
| Continuous reconciliation | Controllers keep real cloud resources in sync with the desired state. Manual drift is corrected automatically. |
| Composable | Platform teams can bundle many resources into a simple custom API (Compositions / XRDs) for developers. |
| No state file | The Kubernetes API (etcd) is the source of truth, so there is no `terraform.tfstate` to store or lock. |

**Crossplane vs Terraform (quick view)**

| | Crossplane | Terraform |
|---|---|---|
| Model | Continuous reconciliation loop | Plan / apply on demand |
| State | Kubernetes etcd | State file / backend |
| Interface | `kubectl`, YAML, GitOps | HCL, CLI |
| Drift correction | Automatic | Only on next apply |

---

## 2. Key Concepts

- **Provider**: A package that adds support for an external system (for example `provider-aws-ec2`). It installs CRDs and a controller.
- **ProviderConfig**: Tells a provider how to authenticate (credentials, region and so on).
- **Managed Resource (MR)**: A Kubernetes object that maps 1:1 to a cloud resource (`VPC`, `Subnet`, `Instance`, ...). This README uses MRs directly.
- **Composition / XRD / Claim**: Higher-level abstractions to build your own platform APIs from multiple managed resources (not covered in this demo).
- **References (`...Ref`)**: Fields such as `vpcIdRef` let one resource refer to another by Kubernetes name, so Crossplane resolves the real AWS IDs for you.

---

## 3. Prerequisites

| Tool | Purpose |
|---|---|
| Docker | Container runtime used by kind |
| [kind](https://kind.sigs.k8s.io/) | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Talk to the cluster |
| [Helm 3](https://helm.sh/docs/intro/install/) | Install Crossplane |
| AWS account + IAM credentials | Permissions to create VPC and EC2 resources |

Install on Linux (example):

```bash
# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify:

```bash
docker --version
kind --version
kubectl version --client
helm version
```

---

## 4. Create a kind Cluster

```bash
kind create cluster --name crossplane-demo
```

Confirm the cluster is up:

```bash
kubectl cluster-info --context kind-crossplane-demo
kubectl get nodes
```

---

## 5. Install Crossplane

Add the Helm repo and install Crossplane into the `crossplane-system` namespace:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace
```

Verify the pods are running:

```bash
kubectl get pods -n crossplane-system
```

Expected: the `crossplane` and `crossplane-rbac-manager` pods in `Running` state.

---

## 6. Install the AWS Provider

This demo only needs EC2/VPC resources, so install the lightweight `provider-aws-ec2` (part of the Upbound AWS provider family) instead of the full AWS provider.

Create `provider.yaml`:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-ec2
spec:
  package: xpkg.upbound.io/upbound/provider-aws-ec2:v1.14.0
```

> Check [marketplace.upbound.io](https://marketplace.upbound.io/providers/upbound/provider-aws-ec2) for the latest version.

Apply and wait until it is healthy:

```bash
kubectl apply -f provider.yaml
kubectl get providers
kubectl wait provider.pkg.crossplane.io/provider-aws-ec2 --for=condition=Healthy --timeout=5m
```

You should see `INSTALLED=True` and `HEALTHY=True`. The `provider-family-aws` dependency is installed automatically.

---

## 7. Configure AWS Credentials

Create a credentials file (**never commit this file to Git**):

```bash
cat > aws-credentials.txt <<EOF
[default]
aws_access_key_id = <YOUR_ACCESS_KEY_ID>
aws_secret_access_key = <YOUR_SECRET_ACCESS_KEY>
EOF
```

Create a Kubernetes secret from it:

```bash
kubectl create secret generic aws-secret \
  -n crossplane-system \
  --from-file=creds=./aws-credentials.txt
```

Create `providerconfig.yaml`:

```yaml
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
```

```bash
kubectl apply -f providerconfig.yaml
```

The manifests below use `providerConfigRef.name: default`, which matches this ProviderConfig.

---

## 8. Demo: VPC + EC2 Manifest

Save the following as `aws-infra.yaml`. It creates:

1. VPC
2. Public subnet
3. Internet gateway
4. Public route table
5. Default route (`0.0.0.0/0` to IGW)
6. Route table association
7. Security group
8. Ingress rule (SSH, port 22)
9. Egress rule (all outbound)
10. EC2 instance with a public IP

```yaml
---
# 1. VPC
apiVersion: ec2.aws.upbound.io/v1beta1
kind: VPC
metadata:
  name: demo-vpc
spec:
  forProvider:
    region: us-east-1
    cidrBlock: 10.0.0.0/16
    enableDnsSupport: true
    enableDnsHostnames: true
    tags:
      Name: demo-vpc
  providerConfigRef:
    name: default

---
# 2. Public Subnet
apiVersion: ec2.aws.upbound.io/v1beta1
kind: Subnet
metadata:
  name: demo-public-subnet
spec:
  forProvider:
    region: us-east-1
    availabilityZone: us-east-1a
    cidrBlock: 10.0.1.0/24
    mapPublicIpOnLaunch: true
    vpcIdRef:
      name: demo-vpc
    tags:
      Name: demo-public-subnet
  providerConfigRef:
    name: default

---
# 3. Internet Gateway
apiVersion: ec2.aws.upbound.io/v1beta1
kind: InternetGateway
metadata:
  name: demo-igw
spec:
  forProvider:
    region: us-east-1
    vpcIdRef:
      name: demo-vpc
    tags:
      Name: demo-igw
  providerConfigRef:
    name: default

---
# 4. Public Route Table
apiVersion: ec2.aws.upbound.io/v1beta1
kind: RouteTable
metadata:
  name: demo-public-rt
spec:
  forProvider:
    region: us-east-1
    vpcIdRef:
      name: demo-vpc
    tags:
      Name: demo-public-rt
  providerConfigRef:
    name: default

---
# 5. Default Internet Route (0.0.0.0/0 -> Internet Gateway)
apiVersion: ec2.aws.upbound.io/v1beta1
kind: Route
metadata:
  name: demo-public-route
spec:
  forProvider:
    region: us-east-1
    routeTableIdRef:
      name: demo-public-rt
    destinationCidrBlock: 0.0.0.0/0
    gatewayIdRef:
      name: demo-igw
  providerConfigRef:
    name: default

---
# 6. Route Table Association (Links Subnet to Route Table)
apiVersion: ec2.aws.upbound.io/v1beta1
kind: RouteTableAssociation
metadata:
  name: demo-public-rta
spec:
  forProvider:
    region: us-east-1
    subnetIdRef:
      name: demo-public-subnet
    routeTableIdRef:
      name: demo-public-rt
  providerConfigRef:
    name: default

---
# 7. Security Group
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroup
metadata:
  name: demo-ec2-sg
spec:
  forProvider:
    region: us-east-1
    name: demo-ec2-sg
    description: Allow SSH inbound and all outbound traffic
    vpcIdRef:
      name: demo-vpc
    tags:
      Name: demo-ec2-sg
  providerConfigRef:
    name: default

---
# 8. Security Group Ingress Rule (Port 22 SSH)
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroupIngressRule
metadata:
  name: demo-sg-ingress-ssh
spec:
  forProvider:
    region: us-east-1
    securityGroupIdRef:
      name: demo-ec2-sg
    ipProtocol: tcp
    fromPort: 22
    toPort: 22
    cidrIpv4: 0.0.0.0/0
  providerConfigRef:
    name: default

---
# 9. Security Group Egress Rule (All Outbound Traffic)
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroupEgressRule
metadata:
  name: demo-sg-egress-all
spec:
  forProvider:
    region: us-east-1
    securityGroupIdRef:
      name: demo-ec2-sg
    ipProtocol: "-1"
    cidrIpv4: 0.0.0.0/0
  providerConfigRef:
    name: default

---
# 10. EC2 Instance with Public IP
apiVersion: ec2.aws.upbound.io/v1beta1
kind: Instance
metadata:
  name: demo-ec2-instance
spec:
  forProvider:
    region: us-east-1
    # Replace with a valid AMI ID for your target region (Amazon Linux 2023 us-east-1 example)
    ami: ami-0c7217cdde317cfec
    instanceType: t3.micro
    subnetIdRef:
      name: demo-public-subnet
    vpcSecurityGroupIdRefs:
      - name: demo-ec2-sg
    associatePublicIpAddress: true
    # Optional: Uncomment and add your EC2 Key Pair name to SSH into the instance
    # keyName: my-aws-keypair
    tags:
      Name: demo-ec2-instance
  providerConfigRef:
    name: default
```

**Notes**

- The AMI ID is region-specific and AMIs get deprecated. Look up a current Amazon Linux 2023 AMI for your region before applying.
- SSH is open to `0.0.0.0/0` for demo purposes only. Restrict `cidrIpv4` to your own IP (for example `203.0.113.10/32`) for anything beyond a throwaway test.
- Uncomment `keyName` and use an existing EC2 key pair if you want to SSH into the instance.

---

## 9. Apply and Verify

```bash
kubectl apply -f aws-infra.yaml
```

Watch the resources become ready (this takes a few minutes; dependent resources wait for the ones they reference):

```bash
kubectl get managed
```

Look for `SYNCED=True` and `READY=True` on every resource. Check individual resource types if needed:

```bash
kubectl get vpc,subnet,internetgateway,routetable,route,routetableassociation
kubectl get securitygroup,securitygroupingressrule,securitygroupegressrule
kubectl get instance
```

Describe a resource to see events and errors:

```bash
kubectl describe instance demo-ec2-instance
```

Get the instance's public IP:

```bash
kubectl get instance demo-ec2-instance -o jsonpath='{.status.atProvider.publicIp}'
```

You can also confirm in the AWS Console (EC2 and VPC, region `us-east-1`).

---

## 10. Cleanup

Delete the AWS resources first so Crossplane removes them from AWS:

```bash
kubectl delete -f aws-infra.yaml
kubectl get managed   # wait until all resources are gone
```

Then remove Crossplane and the kind cluster:

```bash
kubectl delete -f providerconfig.yaml
kubectl delete -f provider.yaml
helm uninstall crossplane -n crossplane-system
kind delete cluster --name crossplane-demo
```

> **Important:** Do not delete the kind cluster before the managed resources are deleted, or the real AWS resources will be left behind and keep costing money.

---

## 11. Troubleshooting

| Symptom | Fix |
|---|---|
| Provider is not `HEALTHY` | `kubectl describe provider provider-aws-ec2` and check the provider pod logs in `crossplane-system`. |
| Resource stuck at `SYNCED=False` | `kubectl describe <kind> <name>` and read the events (usually credentials, permissions or an invalid field). |
| `cannot resolve reference` | The referenced resource (for example `demo-vpc`) is not ready yet. Wait, or check that its name matches. |
| `InvalidAMIID.NotFound` | The AMI does not exist in the chosen region. Use a valid AMI for that region. |
| `UnauthorizedOperation` | The IAM user or role lacks EC2/VPC permissions. |
| Resources not deleting | Check for dependencies (for example, an ENI still attached to the subnet) and look at `kubectl describe` events. |

Useful debug commands:

```bash
kubectl get providers
kubectl get providerconfigs
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-ec2
kubectl get events --sort-by=.lastTimestamp
```

---

## References

- Crossplane docs: https://docs.crossplane.io
- Upbound AWS EC2 provider: https://marketplace.upbound.io/providers/upbound/provider-aws-ec2
- kind: https://kind.sigs.k8s.io
