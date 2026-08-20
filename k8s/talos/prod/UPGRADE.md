# Talos + Kubernetes Upgrade Runbook

**Current state:** Talos **1.12.11** (custom BT/iscsi build) / Kubernetes **1.35.7**, Cilium **1.19.7**,
Kyverno **1.17** (chart 3.7.2). All add-ons current and in range.

**Remaining goal:** one final hop to **Talos 1.13.9 / Kubernetes 1.36** — plus Cilium 1.19 → 1.20 and
a Kyverno minor that supports K8s 1.36.

> 🔴 **Blocked — do not start the final hop yet.** As of **2026-08-20** the newest Kyverno is
> **1.19.0, tested only to K8s 1.33–1.35**; **no Kyverno release lists K8s 1.36.** So K8s 1.36 is
> Kyverno-gated. The current state (Talos 1.12 / K8s 1.35) is fully supported — **hold here until a
> Kyverno minor adds 1.36**, then run Hop 4 below as one unit. Re-check:
> <https://kyverno.io/docs/installation/releases/>

> **Already done (2026-08, not repeated here):** Phase 0 prep (etcd snapshot, support bundles, pluto
> baseline) and Hops 1–3 — Talos 1.9.5 → 1.12.11 and K8s 1.32.3 → 1.35.7, one Talos minor per K8s
> minor, custom installer rebuilt each hop. Add-ons (Cilium 1.19.7, Kyverno 1.17 / chart 3.7.2, ESO,
> VolSync, ArgoCD, cert-manager 1.21.1, Synology CSI on the upstream chart) were already current
> before the OS jump and cover the whole 1.32–1.35 range, so those hops touched only Talos + K8s.

> **Scope — no HA:** Single control-plane node on a single NUC. We are intentionally **not** adding an
> HA control plane. Each control-plane reboot is a brief (~1–3 min) API outage we accept; single-replica
> apps blip while their worker VM reboots. (Parked HA design below.)

> **flicd stays on-cluster → the custom Talos build stays.** The 1.13.9 hop rebuilds the custom
> installer with BT modules + `realtek-firmware` + `iscsi-tools`. Settled constraint — see
> [Custom Talos build](#custom-talos-build).

---

## Global constants

| Thing | Value |
|---|---|
| Control-plane node `cp1` | `192.168.42.10` |
| Worker `worker1` (generic) | `192.168.42.100` |
| Worker `worker2` (dtcnet / Matter / **BT / flicd**) | `192.168.42.101` |
| Worker `worker3` (ESP32 serial) | `192.168.42.102` |
| `talosctl` endpoint | `k8s.cavnet.cloud` (= cp1) |
| Cluster API endpoint | `https://k8s.cavnet.cloud:6443` |
| Talos machine-config patches | `k8s/talos/prod/patches/` |
| Custom installer image (all nodes) | `ghcr.io/dancavallaro/talos/installer:<TALOS_VER>-bluetooth-iscsi` |
| Cilium (Helm, **out-of-band**, not ArgoCD) | values: `k8s/talos/prod/cilium/values.yaml` |

---

## Target versions (remaining hop)

| Component | Current | Target | Notes |
|---|---|---|---|
| **Talos** | 1.12.11 (custom) | **1.13.9** | latest 1.13; Talos 1.13 = K8s 1.31–1.36 ✓. Rebuild the custom installer for `v1.13.9` |
| **Kubernetes** | 1.35.7 | **1.36.x** | **Kyverno-gated** (top of file). K8s 1.37 needs Talos 1.14 / Cilium 1.21 — out of range |
| **Cilium** | 1.19.7 | **1.20.x** | required for K8s 1.36; 1.20 e2e-tested for K8s 1.33–1.36 (latest 1.20.1) |
| **Kyverno** (chart→app) | 3.7.2 (1.17) | **gated — see note** | newest 1.19.0 still tops at K8s 1.35; wait for a minor that lists 1.36 |
| cert-manager | 1.21.1 | — | already covers 1.36; confirm pods healthy, no action expected |

Talos ↔ K8s ranges that matter here: **1.12 = 1.30–1.35**, **1.13 = 1.31–1.36**. The Talos 1.13.9 OS
bump is what unlocks K8s 1.36; Talos 1.13 still supports the current 1.35, so the OS can move first.

Talos system extensions (`iscsi-tools`, `realtek-firmware`) are released **co-versioned with Talos** —
the `siderolabs/extensions` release for the target tag carries the matching images.

---

## Custom Talos build

flicd (the Flic-button daemon, `k8s/manifests/flicd/`, `nodeSelector: hardware: bluetooth` → worker2)
needs Bluetooth, but Talos's stock kernel ships `# CONFIG_BT is not set` and there is no official BT
system extension. So **all nodes boot a custom installer image** bundling the BT kernel modules plus the
`realtek-firmware` (UB500 dongle) and `iscsi-tools` (Synology iSCSI) extensions:
`ghcr.io/dancavallaro/talos/installer:<TALOS_VER>-bluetooth-iscsi`.

The full build (local registry → kernel → initramfs → imager → installer) is documented in
**`k8s/NOTES.md` §"Building Talos with Bluetooth support"**. Per hop, the load-bearing step is the
installer build, with base image and extensions pinned to the target version:

```bash
# (kernel/imager already built for <TAG> per NOTES.md; registry at 127.0.0.1:5005)
docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> installer \
    --base-installer-image ghcr.io/siderolabs/installer:v1.13.9 \
    --system-extension-image ghcr.io/siderolabs/realtek-firmware:<ver> \
    --system-extension-image ghcr.io/siderolabs/iscsi-tools:<ver-matching-talos-1.13> \
# tag + push → ghcr.io/dancavallaro/talos/installer:v1.13.9-bluetooth-iscsi
```

**Per-version deltas to check for the 1.13.9 build:**
- `--base-installer-image` tag → `v1.13.9`.
- Re-apply the BT changes against the target Talos's `pkgs`/`talos` source tags: replace
  `# CONFIG_BT is not set` in `pkgs` `kernel/build/config-amd64` with the **full BT block** (the HCI
  USB / RTL drivers default off, so `CONFIG_BT=m` alone isn't enough), then
  `make kernel-olddefconfig PLATFORM=linux/amd64`; and prepend the BT module lines to `talos`
  `hack/modules-amd64.txt`. Exact config block + module list + which modules the UB500 actually needs:
  NOTES.md §"BT config + module reference".
- **`iscsi-tools`** → use the image from the `siderolabs/extensions` release matching the target Talos
  tag (co-versioned with Talos). `realtek-firmware` (`20250211`) rarely changes.

> **Historical note:** Talos v1.12.5 briefly moved the `iscsi-tools` binaries off the host into the
> extension container rootfs, breaking chroot-based CSI drivers ([talos#12951]); that was fixed by the
> 1.12.11 patch this cluster now runs, verified against live Synology CSI attach/mount. Still verify
> iSCSI after the 1.13.9 hop (below) — the check is cheap and the failure mode is silent.
>
> [talos#12951]: https://github.com/siderolabs/talos/issues/12951

Confirm before using it in the hop:
`docker manifest inspect ghcr.io/dancavallaro/talos/installer:v1.13.9-bluetooth-iscsi` resolves.

---

## Parked decision — HA control plane

Single CP, accept upgrade outages. If revisited: 3 CP (never 2 — quorum) + a Talos native
control-plane VIP (`machine.network.interfaces[].vip`); decide 3-untainted-CP + 2-workers (5 VMs) vs
3-dedicated-CP + 3-workers (6 VMs) based on NUC RAM (memory is the binding constraint; nodes already at
45–71%).

---

## Hop 4 — the only remaining hop: Talos 1.13.9 → add-ons for 1.36 → Kubernetes 1.36

**Do not start until the Kyverno gate lifts** (top of file). This is the only hop that touches Cilium
and Kyverno.

### 0. Fresh backups first

The Phase-0 snapshot is stale — take a new one before touching anything:

```bash
talosctl -n 192.168.42.10 etcd snapshot ./etcd-$(date +%F).snapshot           # single-CP safety net
kubectl get all,cm,secret,pvc,ingress,gateway -A -o yaml > ./cluster-manifests-$(date +%F).yaml
```
Confirm: `etcd-*.snapshot` is non-empty (`ls -lh etcd-*.snapshot`).

### 1. Talos OS → 1.13.9

Rebuild the custom installer for `v1.13.9` ([Custom Talos build](#custom-talos-build)), then:

**(a) Update the install image** in `k8s/talos/prod/patches/common.patch.yaml`, then commit:
```yaml
machine:
  install:
    image: ghcr.io/dancavallaro/talos/installer:v1.13.9-bluetooth-iscsi
```

**(b) Re-render and validate every node config against Talos 1.13** *before* touching a node — with the
`talosctl` client bumped to ≥1.13, this catches a machine-config schema key that changed across 1.12→1.13
(`machine.features`, the `PodSecurity` `admissionControl` block, etc.) at your desk instead of on a
rebooting node:
```bash
# base configs come from `talosctl gen config` (same as the README bootstrap). For validation the
# secrets don't matter — you're schema-checking, not applying — so these are THROWAWAY. Never apply
# a freshly-genned config to the live cluster: it mints new PKI and would break node trust.
talosctl gen config talos-prod https://k8s.cavnet.cloud:6443   # controlplane.yaml, worker.yaml (+ throwaway talosconfig)
talosctl mc patch controlplane.yaml --patch @patches/common.patch.yaml --patch @patches/cp.patch.yaml --output cp.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --output worker.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --patch @patches/worker-dtcnet.patch.yaml --output worker2.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --patch @patches/worker-esp32.patch.yaml --output worker3.final.yaml
for f in cp worker worker2 worker3; do talosctl validate -m metal -c $f.final.yaml; done
```
Confirm: every config validates clean (deprecation *warnings* are fine; a hard error means a patch key
changed in the 1.13 schema — fix it before upgrading). The `gen config` output is scratch — discard it;
don't apply it and don't commit it.

**(c) Upgrade Talos OS, one node at a time (workers first, cp1 last):**
```bash
IMG=ghcr.io/dancavallaro/talos/installer:v1.13.9-bluetooth-iscsi
talosctl upgrade -n 192.168.42.100 --image $IMG   # worker1
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.101 --image $IMG   # worker2 (BT/flicd — verify BT after)
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.102 --image $IMG   # worker3
talosctl -n 192.168.42.10 health --wait-timeout 10m
# control plane LAST — brief API outage while it reboots (accepted)
talosctl upgrade -n 192.168.42.10  --image $IMG   # cp1
```
> ⚠️ Do **not** pass `--force` on cp1 — it skips the etcd health/member check and risks data loss on a
> single-member etcd. Plain `upgrade` preserves etcd and waits for health.

Confirm:
- `kubectl get nodes -o wide` — all Ready, OS-IMAGE shows Talos v1.13.9; `talosctl version --short`
  server tag `v1.13.9-bluetooth-iscsi`.
- **flicd still works** (a button press triggers its action — worker2's BT survived the custom-kernel
  rebuild).
- **worker2 dtcnet/Thread path** survived: `talosctl -n 192.168.42.101 get links` still shows `enp2s0`
  and its `enp2s0.192` VLAN up, and the Matter controller still receives the HomePod's Thread routes
  (RA-learned IPv6 routes on `enp2s0`). The `accept_ra` sysctls in `worker-dtcnet.patch.yaml` key on the
  **literal** name `enp2s0`, so a NIC rename across a kernel hop would silently no-op them and drop
  Thread routing with no error.
- **iSCSI storage still attaches** — `iscsiadm` reachable and a Synology CSI volume can attach+mount
  (bounce a pod with an iSCSI PVC, watch it re-attach).

### 2. Cilium 1.19 → 1.20

Required for K8s 1.36 (1.20 supports 1.33–1.36). Same procedure as the earlier Cilium upgrades:
```bash
helm repo update cilium
# (a) apply the Gateway API CRDs version required by Cilium 1.20 (check that release's docs;
#     bump k8s/talos/prod/cilium/kustomization.yaml, then kubectl apply -k)
# (b) pre-flight (clean render — no full values file; keep the KubePrism host):
helm template cilium/cilium --version 1.20.x -n kube-system \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false \
  --set k8sServiceHost=localhost --set k8sServicePort=7445 > cilium-preflight.yaml
kubectl create -f cilium-preflight.yaml    # verify preflight DS READY == cilium DS READY, then:
kubectl delete -f cilium-preflight.yaml
# (c) upgrade
helm upgrade cilium cilium/cilium --version 1.20.x -n kube-system \
  --values k8s/talos/prod/cilium/values.yaml --set upgradeCompatibility=1.19
kubectl -n kube-system rollout status ds/cilium --timeout 10m
```
Confirm: `cilium status` green; LB IPs (172.16.42.x) still held/ARP-reachable; gateways serving.

### 3. Kyverno → a minor that supports K8s 1.36

⚠️ **Gated (top of file).** Once a supporting minor exists, bump `targetRevision` in
`k8s/infra/kyverno.yaml` one minor at a time, let ArgoCD sync, and verify admission + the
`enable-volsync-backup` generate policy after each. **Watch the 1.20 line:** legacy
`ClusterPolicy`/`CleanupPolicy` are removed in Kyverno 1.20 — if a hop reaches 1.20, first migrate
`enable-volsync-backup` → `GeneratingPolicy` and the ReplicaSet cleanup → `DeletingPolicy`
(`policies.kyverno.io/v1`).

### 4. cert-manager

1.21.1 already covers 1.36 — confirm pods healthy, no action expected.

### 5. Scan + upgrade K8s to 1.36

```bash
pluto detect-all-in-cluster -owide                          # expect no REMOVED:true for 1.36
talosctl -n 192.168.42.10 upgrade-k8s --to 1.36.x --dry-run   # review the plan
talosctl -n 192.168.42.10 upgrade-k8s --to 1.36.x
```
Confirm: `kubectl get nodes -o wide` (all VERSION = 1.36); `kubectl get pods -A | grep -vE "Running|Completed"`
empty; `talosctl -n 192.168.42.10 health`.

### 6. Verify the identity integrations that ride on the apiserver flags

`upgrade-k8s` restarts the apiserver; these flags are unchanged in the patches but the 1.36 apiserver
exercises them fresh, so confirm end-to-end:
- **kubectl OIDC login via pocket-id** (`oidc.patch.yaml` → `oidc-issuer-url:
  pocket-id.o.cavnet.cloud`): a fresh `kubectl` auth succeeds and RBAC groups resolve.
- **AWS web-identity federation** against the custom `service-account-issuer`
  (`https://oidc.cavnet.io`, `cp.patch.yaml` — must still match the OIDC provider + jwks that
  `oidc.cavnet.io` serves). This is now the **`pod-identity-webhook` / DIY-IRSA** path
  (`k8s/manifests/oidc-provider/`), **not** the retired `aws-iamra-manager` sidecar: a
  webhook-injected workload can still `AssumeRoleWithWebIdentity` and complete an AWS operation
  (e.g. cert-manager → Route53, or an ESO fetch).

Note: the legacy `oidc-*` apiserver flags still work through 1.36 but are on the deprecation path
toward Structured Authentication Config (`AuthenticationConfiguration`) — no action for this plan, but
it's the one apiserver-flag area to watch beyond 1.36.

**End state: Talos 1.13.9 (custom BT/iscsi build) / Kubernetes 1.36.x / Cilium 1.20, flicd still
on-cluster; OIDC login + AWS web-identity federation verified.**

---

## Rollback / troubleshooting

- **A node won't come back after Talos upgrade:** `talosctl -n <ip> dmesg` and
  `talosctl -n <ip> logs machined`. Talos keeps the previous image — `talosctl rollback -n <ip>` reverts
  to the prior boot. (Worker rollback is safe; cp1 rollback on single etcd is the risky one — that's what
  the fresh snapshot is for: `talosctl -n 192.168.42.10 bootstrap` + `etcd snapshot restore` if etcd is
  lost.)
- **flicd/Bluetooth dead after the Talos hop:** the custom kernel build for 1.13.9 is missing a BT module
  or the wrong `realtek-firmware`. Rebuild the installer (check `hack/modules-amd64.txt` and the extension
  pins), re-`talosctl upgrade` worker2. Stock Talos will never carry BT.
- **upgrade-k8s wedged:** it's idempotent — re-run the same `--to`. Use `--dry-run` to see what remains.
  Per-component images can be pinned with `--apiserver-image` etc. if a pull fails.
- **Cilium breaks networking:** `helm rollback cilium -n kube-system`; pods keep running, but new
  scheduling/DNS may be impaired until healthy. Don't proceed to upgrade-k8s with Cilium unhealthy.
- **An ArgoCD app fails to sync on 1.36:** check for a removed API in that app's rendered manifests
  (`pluto detect-files` on its chart), bump the chart, re-sync.

---

## Post-upgrade cleanup

- Update version references to the new state: `CLAUDE.md` ("Talos Linux v1.12.11" → 1.13.9) and the
  Cilium `helm install --version` in `k8s/talos/prod/README.md` (1.19.7 → 1.20).
- Keep `k8s/NOTES.md` §"Building Talos with Bluetooth support" current if any build step changed (e.g. a
  new `iscsi-tools` pin). The custom build is **retained** — do not remove those notes.
