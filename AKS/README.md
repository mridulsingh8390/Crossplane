# Crossplane on kind: create an AKS cluster on Azure from YAML

Run **Crossplane** on a local **kind** cluster and use it to create a resource group, a VNet and an **AKS** cluster on Azure, all from one YAML file.

| File | Purpose |
|---|---|
| `00-setup-aks.sh` | Installs the tools, kind, Crossplane and the Azure providers, applies the YAML, waits, and writes the kubeconfig |
| `crossplane-aks-all-in-one.yaml` | All Azure resources (resource group, VNet, subnet, AKS cluster) |

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

- **Provider:** a package that adds support for a cloud (for example `provider-azure-network`).
- **ProviderConfig:** tells a provider how to authenticate.
- **Managed resource:** a Kubernetes object that maps 1:1 to a cloud resource (`ResourceGroup`, `VirtualNetwork`, `KubernetesCluster`, ...).
- **References** (`...Ref`): fields such as `virtualNetworkNameRef` that point to another resource by name, so Crossplane resolves the real IDs.

---

## 2. What it creates

Region defaults to `eastus`.

| Area | Details |
|---|---|
| Resource group | `demo-aks-rg` |
| Node network | VNet `10.0.0.0/16`, node subnet `10.0.1.0/24` |
| Pod network | Azure CNI **Overlay**, pod CIDR `10.244.0.0/16` (virtual, not part of the VNet) |
| Service network | `172.20.0.0/16`, DNS service IP `172.20.0.10` |
| AKS | Public API endpoint, system-assigned identity, Free tier |
| Nodes | One node pool, 2 x `Standard_D2s_v3` (2 vCPU / 8 GB) |
| Versions | `kubernetesVersion` (control plane) and `orchestratorVersion` (node pool) set explicitly |

There is no jump VM, because the API endpoint is public. Crossplane publishes the kubeconfig into the secret `demo-aks-kubeconfig`, and the script writes it to `~/aks.kubeconfig`.

---

## 3. Requirements

| Item | Needed |
|---|---|
| VM | Linux (Ubuntu/Debian or Amazon Linux/RHEL), x86_64 or ARM, **4 GB RAM (8 GB is comfortable), 30 GB disk**, `sudo` or root |
| Network | Outbound internet (Docker Hub, `xpkg.upbound.io`, `login.microsoftonline.com`, `management.azure.com`) |
| Azure | A service principal with **Contributor** on the subscription |

The script installs docker, kubectl, kind, helm and python3 itself. It needs no Azure CLI. It stops early if the disk has less than 15 GB free.

---

## 4. Before you run

1. **Service principal.** Create it once (Azure Cloud Shell or any machine with `az`):

   ```bash
   az ad sp create-for-rbac --name crossplane-aks --role Contributor --scopes /subscriptions/<SUBSCRIPTION_ID>
   ```

   Map the output: `appId` is `AZURE_CLIENT_ID`, `password` is `AZURE_CLIENT_SECRET`, `tenant` is `AZURE_TENANT_ID`.

2. **Keys.** Open `00-setup-aks.sh` and paste the four values (client ID, client secret, tenant ID, subscription ID) at the top, or export them.

3. **Resource providers.** The subscription needs these registered:

   ```bash
   az provider register --namespace Microsoft.ContainerService
   az provider register --namespace Microsoft.Network
   ```

4. **Settings (optional).** At the top of the script, or as environment variables:

   | Setting | Default | Meaning |
   |---|---|---|
   | `AZURE_LOCATION` | `eastus` | Azure region |
   | `K8S_VERSION` | empty | Empty = latest patch of the default AKS version in the region. `1.32` = latest patch of 1.32. `1.32.7` = exact. |
   | `VM_SIZE` | `Standard_D2s_v3` | Node size |
   | `NODE_COUNT` | `2` | Number of nodes |
   | `PROVIDER_VERSION` | `v2.6.0` | Upbound Azure provider version |

5. **API access.** The API endpoint is open to the internet (with authentication). To restrict it, uncomment `apiServerAccessProfile` in the YAML and set `authorizedIpRanges` to your own `x.x.x.x/32`.

---

## 5. Run

Put the script and the YAML in the same folder:

```bash
chmod 700 00-setup-aks.sh
./00-setup-aks.sh crossplane-aks-all-in-one.yaml
```

Steps: tools, kind, Crossplane, providers (family, network, containerservice), credentials secret, `ProviderConfig`, pick a supported AKS version for your region (this also checks your Azure login), apply the YAML, wait until the resources are ready, write `~/aks.kubeconfig`. AKS usually takes 5-15 minutes.

The script writes the YAML it applied, with your settings filled in, to `crossplane-aks.generated.yaml`. It contains no secrets.

Watch progress (it prints nothing when everything is ready):

```bash
kubectl get managed --no-headers | grep -v "True *True"
```

---

## 6. Connect

```bash
export KUBECONFIG=~/aks.kubeconfig
kubectl get nodes -o wide        # node IPs 10.0.1.x
kubectl get pods -A -o wide      # pod IPs 10.244.x.x
kubectl get svc -A               # service IPs 172.20.x.x
unset KUBECONFIG                 # back to the kind cluster (kubectl get managed)
```

The kubeconfig is kept separate so the kind context Crossplane needs is not overwritten. To fetch it again:

```bash
./00-setup-aks.sh --kubeconfig
```

Or by hand:

```bash
kubectl get secret demo-aks-kubeconfig -n crossplane-system -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/aks.kubeconfig
```

---

## 7. Upgrade Kubernetes

Change both `kubernetesVersion` and `orchestratorVersion` in the YAML to the next minor version (one minor at a time), then re-apply. Or let the script pick the latest patch:

```bash
K8S_VERSION=1.33 ./00-setup-aks.sh crossplane-aks-all-in-one.yaml
```

The control plane and the node pool are one resource, so Azure orders the upgrade itself (control plane first). AKS cannot be downgraded. To roll back, create a new cluster on the older version.

---

## 8. Delete

```bash
./00-setup-aks.sh crossplane-aks-all-in-one.yaml --destroy                    # waits until all Azure resources are gone
./00-setup-aks.sh crossplane-aks-all-in-one.yaml --destroy --delete-cluster   # ...and removes kind too
```

Do not delete the kind cluster before the resources are gone, or the Azure resources stay behind and keep costing money.

---

## 9. Manual install (without the script)

```bash
# 1. kind cluster
kind create cluster --name crossplane-demo

# 2. Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace

# 3. Providers. Pin all of them, including the family provider, to the SAME version.
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: upbound-provider-family-azure}
spec: {package: "xpkg.upbound.io/upbound/provider-family-azure:v2.6.0"}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: provider-azure-network}
spec: {package: "xpkg.upbound.io/upbound/provider-azure-network:v2.6.0"}
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: {name: provider-azure-containerservice}
spec: {package: "xpkg.upbound.io/upbound/provider-azure-containerservice:v2.6.0"}
EOF
kubectl get providers          # wait until all show INSTALLED=True HEALTHY=True

# 4. Credentials (JSON with the four values)
cat > azure-credentials.json <<'EOF'
{"clientId": "<APP_ID>", "clientSecret": "<PASSWORD>", "subscriptionId": "<SUBSCRIPTION_ID>", "tenantId": "<TENANT_ID>"}
EOF
kubectl create secret generic azure-secret -n crossplane-system --from-file=creds=./azure-credentials.json

# 5. ProviderConfig (only after the providers are healthy; the type does not exist before that)
kubectl apply -f - <<'EOF'
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata: {name: default}
spec:
  credentials:
    source: Secret
    secretRef: {namespace: crossplane-system, name: azure-secret, key: creds}
EOF

# 6. Create the stack. First replace REPLACE_K8S_VERSION in the YAML with a supported AKS version, e.g. "1.32.7"
#    (list versions with: az aks get-versions --location eastus -o table)
kubectl apply --validate=false -f crossplane-aks-all-in-one.yaml
```

---

## 10. Security and cost notes

- **Secrets in the script.** `00-setup-aks.sh` holds the service principal secret once you paste it. Never commit it with real values. Commit the placeholders only, and rotate or delete the secret when you finish. The credentials also live in the kind cluster as a secret, so deleting the cluster removes them.
- **Public API endpoint.** The cluster is reachable from the internet (with authentication). Restrict it with `authorizedIpRanges`.
- **Cost.** Two `Standard_D2s_v3` nodes and the load balancer bill continuously. The control plane is on the Free tier. Delete test stacks when you are done.
- **kubectl validation.** The providers install many CRDs, which can make kubectl's schema download time out on small VMs. The script uses `--validate=false`, so a misspelled field name is dropped silently and not rejected. If a resource behaves oddly, compare it with `kubectl get <kind> <name> -o yaml`.

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ImagePullBackOff`, "no space left on device" | The VM disk is too small. Grow the root volume to 30 GB or more, delete the kind cluster and re-run. |
| `failed to download openapi ... timeout` | Use `kubectl apply --validate=false -f <file>`. The script already does. |
| A provider is not `HEALTHY` | `kubectl describe provider <name>`. If the package is "not found", that version does not exist: set `PROVIDER_VERSION=<another tag>`. |
| `no matches for kind ProviderConfig` | The `ProviderConfig` was applied before the providers were healthy. Wait for them, then apply it again. |
| Azure login failed | Check `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` and `AZURE_TENANT_ID`. The secret may be expired. |
| "could not list AKS versions" | Check `AZURE_SUBSCRIPTION_ID`, the location name (for example `eastus`, not "East US") and that the service principal has access to the subscription. |
| `MissingSubscriptionRegistration` | Register `Microsoft.ContainerService` and `Microsoft.Network` (section 4). |
| VM size not available or quota exceeded | Set another `VM_SIZE`, or request quota for your region. |
| Subnet "join" permission error | The cluster identity needs the Network Contributor role on the VNet. |
| Resources stuck at `SYNCED=False` | Often just waiting on a dependency. If it lasts over 10 minutes, `kubectl describe <kind> <name> \| tail -20` shows the real error. |
| `yaml: control characters are not allowed` | A stray terminal character got into the file, often from pasting over SSH. Find it with `grep -nP '[\x00-\x08\x0B-\x1F\x7F]' <file> \| cat -A`, remove it, or get the file with `curl` or `git clone`. |
| Kubeconfig secret has no `kubeconfig` key | The script prints the keys that exist. Tell me which ones, or take the kubeconfig from the Azure portal. |

Useful commands:

```bash
kubectl get providers
kubectl get managed
kubectl describe kubernetescluster demo-aks | tail -20
kubectl get pods -n crossplane-system
kubectl get events --sort-by=.lastTimestamp
```

---

## References

- Crossplane docs: https://docs.crossplane.io
- Upbound Azure providers: https://marketplace.upbound.io/providers/upbound/provider-azure-containerservice
- kind: https://kind.sigs.k8s.io
