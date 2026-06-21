# Talos + Kubernetes Upgrade Runbook

**Goal:** Bring the `talos-prod` cluster from **Talos 1.9.5 / Kubernetes 1.32.3** up to
**Talos 1.13.4 / Kubernetes 1.35**, upgrading the gating add-ons (Cilium, cert-manager,
Kyverno, Synology CSI) in lockstep, and retiring the custom "bluetooth-iscsi" Talos build.

**Why now:** Both Talos 1.9 and Kubernetes 1.32 are end-of-life / out of support (4 minor
versions behind). See the compatibility tables below.

> **Scope note — no HA:** This cluster runs a single control-plane node on a single NUC.
> We are intentionally **not** adding HA control plane for this upgrade. Each control-plane
> reboot is a brief (~1–3 min) API outage that we accept. Running single-replica apps will
> also blip while their worker VM reboots. (HA CP is parked — see DECISIONS / DP-5.)

> **Execution model:** This is an operational runbook, not a code plan. Each step has an
> exact command and a verification ("Confirm:"). Do **not** start a hop until the previous
> hop's verification passes. Work top-to-bottom: Phase 0 (prep) → Hop 1 → 2 → 3 → Phase 4.

---

## Global constants

| Thing | Value |
|---|---|
| Control-plane node `cp1` | `192.168.42.10` |
| Worker `worker1` (generic) | `192.168.42.100` |
| Worker `worker2` (dtcnet / Matter / BT) | `192.168.42.101` |
| Worker `worker3` (ESP32 serial) | `192.168.42.102` |
| `talosctl` endpoint | `k8s.cavnet.cloud` (= cp1) |
| Cluster API endpoint | `https://k8s.cavnet.cloud:6443` |
| Talos machine-config patches | `k8s/talos/prod/patches/` |
| Cilium (Helm, **out-of-band**, not ArgoCD) | values: `k8s/talos/prod/cilium/values.yaml` |

`worker4` (`192.168.42.103`) is referenced in old docs/DHCP but was **never joined** — ignore
it; only cp1 + worker1/2/3 exist. (Doc cleanup item in Phase 5.)

---

## Target versions (verified June 2026)

| Component | Current | Target | Notes |
|---|---|---|---|
| **Talos** | 1.9.5 (custom) | **1.13.4** | stock Image Factory image after DP-1 |
| **Kubernetes** | 1.32.3 | **1.35.x** | 1.36 deferred — see DP-4 |
| **Cilium** | 1.17.1 | **1.19.5** | step 1.17→1.18→1.19, no skipping |
| **cert-manager** | 1.17.0 | **1.20.x** | 1.17 only covers K8s ≤1.33 |
| **Kyverno** (chart) | 3.4.1 (app 1.14.1) | **3.7.x (1.17)** min for K8s 1.35; **3.8.x (1.18)** = latest | step one minor per hop; webhook = high blast radius |
| **Synology CSI driver** | 1.2.0 | **1.3.0** | + sidecars below (DP-2) |
| → csi-provisioner | 3.0.0 | **6.1.0** | |
| → csi-attacher | 3.3.0 | **4.10.0** | |
| → csi-resizer | 1.3.0 | **2.0.0** | |
| → csi-snapshotter | 4.2.1 | **7.0.2** | |
| → csi-node-driver-registrar | 2.3.0 | **2.15.0** | |
| → snapshot-controller | 8.0.1 | **8.2.0** | |
| **ArgoCD** | 3.0.2 (EOL) | **3.4.x** | bootstrap kustomize, manual |
| **VolSync** | 0.12.1 | **0.16.0** | opportunistic |
| **External Secrets Operator** | 0.15.0 | **2.5** | DP-3 — decoupled, separate project |
| **pod-identity-webhook** (chart) | 2.6.5 | latest 2.x | opportunistic |

### Talos ↔ Kubernetes support ranges

| Talos | K8s min | K8s max |
|---|---|---|
| 1.9 | 1.27 | 1.32 |
| 1.10 | 1.28 | 1.33 |
| 1.11 | 1.29 | 1.34 |
| 1.12 | 1.30 | 1.35 |
| 1.13 | 1.31 | 1.36 |

### Cilium ↔ Kubernetes tested ranges

| Cilium | K8s min | K8s max |
|---|---|---|
| 1.17 | 1.29 | 1.32 |
| 1.18 | 1.30 | 1.33 |
| 1.19 | 1.32 | 1.35 |
| 1.20 (dev) | — | 1.36 |

### Kyverno ↔ Kubernetes tested ranges (app version / Helm chart)

| Kyverno app | Helm chart | K8s min | K8s max |
|---|---|---|---|
| 1.14 *(current)* | 3.4.x | 1.29 | 1.32 |
| 1.15 | 3.5.x | 1.30 | 1.33 |
| 1.16 | 3.6.x | 1.31 | 1.34 |
| 1.17 | 3.7.x | 1.32 | 1.35 |
| 1.18 | 3.8.x | 1.33 | 1.35 |

(Helm chart `3.N` ↔ app `1.(N+10)`. Rows 1.14–1.16 and 1.18 are from Kyverno's official
version-pinned docs; 1.17 is bounded by them. One Kyverno minor per K8s minor — see hops.)

The interleave below keeps the **running** K8s inside the **running** Talos, **Cilium**, *and*
**Kyverno** ranges at every step.

---

## DECISION POINTS

These are the choices that shape the rest of the runbook. Each has a default (what the steps
below assume) plus the alternative(s) and trade-offs. Revisit before executing.

### DP-1 — How to retire the custom "bluetooth-iscsi" Talos build

The cluster boots `ghcr.io/dancavallaro/talos/installer:v1.9.5-bluetooth-iscsi`, a **custom
kernel build** bundling three things: `iscsi-tools` (official extension), `realtek-firmware`
(official extension, for the TP-Link UB500 BT dongle), and **Bluetooth kernel modules**
(custom — Talos's stock kernel ships `# CONFIG_BT is not set`, and both upstream requests to
add it were closed "not planned"). The *only* reason for the custom kernel is Bluetooth, and
the **only** consumer of Bluetooth is the `flicd` Flic-button daemon
(`k8s/manifests/flicd/`, `nodeSelector: hardware: bluetooth`). Home Assistant and Matter do
**not** use BT (Matter rides Thread/IP via `network: dtcnet`).

| Option | What | Trade-off |
|---|---|---|
| **A — Move flicd to the NUC host** *(DEFAULT)* | Run flicd as a container/service on the NUC hypervisor with the UB500 plugged into the host; remove the `flicd` workload, the `hardware: bluetooth` label, and BT USB passthrough from worker2. All 4 nodes then boot a **stock Image Factory image (iscsi-tools only)**. | **Permanently kills the per-version kernel rebuild.** One-time migration cost (flicd off-cluster + data move + client cutover). Reverts commit `12f3fe2`. |
| **B — Split installer images** | cp1/worker1/worker3 → factory (iscsi-tools); worker2 → keep custom kernel (BT + realtek-firmware + iscsi-tools), image overridden in `worker-dtcnet.patch.yaml`. | flicd stays on-cluster, but you **rebuild worker2's custom kernel once per Talos minor** (4× this upgrade). |
| **C — Status quo** | Rebuild the all-in-one custom image for every hop, all nodes. | Most work, no upside over B. |

**This runbook assumes Option A.** If you pick B or C, the Talos image in every `talosctl
upgrade` below becomes node-specific and Phase 0 §0.4 changes (you keep the custom build for
worker2 and skip the flicd migration).

### DP-2 — How to upgrade the Synology CSI stack

The driver is **not** a Helm release — `k8s/manifests/synology-csi/kustomization.yaml` pulls
raw manifests from your **`dancavallaro/synology-csi-talos` fork** (`deploy/kubernetes/v1.20/`),
which hardcodes ~2021-era sidecars (provisioner 3.0.0, snapshotter 4.2.1, registrar 2.3.0).
They run on stable GA `storage.k8s.io/v1` APIs so they *probably* survive to 1.35, but the
stack is years out of support and snapshotter 4.2.1 is mismatched with snapshot-controller 8.

| Option | What | Trade-off |
|---|---|---|
| **A — Update the fork's deploy manifests** *(DEFAULT)* | Bump driver→1.3.0 and sidecars to the target versions in your `synology-csi-talos` fork; the kustomization keeps pulling from it. | Keeps whatever Talos-specific tweak motivated the fork; you maintain the fork. |
| **B — Migrate to the maintained chart** | Switch to `christian-schlichtherle/synology-csi-chart` (tracks current driver + sidecars). | Cleaner long-term, no fork to maintain. **Must first confirm** the chart covers the reason the fork exists (verify before committing). |

**This runbook assumes Option A** and folds the CSI bump into Phase 0 (done on K8s 1.32 to
de-risk, since the new sidecars support 1.32+). If you choose B, replace §0.6 with the chart
migration and test against an existing iSCSI PVC before proceeding.

### DP-3 — When to upgrade External Secrets Operator

ESO went **1.0 GA (Nov 2025)**, promoting CRDs `external-secrets.io/v1beta1` → `v1` (breaking),
and is now at **2.5**. Going 0.15 → 2.5 crosses that GA and requires stored-object migration;
ESO supports only one-minor-at-a-time. But 0.15 keeps **functioning** through K8s 1.35.

**Default: decouple it.** Do NOT block the K8s upgrade on ESO. Treat 0.15 → 2.x as its own
follow-up project (with its own CRD-migration testing) after the cluster reaches 1.35. The
only thing to verify mid-upgrade: ESO 0.15 pods stay healthy after each K8s hop (they should).

### DP-4 — Kubernetes 1.36

**No stable Cilium supports K8s 1.36** (only Cilium 1.20-dev). **Default: stop at K8s 1.35.**
Land on Talos 1.13.4 / K8s 1.35 / Cilium 1.19, then **defer** the K8s 1.35→1.36 hop until
Cilium 1.20 reaches GA (see "Deferred" section). Re-check Cilium releases before attempting.

### DP-5 — HA control plane

Parked by user decision. Single CP, accept upgrade outages. If revisited: 3 CP (never 2 —
quorum) + a Talos native control-plane VIP (`machine.network.interfaces[].vip`), and decide
3-untainted-CP + 2-workers (5 VMs) vs 3-dedicated-CP + 3-workers (6 VMs) based on NUC RAM
(memory is the binding constraint; nodes already at 45–71%).

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
# talosctl client should be >= the highest target Talos minor (you have 1.12.1; bump to >=1.13)
talosctl version --short
# Deprecation scanner (safety net before each K8s hop)
brew install fairwindsops/tap/pluto   # or: go install github.com/doitintl/kube-no-trouble/cmd/kubent@latest
```

### 0.3 — Baseline deprecated-API scan

Built-in API removals are a **non-issue** for 1.32→1.35 (last built-in removal was 1.32's
`flowcontrol.apiserver.k8s.io/v1beta3`, already past; nothing removed in 1.33/1.34/1.35).
Run pluto anyway to catch anything in Helm-rendered manifests:

```bash
pluto detect-all-in-cluster -owide
pluto detect-files -d k8s/
```

Confirm: no rows with `REMOVED: true` for the target K8s versions. (Beta CRDs from ESO /
Kyverno / Gateway API / snapshot are component-owned, not core — they migrate with their
component upgrades, not with the K8s bump.)

### 0.4 — Build the stock Image Factory schematic (DP-1 Option A)

After flicd moves off-cluster there is **no Bluetooth and no realtek-firmware** need — every
node uses one schematic with just `iscsi-tools`.

```bash
cat > schematic.yaml <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
EOF
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# → {"id":"<SCHEMATIC_ID>"}   ← record this; installer images are:
#   factory.talos.dev/installer/<SCHEMATIC_ID>:vX.Y.Z
```

Export it for the commands below:

```bash
export SCHEMATIC=<SCHEMATIC_ID>
```

### 0.5 — Migrate flicd off the cluster (DP-1 Option A)

> This is its own mini-project with a cutover. Do it fully before Hop 1, while still on
> Talos 1.9 / K8s 1.32, so the cluster is "BT-free" before any node re-images.

1. Copy the flic database off its PVC:
   ```bash
   kubectl -n flicd cp flicd-0:/data/flic.sqlite3 ./flic.sqlite3
   ```
2. On the **NUC host** (UB500 plugged in; confirm `hciconfig` shows an `hci*` adapter), run
   flicd as a container on the host network with BT access:
   ```bash
   sudo mkdir -p /var/lib/flicd && sudo cp flic.sqlite3 /var/lib/flicd/
   docker run -d --name flicd --restart always --net host \
     --cap-add NET_ADMIN --cap-add NET_RAW \
     -v /var/lib/flicd:/data \
     ghcr.io/dancavallaro/rpi-config/flicd:0.1.3 \
     -f /data/flic.sqlite3 -s 0.0.0.0 -p 5551
   ```
   Confirm: `docker logs flicd` shows it bound to `:5551` and found the adapter.
3. **Repoint flicd clients.** The in-cluster Service was `flic.o.cavnet.cloud:5551`
   (LoadBalancer). Update whatever connects (HA / scripts) to the NUC's IP:5551, or move the
   `flic.o.cavnet.cloud` DNS record to the NUC. Verify a button press still triggers its action.
4. Remove the cluster workload and BT scheduling:
   ```bash
   git rm k8s/manifests/flicd/flicd.yaml k8s/apps/flicd.yaml   # (keep flicd/ Dockerfile if you like)
   # edit k8s/talos/prod/patches/worker-dtcnet.patch.yaml: delete the line  `hardware: bluetooth`
   ```
   Commit + let ArgoCD prune the `flicd` Application. Confirm: `kubectl get ns flicd` → gone.
5. (Optional cleanup, later) detach the BT USB device (`0x2357:0x0604`) from the worker2 VM
   in libvirt so it's free for the host. Not required for the upgrade.

Confirm before continuing: `kubectl get pods -A | grep -i flic` returns nothing, and Flic
buttons still work via the NUC.

### 0.6 — Upgrade Synology CSI (DP-2 Option A)

Done now (on K8s 1.32) to de-risk; target sidecars support 1.32+. In your
`dancavallaro/synology-csi-talos` fork, bump `deploy/kubernetes/v1.20/{controller,node,snapshotter}.yaml`:

- `ghcr.io/.../synology-csi:v1.2.0` → `v1.3.0`
- `csi-provisioner:v3.0.0` → `v6.1.0`, `csi-attacher:v3.3.0` → `v4.10.0`,
  `csi-resizer:v1.3.0` → `v2.0.0`, `csi-snapshotter:v4.2.1` → `v7.0.2`,
  `csi-node-driver-registrar:v2.3.0` → `v2.15.0`
- In `k8s/manifests/synology-csi/kustomization.yaml` bump the external-snapshotter ref
  `?ref=v8.2.0` (already pinned) and confirm the fork raw URLs resolve.

Then let ArgoCD sync (or `kubectl apply -k k8s/manifests/synology-csi/`).

Confirm:
```bash
kubectl -n synology-csi get pods            # all Running, new image tags
# exercise it: create + mount a test PVC, then snapshot
kubectl apply -f k8s/manifests/synology-csi/speedtest.yaml     # provisions an iSCSI PVC
kubectl apply -f k8s/manifests/synology-csi/snapshottest.yaml  # takes a VolumeSnapshot
kubectl get volumesnapshot -A                # READYTOUSE=true
# clean up the test objects afterward
```

### 0.7 — cert-manager 1.17 → 1.20 (do now; 1.20 supports K8s 1.32–1.35)

cert-manager is **vendored** (`k8s/manifests/cert-manager/charts/`). Re-vendor 1.20:

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm pull jetstack/cert-manager --version v1.20.x --untar \
  --untardir k8s/manifests/cert-manager/charts/
# CRDs: cert-manager does NOT auto-upgrade them. Either set `crds.enabled: true` in the
# chart values (so the chart manages them), or apply the standalone bundle first:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.x/cert-manager.crds.yaml
```

Commit; let ArgoCD sync. Confirm:
```bash
kubectl -n cert-manager get pods            # all Running on v1.20
kubectl get certificate -A                  # all READY=True (re-issue not triggered)
```

### 0.8 — Opportunistic (anytime; not gating)

- **ArgoCD 3.0.2 → 3.4.x:** bump the ref in `k8s/talos/prod/argocd/kustomization.yaml`
  (`.../argo-cd/v3.4.x/manifests/install.yaml`), `kubectl apply -k k8s/talos/prod/argocd`.
- **VolSync 0.12.1 → 0.16.0**, **pod-identity-webhook → latest 2.x**: bump versions, sync.
- **ESO:** leave at 0.15 (DP-3). Just confirm its pods are healthy after each hop.

---

## Hop 1 — Talos 1.9 → 1.10, then Kubernetes 1.32 → 1.33

### 1.1 — Update the install image in machine config (so reboots/reinstalls stay consistent)

Edit `k8s/talos/prod/patches/common.patch.yaml`, set:
```yaml
machine:
  install:
    image: factory.talos.dev/installer/<SCHEMATIC_ID>:v1.10.x
```
(Drop the old `# Custom build…` comment.) Commit.

### 1.2 — Upgrade Talos OS to 1.10, one node at a time (workers first, cp1 last)

```bash
talosctl upgrade -n 192.168.42.100 --image factory.talos.dev/installer/$SCHEMATIC:v1.10.x  # worker1
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.101 --image factory.talos.dev/installer/$SCHEMATIC:v1.10.x  # worker2
talosctl -n 192.168.42.10 health --wait-timeout 10m
talosctl upgrade -n 192.168.42.102 --image factory.talos.dev/installer/$SCHEMATIC:v1.10.x  # worker3
talosctl -n 192.168.42.10 health --wait-timeout 10m
# control plane LAST — brief API outage while it reboots (accepted)
talosctl upgrade -n 192.168.42.10  --image factory.talos.dev/installer/$SCHEMATIC:v1.10.x  # cp1
```

> ⚠️ Do **not** pass `--force` on cp1 — it skips the etcd health/member check and risks data
> loss on a single-member etcd. Plain `upgrade` preserves etcd and waits for health.

Confirm after each:
```bash
kubectl get nodes -o wide        # node returns Ready; OS-IMAGE shows Talos (v1.10.x)
talosctl -n 192.168.42.10 health
```

### 1.3 — Cilium 1.17 → 1.18 (required before K8s 1.33; 1.18 also supports current 1.32)

```bash
helm repo update cilium
# (a) apply the Gateway API CRDs version required by Cilium 1.18 (see that release's docs),
#     since gatewayAPI is enabled in values.yaml.
# (b) pre-flight check
helm install cilium-preflight cilium/cilium --version 1.18.x -n kube-system \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false
kubectl -n kube-system get pods | grep preflight   # Running/Completed, READY
helm uninstall cilium-preflight -n kube-system
# (c) upgrade
helm upgrade cilium cilium/cilium --version 1.18.x -n kube-system \
  --values k8s/talos/prod/cilium/values.yaml --set upgradeCompatibility=1.17
kubectl -n kube-system rollout status ds/cilium --timeout 10m
```

Confirm: `cilium status` (if CLI present) all green; `kubectl get pods -A` data path intact
(no CrashLoop), DNS resolves (`kubectl run t --rm -it --image=busybox -- nslookup kubernetes`).

### 1.4 — Kyverno chart 3.4 → 3.5 (app 1.14 → 1.15; required before K8s 1.33)

Kyverno 1.14 tops out at K8s 1.32; 1.15 covers 1.30–1.33 (so it's fine on current 1.32 too).
Kyverno is an ArgoCD app — bump `targetRevision` in `k8s/infra/kyverno.yaml` from `3.4.1` to
the latest `3.5.x`, commit, let ArgoCD sync. Step one minor only (CRD migrations); don't skip.

> The Kyverno chart installs/updates its own CRDs by default. If you template CRDs separately,
> apply the matching `3.5.x` CRDs first.

Confirm: `kubectl -n kyverno get pods` all Running on `:v1.15.x`; `kubectl get clusterpolicy`
intact; a normally-admitted pod still admits (webhook healthy):
`kubectl run admit-test --image=nginx --dry-run=server -o name`.

### 1.5 — Deprecation scan, then upgrade Kubernetes to 1.33

```bash
pluto detect-all-in-cluster -owide            # expect no REMOVED:true for 1.33
talosctl -n 192.168.42.10 upgrade-k8s --to 1.33.x --dry-run   # review the plan
talosctl -n 192.168.42.10 upgrade-k8s --to 1.33.x
```

Confirm:
```bash
kubectl get nodes -o wide        # all VERSION = v1.33.x
kubectl version                  # Server v1.33.x
kubectl get pods -A | grep -vE "Running|Completed"   # empty
talosctl -n 192.168.42.10 health
```

---

## Hop 2 — Talos 1.10 → 1.11, then Kubernetes 1.33 → 1.34

1. **common.patch.yaml** install image → `:v1.11.x`; commit.
2. **Talos OS → 1.11** (same node order + health checks as §1.2, image tag `:v1.11.x`).
3. **Cilium 1.18 → 1.19** (required before K8s 1.34; 1.19 supports current 1.33). Same
   procedure as §1.3 with `--version 1.19.x --set upgradeCompatibility=1.18`, and the Gateway
   API CRDs for Cilium 1.19.
4. **cert-manager** already 1.20 (covers 1.34) — no action.
5. **Kyverno chart 3.5 → 3.6** (app 1.15 → 1.16; required before K8s 1.34 — 1.15 maxes at 1.33,
   1.16 covers 1.31–1.34). Bump `targetRevision` in `k8s/infra/kyverno.yaml`, sync (§1.4 method).
6. **Scan + upgrade K8s:**
   ```bash
   pluto detect-all-in-cluster -owide
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.34.x --dry-run
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.34.x
   ```

Confirm: same checks as §1.5, all on v1.34.x. Verify ESO 0.15 pods still healthy (DP-3).

---

## Hop 3 — Talos 1.11 → 1.12, then Kubernetes 1.34 → 1.35

1. **common.patch.yaml** install image → `:v1.12.x`; commit.
2. **Talos OS → 1.12** (same node order + health checks).
3. **Cilium**: 1.19 already covers 1.35 — **no Cilium change**.
4. **cert-manager**: 1.20 covers 1.35 — no action.
5. **Kyverno chart 3.6 → 3.7** (app 1.16 → 1.17; required before K8s 1.35 — 1.16 maxes at 1.34,
   1.17 covers 1.32–1.35). Bump `targetRevision`, sync (§1.4 method). *Optional:* go straight to
   `3.8.x` (app 1.18) to land on the latest supported release — 1.18 also covers 1.35.
6. **Scan + upgrade K8s:**
   ```bash
   pluto detect-all-in-cluster -owide
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.35.x --dry-run
   talosctl -n 192.168.42.10 upgrade-k8s --to 1.35.x
   ```

Confirm: all nodes v1.35.x; `talosctl health` clean; all workloads Running.

---

## Phase 4 — Talos 1.12 → 1.13.4 (final OS bump, K8s stays 1.35)

Talos 1.13 supports K8s 1.31–1.36, so 1.35 is fine. No Kubernetes change here.

1. **common.patch.yaml** install image → `:v1.13.4`; commit.
2. **Talos OS → 1.13.4** (same node order + health checks as §1.2, tag `:v1.13.4`).

Confirm:
```bash
kubectl get nodes -o wide   # OS-IMAGE = Talos (v1.13.4), VERSION = v1.35.x
talosctl -n 192.168.42.10 health
talosctl version --short    # server tag v1.13.4 (no more custom suffix)
```

**End state: Talos 1.13.4 / Kubernetes 1.35.x / Cilium 1.19.5, stock images, no custom kernel.**

---

## Deferred — Kubernetes 1.35 → 1.36 (DP-4)

Blocked until **Cilium 1.20 reaches GA**. When it does:

1. Re-check Cilium 1.20's tested K8s range includes 1.36, and Talos 1.13's range still covers
   it (it does: 1.31–1.36).
2. Cilium 1.19 → 1.20 (§1.3 procedure, `--set upgradeCompatibility=1.19`, Gateway API CRDs).
3. `talosctl -n 192.168.42.10 upgrade-k8s --to 1.36.x` (dry-run first).

---

## Phase 5 — Post-upgrade cleanup

- Update version references to the new state: `CLAUDE.md` ("Talos Linux v1.9.5" → 1.13.4) and
  `k8s/talos/prod/README.md` (`IMAGE_PATH` and the `talosctl upgrade --image` examples → the
  factory image / v1.13.4). *(Worker-count / `worker4` docs were already corrected pre-upgrade.)*
- Update `k8s/NOTES.md` §Bluetooth: the custom-build process is retired (DP-1 Option A); note
  flicd now runs on the NUC host.
- Remove the now-unused custom installer references.
- (DP-3 follow-up project) Plan ESO 0.15 → 2.5 with the v1.0 `v1beta1`→`v1` CRD migration.

---

## Rollback / troubleshooting

- **A node won't come back after Talos upgrade:** `talosctl -n <ip> dmesg` and
  `talosctl -n <ip> logs machined`. Talos keeps the previous image — `talosctl rollback -n <ip>`
  reverts to the prior boot. (Worker rollback is safe; cp1 rollback on single etcd is the risky
  one — that's what the §0.1 snapshot is for: `talosctl -n 192.168.42.10 bootstrap` +
  `etcd snapshot restore` if etcd is lost.)
- **upgrade-k8s wedged:** it's idempotent — re-run the same `--to`. Use `--dry-run` to see what
  remains. Per-component images can be pinned with `--apiserver-image` etc. if a pull fails.
- **Cilium breaks networking:** `helm rollback cilium -n kube-system`; pods keep running, but
  new scheduling/DNS may be impaired until healthy. Don't proceed to upgrade-k8s with Cilium
  unhealthy.
- **An ArgoCD app fails to sync on a new K8s version:** check for a removed API in that app's
  rendered manifests (`pluto detect-files` on its chart), bump the chart, re-sync.

---

## Quick reference — the interleave

| Hop | Talos OS | Cilium pre-req | Kyverno (chart→app) | cert-mgr / CSI | then upgrade-k8s |
|---|---|---|---|---|---|
| 0 (prep) | 1.9 | — | — | cert-mgr→1.20; CSI bump | — |
| 1 | →1.10 | 1.17→1.18 | 3.4→3.5 (1.14→1.15) | — | 1.32→1.33 |
| 2 | →1.11 | 1.18→1.19 | 3.5→3.6 (1.15→1.16) | — | 1.33→1.34 |
| 3 | →1.12 | (1.19 ok) | 3.6→3.7 (1.16→1.17) | — | 1.34→1.35 |
| 4 | →1.13.4 | — | (opt. →3.8/1.18) | — | (stay 1.35) |
| deferred | 1.13 | 1.19→1.20 | — | — | 1.35→1.36 |
