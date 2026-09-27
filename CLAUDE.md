# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Home infrastructure configuration repository managing a Kubernetes cluster (Talos Linux) running on 4 VMs on a NUC 11, plus Ansible automation for additional hosts. Deployments are GitOps-driven via ArgoCD—commits to main auto-sync to the cluster.

## Repository Structure

- **k8s/** — Kubernetes infrastructure (the primary content of this repo)
  - `apps/` — ArgoCD Application resources for user-facing services
  - `infra/` — ArgoCD Application resources for infrastructure components
  - `manifests/` — Actual Kubernetes manifests (Kustomize bases, Helm values) referenced by ArgoCD apps
  - `talos/prod/` — Talos Linux machine config and patches for the 4-VM cluster (1 CP + 3 workers)
  - `app-roots/` — Top-level ArgoCD app-of-apps (`all-apps.yaml`, `all-infra.yaml`)
  - `demos/` — Debug/test pods (SSH, netshoot, kuard, nginx)
- **ansible/** — Playbooks and roles for host provisioning (rpi, bastion, talos-host, protectli)
- **bin/** — Utility scripts (power control, temperature sensors, backups, WoL)
- **mikrotik/** — MikroTik RB5009 switch configuration (RouterOS)
- **dotfiles/** — Shell/git/vim configuration files

## Key Technologies

- **Cluster**: Talos Linux v1.13.9, Cilium CNI, ArgoCD for GitOps
- **Observability**: LGTM stack (Loki, Grafana, Mimir, Alloy) in `k8s/manifests/monitoring/`
- **Storage**: MinIO (S3), Synology iSCSI, local-path-provisioner, Volsync for backups
- **Networking**: Multus (macvlan homenet legs), Tailscale, Cloudflare Tunnel, k8s_gateway for private DNS (`*.o.cavnet.cloud`)
- **Secrets**: External Secrets Operator; AWS access via web-identity federation / DIY IRSA (`oidc-provider` + `pod-identity-webhook`)
- **IaC**: Ansible (roles under `ansible/roles/`, including host networking and Tailscale), Talos machine config patches, Kustomize

## Common Commands

### Ansible
```shell
cd ansible && ./run                    # Run bootstrap playbook against all hosts
ansible-playbook -i inventory.ini bootstrap.yaml --limit rpi  # Single host
```

### Kubernetes / Talos
```shell
kubectl apply -k k8s/manifests/<app>/  # Apply a manifest directly
talosctl -n <NODE_IP> patch mc -p @k8s/talos/prod/patches/<patch>.yaml  # Patch machine config
talosctl upgrade -n <NODE_IP> --image ghcr.io/siderolabs/installer:<version>  # Upgrade Talos
```

### ArgoCD pattern
Apps are defined as ArgoCD `Application` resources in `k8s/apps/` and `k8s/infra/`. Each points to a manifest directory under `k8s/manifests/`. To add a new service: create the manifest in `k8s/manifests/<name>/`, then create an ArgoCD Application in `k8s/apps/` or `k8s/infra/`.

## Architecture Notes

- **DNS**: Private zone `*.o.cavnet.cloud` served by k8s_gateway at 172.16.42.53, forwarded by the MikroTik resolver (labnet, nodes) and Tailscale split DNS (Tailnet clients). Public access via Cloudflare Tunnel on `*.cavnet.io`.
- **Cluster network**: nodes on routed VLAN 11 (`10.11.0.0/24`, gateway = MikroTik); LoadBalancers on `172.16.42.0/24`, on-link via Cilium L2 announcements. See `docs/network.md`.
- **Worker node specialization**: worker2 has the Bluetooth USB passthrough (`hardware: bluetooth`); worker3 has USB passthrough for ESP32 serial logging. Every worker has an unaddressed homenet NIC, `enp9s0`, on talos-host's `br192`; pods that need the homenet (HA, Matter, UniFi, Jellyfin) get a Multus macvlan interface on it, so they run on any worker.
- **Talos config patches** are layered: `common` → `cp` or `worker-common` → optional per-worker patches (`worker-bluetooth`, `worker-esp32`, `oidc`) → the per-node `node-*.patch.yaml` (static address, hostname). Configs render from the age-encrypted secrets bundle with `--talos-version v1.9`; see `k8s/talos/prod/README.md`.
