# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Home infrastructure configuration repository managing a Kubernetes cluster (Talos Linux) running on 5 VMs on a NUC 11, plus Ansible automation for additional hosts. Deployments are GitOps-driven via ArgoCD—commits to main auto-sync to the cluster.

## Repository Structure

- **k8s/** — Kubernetes infrastructure (the primary content of this repo)
  - `apps/` — ArgoCD Application resources for user-facing services
  - `infra/` — ArgoCD Application resources for infrastructure components
  - `manifests/` — Actual Kubernetes manifests (Kustomize bases, Helm values) referenced by ArgoCD apps
  - `talos/prod/` — Talos Linux machine config and patches for the 5-VM cluster (1 CP + 4 workers)
  - `app-roots/` — Top-level ArgoCD app-of-apps (`all-apps.yaml`, `all-infra.yaml`)
  - `demos/` — Debug/test pods (SSH, netshoot, kuard, nginx)
- **ansible/** — Playbooks and roles for host provisioning (rpi, bastion, dpu-host, protectli)
- **bin/** — Utility scripts (power control, temperature sensors, backups, WoL)
- **mikrotik/** — MikroTik RB5009 switch configuration (RouterOS)
- **dotfiles/** — Shell/git/vim configuration files

## Key Technologies

- **Cluster**: Talos Linux v1.9.5, Cilium CNI, ArgoCD for GitOps
- **Observability**: LGTM stack (Loki, Grafana, Mimir, Alloy) in `k8s/manifests/monitoring/`
- **Storage**: MinIO (S3), Synology iSCSI, local-path-provisioner, Volsync for backups
- **Networking**: Tailscale, Cloudflare Tunnel, k8s_gateway for private DNS (`*.o.cavnet.cloud`)
- **Secrets**: External Secrets Operator, AWS IAM Roles Anywhere (`aws-iamra-manager`)
- **IaC**: Ansible (6 roles), Talos machine config patches, Kustomize

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

- **DNS**: Private zone `*.o.cavnet.cloud` served by k8s_gateway at 172.16.42.53, delegated via Tailscale DNS. Public access via Cloudflare Tunnel on `*.cavnet.io`.
- **Worker node specialization**: worker2 has a `dtcnet` taint/label and home network bridge; worker3 has USB passthrough for ESP32 serial logging.
- **Talos config patches** are layered: `common` → `cp` or `worker-common` → optional per-worker patches (`worker-dtcnet`, `worker-esp32`, `oidc`).
