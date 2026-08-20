# Talos + Kubernetes Upgrade Runbook

**Goal:** Bring the `talos-prod` cluster from **Talos 1.9.5 / Kubernetes 1.32.3** up to
**Talos 1.13.9 / Kubernetes 1.36**.

This cluster keeps **flicd on Kubernetes**, so it **continues to run a custom Talos build** with
Bluetooth kernel modules. Every Talos hop below therefore requires **rebuilding the custom
installer image for the target version first** — see [Custom Talos build](#custom-talos-build)
before starting any hop.

**Why now:** Both Talos 1.9 and Kubernetes 1.32 are end-of-life. The gating add-ons (Cilium,
Kyverno, cert-manager, ESO, VolSync, ArgoCD, Synology CSI) are already upgraded, so the cluster is
ready for the OS/Kubernetes jump.

> **What's already done (not in scope here):** Cilium 1.19.7, Kyverno chart 3.7.2 (app 1.17),
> ESO 2.9.0, VolSync 0.16.0, ArgoCD 3.5.1, cert-manager 1.21.1, and Synology CSI (migrated to the
> upstream published chart, `0.11.2`). These are current and cover the whole K8s range below —
> **Cilium 1.19 and Kyverno 1.17 both support K8s 1.32–1.35, so no add-on changes are needed until
> the final 1.35→1.36 hop.** The remaining per-hop prep is rebuilding the custom Talos installer.

> **Scope note — no HA:** Single control-plane node on a single NUC. We are intentionally **not**
> adding an HA control plane. Each control-plane reboot is a brief (~1–3 min) API outage we accept.
> Single-replica apps also blip while their worker VM reboots.

> **Execution model:** operational runbook, not a code plan. Each step has an exact command and a
> verification ("Confirm:"). Do **not** start a hop until the previous hop's verification passes.
> Work top-to-bottom: Phase 0 (prep) → Hop 1 → 2 → 3 → Hop 4 (final).

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

## Target versions (verified August 2026)

| Component | Current | Target | Notes |
|---|---|---|---|
| **Talos** | 1.9.5 (custom) | **1.13.9** | latest 1.13 patch (bundles K8s 1.36.3); custom installer, rebuilt per version. Hop 3 lands on **1.12.11** (latest 1.12) — see the iscsi-tools note below |
| **Kubernetes** | 1.32.3 | **1.36.x** | 1.37 releases ~2026-08-26; needs Talos 1.14 / Cilium 1.21 — out of range |
| **Cilium** | 1.19.7 | **1.20.x** | **only for the 1.36 hop**; 1.20 tested for K8s 1.33–1.36 (latest 1.20.1); 1.19 covers 1.32–1.35 |
| **Kyverno** (chart→app) | 3.7.2 (1.17) | **gated — see note** | ⚠️ **as of Aug 2026 the newest Kyverno is 1.18.0, tested only to K8s 1.35. No release lists 1.36 yet, so the 1.36 hop is currently Kyverno-gated** — hold at K8s 1.35 until a Kyverno minor adds 1.36 (Hop 4 §3) |
| cert-manager | 1.21.1 | — | already current; covers through 1.36 (confirm, no action expected) |

> **Versions confirmed against upstream (2026-08-19):** Talos 1.13.9 is the latest 1.13 (Talos↔K8s
> matrix: 1.13 = K8s 1.31–1.36 ✓); latest 1.12 is 1.12.11. Cilium 1.20 is e2e-tested for K8s
> 1.33–1.36 ✓. Kyverno tops out at 1.18.0 / K8s 1.35 — **1.36 not yet supported by any Kyverno
> release** (the one blocker on reaching K8s 1.36 today). Talos system extensions
> (`iscsi-tools`, `realtek-firmware`) are now released co-versioned with Talos — the
> `siderolabs/extensions` release for your target Talos tag carries the matching extension images.

### Talos ↔ Kubernetes support ranges

| Talos | K8s min | K8s max |
|---|---|---|
| 1.9 | 1.27 | 1.32 |
| 1.10 | 1.28 | 1.33 |
| 1.11 | 1.29 | 1.34 |
| 1.12 | 1.30 | 1.35 |
| 1.13 | 1.31 | 1.36 |

Each Talos minor unlocks the next K8s minor, so the OS and K8s bumps interleave one-for-one.

### Cilium / Kyverno ↔ Kubernetes tested ranges

| Component | K8s ≤1.35 | K8s 1.36 |
|---|---|---|
| **Cilium** | 1.19 ✓ (covers 1.32–1.35) | needs **1.20** (1.33–1.36) |
| **Kyverno** | 1.17 ✓ (covers 1.32–1.35) | **none yet** — 1.18 still tops at 1.35 (gated, see Hop 4 §3) |

Because current Cilium (1.19) and Kyverno (1.17) already cover the entire 1.32→1.35 path, Hops 1–3
touch **only Talos + Kubernetes**. The add-on bumps are isolated to Hop 4 (the 1.36 step).

---

## Custom Talos build

flicd (the Flic-button daemon, `k8s/manifests/flicd/`, `nodeSelector: hardware: bluetooth` →
worker2) needs Bluetooth, but Talos's stock kernel ships `# CONFIG_BT is not set` and there is no
official BT system extension. So **all nodes boot a custom installer image** that bundles the BT
kernel modules plus the `realtek-firmware` (UB500 dongle) and `iscsi-tools` (Synology iSCSI)
extensions: `ghcr.io/dancavallaro/talos/installer:<TALOS_VER>-bluetooth-iscsi`.

**This is a settled constraint, not an option** — keeping flicd on-cluster means rebuilding this
image for each target Talos version. The full build (local registry → kernel → initramfs → imager
→ installer) is documented in **`k8s/NOTES.md` §"Building Talos with Bluetooth support"**. Per hop,
the load-bearing step is the installer build, with the base image and extensions pinned to the
target version:

```bash
# (kernel/imager already built for <TAG> per NOTES.md; registry at 127.0.0.1:5005)
docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> installer \
    --base-installer-image ghcr.io/siderolabs/installer:v1.<N>.x \
    --system-extension-image ghcr.io/siderolabs/realtek-firmware:<ver> \
    --system-extension-image ghcr.io/siderolabs/iscsi-tools:<ver-matching-talos-1.N>
# tag + push → ghcr.io/dancavallaro/talos/installer:v1.<N>.x-bluetooth-iscsi
```

**Per-version deltas to check each hop:**
- `--base-installer-image` tag → the target Talos version.
- Re-apply the BT changes against the target Talos's `pkgs`/`talos` source tags: replace
  `# CONFIG_BT is not set` in `pkgs` `kernel/build/config-amd64` with the **full BT block** (the HCI
  USB / RTL drivers default off, so `CONFIG_BT=m` alone isn't enough), then
  `make kernel-olddefconfig PLATFORM=linux/amd64`; and prepend the BT module lines to `talos`
  `hack/modules-amd64.txt`. Exact config block + module list + which modules the UB500 actually needs:
  NOTES.md §"BT config + module reference".
- **`iscsi-tools`** → use the image from the `siderolabs/extensions` release that matches the target
  Talos tag (extensions are now co-versioned with Talos — the `v1.<N>.x` extensions release carries
  the matching `iscsi-tools`; don't reuse the old standalone `v0.1.x` pin). `realtek-firmware`
  (`20250211`) rarely changes.

> 🔴 **iscsi-tools / Synology CSI regression — gates Hop 3 (→1.12).** Talos **v1.12.5** moved the
> iscsi-tools binaries off the host `/usr/local/sbin/` into the extension container rootfs, which
> **breaks chroot-based CSI drivers, Synology CSI among them** ([talos#12951]; broken 1.12.5, worked
> 1.12.4). Land Hop 3 on a 1.12 patch where this is fixed — **verify on the actual node** that
> `iscsiadm` resolves and Synology CSI can attach+mount a volume before proceeding — not an early
> 1.12.x. Latest 1.12 is **1.12.11**; confirm the fix is in whatever patch you pick against
> [talos#12951] rather than assuming. Rebuild the custom installer for that exact 1.12 patch.
>
> [talos#12951]: https://github.com/siderolabs/talos/issues/12951

Confirm before using it in a hop: `docker manifest inspect ghcr.io/dancavallaro/talos/installer:v1.<N>.x-bluetooth-iscsi` resolves.

---

## Parked decision — HA control plane

Single CP, accept upgrade outages. If revisited: 3 CP (never 2 — quorum) + a Talos native
control-plane VIP (`machine.network.interfaces[].vip`); decide 3-untainted-CP + 2-workers (5 VMs)
vs 3-dedicated-CP + 3-workers (6 VMs) based on NUC RAM (memory is the binding constraint; nodes
already at 45–71%).

---

## Phase 0 — Preparation (no Talos / K8s version change yet)

### 0.1 — Backups (do not skip)

```bash
# etcd snapshot (single CP — this is your safety net)
talosctl -n 192.168.42.10 etcd snapshot ./etcd-$(date +%F).snapshot
# Talos support bundle (machine config + state) for every node
talosctl -n 192.168.42.10,192.168.42.100,192.168.42.101,192.168.42.102 support -O ./talos-support-$(date +%F).zip
# Snapshot of all live manifests (in case an ArgoCD app misbehaves mid-upgrade)
kubectl get all,cm,secret,pvc,ingress,gateway -A -o yaml > ./cluster-manifests-$(date +%F).yaml
```

Confirm: `etcd-*.snapshot` is non-empty (`ls -lh etcd-*.snapshot`).

### 0.2 — Tooling

```bash
# talosctl client should be >= the highest target Talos minor (bump to >= 1.13)
talosctl version --short
# Deprecation scanner (safety net before each K8s hop)
brew install fairwindsops/tap/pluto   # or: go install github.com/doitintl/kube-no-trouble/cmd/kubent@latest
```

### 0.3 — Baseline deprecated-API scan

Built-in API removals are a **non-issue** for 1.32→1.36 (last built-in removal was 1.32's
`flowcontrol.apiserver.k8s.io/v1beta3`, already past). Run pluto anyway to catch anything in
Helm-rendered manifests:

```bash
pluto detect-all-in-cluster -owide
pluto detect-files -d k8s/
```

Confirm: no rows with `REMOVED: true` for the target K8s versions. (Beta CRDs from Cilium /
Kyverno / Gateway API / snapshot are component-owned, not core — they migrate with their
components, not with the K8s bump.)

---

## Hops 1–3 — Talos + Kubernetes only (no add-on changes)

Cilium 1.19 and Kyverno 1.17 already cover K8s 1.32–1.35, so these three hops touch **only** the OS
and Kubernetes. Each hop: rebuild the custom installer → bump the install image → upgrade Talos OS
(workers first, cp1 last) → scan → `upgrade-k8s`.

### The per-hop mechanic (applies to Hops 1–3)

**1. Rebuild + push the custom installer** for the target Talos version — see
[Custom Talos build](#custom-talos-build). The image tag below assumes it exists:
`ghcr.io/dancavallaro/talos/installer:v1.<N>.x-bluetooth-iscsi`.

**2. Update the install image** in `k8s/talos/prod/patches/common.patch.yaml` (so reboots/reinstalls
stay consistent), then commit:
```yaml
machine:
  install:
    image: ghcr.io/dancavallaro/talos/installer:v1.<10|11|12>.x-bluetooth-iscsi
```

Then **re-render and validate every node config against the target Talos version** *before* touching
a node — with the `talosctl` client bumped to the target minor (§0.2), this catches a machine-config
schema key that changed or was removed across the minor (`machine.features`, the `PodSecurity`
`admissionControl` block, etc.) at your desk instead of on a rebooting node:
```bash
# base configs come from `talosctl gen config` (same as the README bootstrap). For validation the
# secrets don't matter — you're schema-checking, not applying — so these are THROWAWAY. Never apply
# a freshly-genned config to the live cluster: it mints new PKI and would break node trust.
talosctl gen config talos-prod https://k8s.cavnet.cloud:6443   # writes controlplane.yaml, worker.yaml (+ throwaway talosconfig)
talosctl mc patch controlplane.yaml --patch @patches/common.patch.yaml --patch @patches/cp.patch.yaml --output cp.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --output worker.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --patch @patches/worker-dtcnet.patch.yaml --output worker2.final.yaml
talosctl mc patch worker.yaml --patch @patches/common.patch.yaml --patch @patches/worker-common.patch.yaml --patch @patches/worker-esp32.patch.yaml --output worker3.final.yaml
for f in cp worker worker2 worker3; do talosctl validate -m metal -c $f.final.yaml; done
```
Confirm: every config validates clean (deprecation *warnings* are fine; a hard error means a patch key changed in the target schema — fix it before upgrading). The `gen config` output (`controlplane.yaml`, `worker.yaml`, `talosconfig`, the `*.final.yaml`) is scratch — discard it; don't apply it and don't commit it.

**3. Upgrade Talos OS, one node at a time (workers first, cp1 last):**
```bash
IMG=ghcr.io/dancavallaro/talos/installer:v1.<N>.x-bluetooth-iscsi
talosctl upgrade -n 192.168.42.100 --image $IMG   # worker1
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.101 --image $IMG   # worker2 (BT/flicd — verify BT after)
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.102 --image $IMG   # worker3
talosctl -n 192.168.42.10 health --wait-timeout 10m
# control plane LAST — brief API outage while it reboots (accepted)
talosctl upgrade -n 192.168.42.10  --image $IMG   # cp1
```
> ⚠️ Do **not** pass `--force` on cp1 — it skips the etcd health/member check and risks data loss on
> a single-member etcd. Plain `upgrade` preserves etcd and waits for health.

Confirm: `kubectl get nodes -o wide` (node Ready, OS-IMAGE shows the new Talos); `talosctl -n 192.168.42.10 health`; **flicd still works** (a button press triggers its action — worker2's BT survived the custom-kernel rebuild).

Also confirm **worker2's dtcnet/Thread path** survived the kernel rebuild — don't check only BT:
`talosctl -n 192.168.42.101 get links` still shows `enp2s0` and its `enp2s0.192` VLAN up, and the
Matter controller still receives the HomePod's Thread routes (RA-learned IPv6 routes present on
`enp2s0`). The `accept_ra` sysctls in `worker-dtcnet.patch.yaml` key on the **literal** name
`enp2s0`, so a NIC rename across a kernel hop would silently no-op them and drop Thread routing with
no error (the dtcnet *address* is MAC-selected and would still come up, masking the break).

And confirm **iSCSI storage still attaches** — `iscsiadm` reachable and a Synology CSI volume can
attach+mount (e.g. bounce a pod with an iSCSI PVC, watch it re-attach). This matters every hop but is
**load-bearing on Hop 3 (→1.12)** because of the [iscsi-tools regression](#custom-talos-build).

**4. Scan, then upgrade Kubernetes:**
```bash
pluto detect-all-in-cluster -owide                          # expect no REMOVED:true for the target
talosctl -n 192.168.42.10 upgrade-k8s --to 1.<33|34|35>.x --dry-run   # review the plan
talosctl -n 192.168.42.10 upgrade-k8s --to 1.<33|34|35>.x
```
Confirm: `kubectl get nodes -o wide` (all VERSION = target); `kubectl get pods -A | grep -vE "Running|Completed"` empty; `talosctl -n 192.168.42.10 health`. Every `upgrade-k8s` restarts the apiserver, so also smoke-test the **identity integrations** that ride on its flags — see the fuller check in [Hop 4 §6](#hop-4--talos-112--1137-add-ons-for-136-then-kubernetes-135--136): a fresh kubectl OIDC login and one AWS-IAMRA-backed operation (e.g. cert-manager Route53) still succeed.

### The three hops

| Hop | Talos OS | then upgrade-k8s |
|---|---|---|
| **1** | 1.9 → **1.10** | 1.32 → **1.33** |
| **2** | 1.10 → **1.11** | 1.33 → **1.34** |
| **3** | 1.11 → **1.12** | 1.34 → **1.35** |

After Hop 3 the cluster is on **Talos 1.12 / K8s 1.35**, still on Cilium 1.19 / Kyverno 1.17
(both in range).

---

## Hop 4 — Talos 1.12 → 1.13.9, add-ons for 1.36, then Kubernetes 1.35 → 1.36

This is the only hop that touches Cilium and Kyverno.

1. **Talos OS → 1.13.9** — rebuild the custom installer for `v1.13.9`
   ([Custom Talos build](#custom-talos-build)), bump `common.patch.yaml`, then upgrade with the same
   node order + health checks as Hops 1–3 (`IMG=…:v1.13.9-bluetooth-iscsi`). Confirm nodes on
   `v1.13.9`, flicd still works, `talosctl version --short` server tag `v1.13.9-bluetooth-iscsi`.

2. **Cilium 1.19 → 1.20** (required for K8s 1.36; 1.20 supports 1.33–1.36). Same procedure used for
   the 1.18/1.19 upgrades:
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

3. **Kyverno → the minor that supports K8s 1.36.** ⚠️ **As of 2026-08-19 this is blocked:** the
   newest Kyverno is **1.18.0, tested only to K8s 1.35** — no release lists 1.36 yet, so **K8s 1.36
   is currently Kyverno-gated. Stop at K8s 1.35 (end of Hop 3) and defer the 1.36 hop until a Kyverno
   minor adds 1.36.** Re-check the compat matrix at that point; once a supporting minor exists, bump
   `targetRevision` in `k8s/infra/kyverno.yaml` one minor at a time, let ArgoCD sync, verify
   admission + the `enable-volsync-backup` generate policy after each. **Watch the 1.20 line:**
   legacy `ClusterPolicy`/`CleanupPolicy` are removed in Kyverno 1.20 (~Oct 2026) — if a hop reaches
   1.20, first migrate `enable-volsync-backup` → `GeneratingPolicy` and the ReplicaSet cleanup →
   `DeletingPolicy` (`policies.kyverno.io/v1`).

4. **cert-manager**: 1.21.1 already covers 1.36 — confirm pods healthy, no action expected.

5. **Scan + upgrade K8s to 1.36:**
   ```bash
   pluto detect-all-in-cluster -owide
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.36.x --dry-run
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.36.x
   ```

6. **Verify the identity integrations that ride on the apiserver flags.** These flags are unchanged
   in the patches, but the 1.36 apiserver is exercising them fresh, so confirm end-to-end:
   - **kubectl OIDC login via pocket-id** (`oidc.patch.yaml` → `--oidc-issuer-url`/`--oidc-*`): a
     fresh `kubectl` auth against `pocket-id.o.cavnet.cloud` succeeds and RBAC groups resolve.
   - **AWS IAM web-identity federation** against the custom `service-account-issuer`
     (`https://oidc.cavnet.io`, `cp.patch.yaml` — must still match the OIDC provider + jwks that
     `oidc.cavnet.io` serves): `aws-iamra-manager` sidecar injects and an IAMRA-backed operation
     (cert-manager → Route53, or an ESO fetch) still succeeds.

   Note: the legacy `--oidc-*` apiserver flags still work through 1.36 but are on the deprecation
   path toward Structured Authentication Config (`AuthenticationConfiguration`) — no action for this
   plan, but it's the one apiserver-flag area to watch beyond 1.36.

**End state: Talos 1.13.9 (custom BT/iscsi build) / Kubernetes 1.36.x / Cilium 1.20, flicd still on-cluster; OIDC login + AWS-IAMRA federation verified.**

---

## Rollback / troubleshooting

- **A node won't come back after Talos upgrade:** `talosctl -n <ip> dmesg` and
  `talosctl -n <ip> logs machined`. Talos keeps the previous image — `talosctl rollback -n <ip>`
  reverts to the prior boot. (Worker rollback is safe; cp1 rollback on single etcd is the risky one
  — that's what the §0.1 snapshot is for: `talosctl -n 192.168.42.10 bootstrap` +
  `etcd snapshot restore` if etcd is lost.)
- **flicd/Bluetooth dead after a Talos hop:** the custom kernel build for that version is missing a
  BT module or the wrong `realtek-firmware`. Rebuild the installer (check `hack/modules-amd64.txt`
  and the extension pins), re-`talosctl upgrade` worker2. Stock Talos will never carry BT.
- **upgrade-k8s wedged:** it's idempotent — re-run the same `--to`. Use `--dry-run` to see what
  remains. Per-component images can be pinned with `--apiserver-image` etc. if a pull fails.
- **Cilium breaks networking:** `helm rollback cilium -n kube-system`; pods keep running, but new
  scheduling/DNS may be impaired until healthy. Don't proceed to upgrade-k8s with Cilium unhealthy.
- **An ArgoCD app fails to sync on a new K8s version:** check for a removed API in that app's
  rendered manifests (`pluto detect-files` on its chart), bump the chart, re-sync.

---

## Phase 5 — Post-upgrade cleanup

- Update version references to the new state: `CLAUDE.md` ("Talos Linux v1.9.5" → 1.13.9) and
  `k8s/talos/prod/README.md` (the `talosctl upgrade --image` examples → the `v1.13.9-bluetooth-iscsi`
  custom image).
- Keep `k8s/NOTES.md` §"Building Talos with Bluetooth support" current if any build step changed
  (e.g. new `iscsi-tools` pin). The custom build is **retained** — do not remove those notes.

---

## Quick reference — the plan

| Hop | Custom installer | Talos OS | Cilium | Kyverno | then upgrade-k8s |
|---|---|---|---|---|---|
| 0 (prep) | — | 1.9 | — | — | — (backups, scan) |
| 1 | rebuild →1.10 | →1.10 | (1.19 ok) | (1.17 ok) | 1.32→1.33 |
| 2 | rebuild →1.11 | →1.11 | (1.19 ok) | (1.17 ok) | 1.33→1.34 |
| 3 | rebuild →1.12 | →1.12 | (1.19 ok) | (1.17 ok) | 1.34→1.35 |
| 4 | rebuild →1.13.9 | →1.13.9 | 1.19→1.20 | →1.36-compatible minor | 1.35→1.36 |
