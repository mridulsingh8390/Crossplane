# Crossplane on kind: create cloud Kubernetes clusters from YAML

Run Crossplane on a local kind cluster and use it to create a Kubernetes cluster in your cloud from one YAML file. Pick your cloud:

| Cloud | Guide | Setup script | Manifest |
|---|---|---|---|
| AWS (EKS) | [README.md](README.md) | `00-setup.sh` | `crossplane-eks-all-in-one.yaml` |
| Azure (AKS) | [README.md](README.md) | `00-setup-aks.sh` | `crossplane-aks-all-in-one.yaml` |

Each guide is self-contained: what Crossplane is, what gets created, requirements, run, connect, upgrade, delete, manual install, security notes and troubleshooting.
