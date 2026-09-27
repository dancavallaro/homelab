# homelab

Configuration for my home infrastructure. Most of it manages a Kubernetes cluster: Talos Linux on 4 VMs
on a NUC 11, deployed GitOps-style by ArgoCD from this repo's `main` branch.

- `k8s/` holds the ArgoCD Applications (`apps/`, `infra/`), the manifests and Helm values they point at
  (`manifests/`), and the Talos machine config (`talos/`).
- `ansible/` provisions the hosts outside the cluster: the Raspberry Pis, the bastion, the Talos
  hypervisor host, and the Protectli.
- `mikrotik/` is the RouterOS config for the MikroTik RB5009.
- `terraform/defakto/` configures Defakto (workload identity) for the cluster.
- `docs/network.md` describes the network architecture, with diagrams.
- `bin/` and `dotfiles/` hold utility scripts and shell config.
