# Rotating the Talos API and etcd CAs

Use this after the Talos machine CA (`machine.ca`, the `os` CA in the secrets bundle) or the etcd
CA (`cluster.etcd.ca`) is exposed. It leaves the Kubernetes CA alone.

- **Talos API CA:** `talosctl rotate-ca` rotates it with no reboots and doesn't interrupt traffic
  inside the cluster. See [CA rotation](https://docs.siderolabs.com/talos/v1.13/security/ca-rotation).
- **etcd CA:** neither that page nor `rotate-ca` covers it. Step 4 is our own procedure, and it
  relies on etcd having one member. It reboots the control plane.

Order matters. Rotate the Talos API CA first, because anyone with the old machine CA key can read
the control plane's machine config, which would include the new etcd CA.

**What exposure means:** the machine CA key mints `os:admin` client certificates for every node's
Talos API (port 50000). Every pod can reach that port, because only `orca` has an egress policy.
`os:admin` reads full machine configs, so it reads every other cluster secret. Rotation stops
future use but doesn't undo a read that already happened. If someone could have used the key
before rotation, you'd also need to rotate the Kubernetes CA, the service-account signing key, the
secretbox key, the trustd token and the cluster secret.

## Who uses the Talos API

| Client | Role | Where its talosconfig comes from |
|---|---|---|
| Admin (Dan) | `os:admin` | `~/.talos/config`, plus any other copies, such as other laptops or the password manager |
| `orca/orca-talos` | `os:reader` | Talos writes a Secret for the `talos.dev` ServiceAccount; the Orca pod mounts it |
| `cluster-archiver/cluster-archiver-talos-secrets` | `os:admin` | Same mechanism; the CronJob runs at 05:00 UTC |

## What breaks, and when

- **`rotate-ca` phases:**
  1. Add the new CA as accepted.
  2. Make the new CA the issuing CA, still accepting the old one.
  3. Remove the old CA.
  4. Write the new talosconfig.
- **From phase 2:** nodes present server certificates from the new CA. Any talosconfig that trusts
  only the old CA fails with `x509: certificate signed by unknown authority`. That includes Orca's
  talosconfig and cluster-archiver's until Talos reissues them in step 3.
- **From phase 3:** nodes reject client certificates signed by the old CA.
- **Kubernetes:** unaffected by the Talos API rotation (`--kubernetes=false`).
- **etcd step:** the control plane reboots, so the Kubernetes API is down for a few minutes.
  Pods on workers keep running. ArgoCD, controllers and certificate renewals pause until it's back.
- **Timing:** avoid 05:00 to 07:30 UTC, when cluster-archiver and the Volsync movers run.

## 0. Prepare

Use a talosctl that matches the cluster's Talos version. `rotate-ca` and `gen secrets` write
machine configs and the secrets bundle in the client's format. Run the helpers below in bash, not
fish. Your custom installer reports `v1.13.9-dirty`, so expect a warning on every command that the
server is older than the client. You can ignore it.

Work in a private directory. Its files will hold new CA keys and an etcd snapshot. Leave it out of
backups. On macOS, `tmutil addexclusion` keeps it out of Time Machine.

```shell
umask 077
mkdir -p ~/talos-rotate && cd ~/talos-rotate
tmutil addexclusion ~/talos-rotate 2>/dev/null
cp ~/.talos/config ~/.talos/config.pre-rotate

NODES=10.11.0.10,10.11.0.100,10.11.0.101,10.11.0.102

# Strip PEM blocks, crt/key/token/secret values and long base64 runs, so the output is safe to share.
redact() { sed -E '/-----BEGIN/,/-----END/d; s/((crt|key|Key|token|secret|Secret)[A-Za-z]*:[[:space:]]*).+/\1<redacted>/' \
  | grep -v -E '[A-Za-z0-9+/]{40,}'; }
# Print the base64 certificate under a rotate-ca log heading, e.g. logca rotate.log Current | b64fp
logca() { awk -v h="^> $2 Talos CA" '$0 ~ h {getline; print $2}' "$1"; }
# Print the subject, expiry and fingerprint of a base64-encoded PEM certificate read from stdin.
b64fp() { base64 -d | openssl x509 -noout -subject -enddate -fingerprint -sha256; }
# Print the base64-encoded CA of a talosconfig's current context.
tcfg_ca() { ctx=$(yq '.context' "$1"); yq ".contexts.\"$ctx\".ca" "$1"; }
# Print a node's live machine config. Writes it to stdout, so only ever pipe it into yq.
livemc() { talosctl -n "$1" get mc v1alpha1 -o yaml | yq '.spec'; }
```

Record the baseline:

```shell
tcfg_ca ~/.talos/config | b64fp > ca-talos-old.txt; cat ca-talos-old.txt
livemc 10.11.0.10 | yq '.cluster.etcd.ca.crt' | b64fp > ca-etcd-old.txt; cat ca-etcd-old.txt
for n in ${NODES//,/ }; do echo "$n acceptedCAs=$(livemc $n | yq '.machine.acceptedCAs | length')"; done   # 0 each
talosctl -n $NODES version --short                       # all four answer
talosctl -n 10.11.0.10 service etcd                      # Running, HEALTH OK
kubectl get nodes                                        # all Ready
```

## 1. Rotate the Talos API CA

### Dry run

`--dry-run` defaults to true. The repo renders configs without docs or examples, so turn those off
here as well, or `rotate-ca` writes them into every node's config.

```shell
talosctl -n 10.11.0.10 rotate-ca --talos=true --kubernetes=false \
  --control-plane-nodes 10.11.0.10 --worker-nodes 10.11.0.100,10.11.0.101,10.11.0.102 \
  --with-docs=false --with-examples=false --output ./talosconfig.new \
  > dryrun.log 2>&1; echo "exit $?"
redact < dryrun.log                    # safe to share: the phases and node list, no keys
logca dryrun.log Current | b64fp       # matches ca-talos-old.txt
rm dryrun.log                          # it holds the current and a throwaway CA key
```

**Checks:**

- The exit code is 1. The log ends with `failed to create new client with rotated Talos CA:
  failed to determine endpoints`. That's a talosctl v1.13.9 dry-run bug: after the dry run,
  `rotate-ca` builds a client from a talosconfig it never generated. It's harmless.
- Every phase shows `OK (dry-run)` or `skipped (dry-run)`, and the log ends with
  `Dry-run mode enabled, no changes were made`.
- The topology lists 1 control plane node and 3 workers.
- No phase reports an error.
- `--kubernetes=false` shows as no Kubernetes phases.
- `talosctl -n $NODES version --short` still works, because nothing changed.

### Real run

The log will contain the new CA certificate and key. Don't share it. It's also your recovery path
until step 5 is done.

```shell
talosctl -n 10.11.0.10 rotate-ca --talos=true --kubernetes=false --dry-run=false \
  --control-plane-nodes 10.11.0.10 --worker-nodes 10.11.0.100,10.11.0.101,10.11.0.102 \
  --with-docs=false --with-examples=false --output ./talosconfig.new \
  > rotate.log 2>&1; echo "exit $?"     # expect 0
redact < rotate.log
logca rotate.log Current | b64fp        # matches ca-talos-old.txt
logca rotate.log New | b64fp            # matches the CA in talosconfig.new (below)
```

### Checks

```shell
tcfg_ca talosconfig.new | b64fp | tee ca-talos-new.txt    # different fingerprint from ca-talos-old.txt
tcfg_ca talosconfig.new | base64 -d > ca-talos-new.pem

# The new admin config works on every node.
talosctl --talosconfig talosconfig.new -e 10.11.0.10 -n $NODES version --short

# Each node runs the new CA, with no leftover acceptedCAs, and only the control plane holds the key.
for n in ${NODES//,/ }; do
  m=$(talosctl --talosconfig talosconfig.new -e 10.11.0.10 -n $n get mc v1alpha1 -o yaml | yq '.spec')
  echo "$n acceptedCAs=$(echo "$m" | yq '.machine.acceptedCAs | length') keylen=$(echo "$m" | yq '(.machine.ca.key // "") | length')"
  echo "$m" | yq '.machine.ca.crt' | b64fp | grep -i fingerprint
done
# Expect acceptedCAs=0 everywhere, keylen>0 only on 10.11.0.10, and every fingerprint matching ca-talos-new.txt.

# Each node's Talos API serves a certificate from the new CA. The workers need direct reach to port 50000.
for n in ${NODES//,/ }; do echo "$n $(openssl s_client -connect $n:50000 -CAfile ca-talos-new.pem </dev/null 2>&1 | grep 'Verify return code')"; done
# Expect 0 (ok)

# The old client certificate is refused, even with the new CA trusted. This proves the old key no longer works.
old_ctx=$(yq '.context' ~/.talos/config.pre-rotate)
yq ".contexts.\"$old_ctx\".ca = \"$(tcfg_ca talosconfig.new)\"" ~/.talos/config.pre-rotate > hybrid.cfg
for n in ${NODES//,/ }; do talosctl --talosconfig hybrid.cfg -e $n -n $n version --short 2>&1 | tail -1; done
# Expect an authentication or TLS error on every node, and no version output.
rm hybrid.cfg
```

Orca can check the control plane from its side: its talosconfig verifies the CP's certificate
only after step 3.

### If `rotate-ca` stops partway

Don't just run it again. Each run generates another CA. Instead, read `redact < rotate.log` to
find the last phase that completed.

- **Before "new CA as issuing":** the old talosconfig still works.
  1. Check `.machine.acceptedCAs` on each node.
  2. Remove any extra entry with
     `talosctl -n <node> patch mc -p '[{"op":"remove","path":"/machine/acceptedCAs"}]'`.
  3. Start again from the dry run.
- **Between "new CA as issuing" and "remove old CA":** nodes still accept the old client
  certificate, but they present new-CA server certificates.
  1. Build `hybrid.cfg` as in the checks above. It's the old client certificate with the new CA's
     certificate from the log, and it works on every switched node. Nodes that haven't switched
     still accept `~/.talos/config.pre-rotate`.
  2. Finish by following the manual steps on the CA rotation page.
- **After "remove old CA", with no `talosconfig.new` written:** use the new CA certificate and key
  from `rotate.log`. Mint an `os:admin` client certificate with `talosctl gen key`,
  `talosctl gen csr --roles os:admin` and `talosctl gen crt`. Then build a talosconfig with
  `talosctl config new`, or write one by hand.

Keep `rotate.log` and `~/.talos/config.pre-rotate` until step 5 is merged.

## 2. Update the admin talosconfig

```shell
talosctl config contexts                       # note the context name, e.g. talos-prod
talosctl config remove talos-prod              # remove the old, dead context so the merge keeps its name
talosctl config merge ./talosconfig.new
talosctl config context talos-prod             # use the name merge reports, if it differs
talosctl config endpoint k8s.cavnet.cloud
```

**Checks:**

- `talosctl config info` shows role `os:admin` and an expiry about a year out.
- `talosctl -n $NODES version --short` works.
- `tcfg_ca ~/.talos/config | b64fp` matches `ca-talos-new.txt`.

Replace every other copy of the admin talosconfig, including the one in the password manager.

## 3. Reissue the `talos.dev` ServiceAccount talosconfigs

Talos issues each Secret from the machine CA. Check whether it already carries the new CA. The
fingerprint of the CA certificate is the only thing printed.

```shell
for s in orca/orca-talos cluster-archiver/cluster-archiver-talos-secrets; do
  echo "$s $(kubectl -n ${s%/*} get secret ${s#*/} -o jsonpath='{.data.config}' | base64 -d \
    | yq '.contexts[].ca' | b64fp | grep -i fingerprint)"
done
```

If either still shows the old fingerprint, force Talos to reissue it:

1. Delete the Secret, for example `kubectl -n orca delete secret orca-talos`.
2. If Talos hasn't recreated it within a minute, delete the ServiceAccount instead, for example
   `kubectl -n orca delete serviceaccounts.talos.dev orca-talos`. ArgoCD self-heal recreates it
   from `k8s/manifests/orca/talos.yaml` or `k8s/manifests/cluster-archiver/resources.yaml`, and
   Talos issues a new Secret.

**Checks:**

- **Fingerprints:** rerun the loop above. Both should match `ca-talos-new.txt`.
- **Orca:** the pod mounts the Secret as a volume, so the new talosconfig arrives within a minute
  or two with no restart. In an Orca terminal, run `talosctl config info`, which should show
  `os:reader`, and `talosctl -n 10.11.0.10 version`, which should answer.
- **cluster-archiver:** each CronJob run picks up the current Secret. Test it now. This also
  leaves a fresh etcd backup in S3 ahead of step 4.

  ```shell
  kubectl -n cluster-archiver create job --from=cronjob/cluster-archiver ca-rotate-check
  kubectl -n cluster-archiver wait --for=condition=complete job/ca-rotate-check --timeout=15m
  kubectl -n cluster-archiver logs job/ca-rotate-check | tail -2   # ends with upload: ... to s3://nuc-talos-backups/...
  kubectl -n cluster-archiver delete job ca-rotate-check
  ```

## 4. Rotate the etcd CA

**Not documented by Sidero.** This procedure relies on etcd having a single member, and works like
this:

- Talos generates etcd's server and peer certificates, the API server's etcd client certificate
  and its own etcd client certificate from `cluster.etcd.ca`.
- With one member, there's no peer that would need to trust both CAs during a rollover.
- The CA isn't stored in etcd's data, so swapping the CA and rebooting brings everything back
  under the new CA.

With more than one control plane node, don't use this. etcd can't trust two CAs during a
rollover, so that case needs its own plan.

### Prepare

```shell
talosctl -n 10.11.0.10 etcd snapshot etcd-pre.db           # holds every Kubernetes Secret
livemc 10.11.0.10 > cp-pre-etcd.yaml                           # for revert; already has the new Talos CA

talosctl gen secrets -o fresh.yaml                         # throwaway bundle: only its etcd CA is used
yq -n '.cluster.etcd.ca.crt = load("fresh.yaml").certs.etcd.crt | .cluster.etcd.ca.key = load("fresh.yaml").certs.etcd.key' \
  > etcd-ca.patch.yaml
rm fresh.yaml
yq '.cluster.etcd.ca.crt' etcd-ca.patch.yaml | b64fp | tee ca-etcd-new.txt   # differs from ca-etcd-old.txt
```

### Dry run

```shell
talosctl -n 10.11.0.10 patch mc -p @etcd-ca.patch.yaml --dry-run 2>&1 | redact | grep -E '^[-+@]|[Dd]ry run|reboot'
```

**Checks:** the diff should change only `crt` and `key` under `cluster.etcd.ca`, which shows as two
`-` lines and two `+` lines with the values redacted. Nothing else should change.

### Apply

```shell
talosctl -n 10.11.0.10 patch mc -p @etcd-ca.patch.yaml --mode=reboot
```

### Checks

Wait for the node to come back, typically 2 to 5 minutes.

```shell
talosctl -n 10.11.0.10 service etcd                            # Running, HEALTH OK
talosctl -n 10.11.0.10 etcd status                             # same member ID and DB size as before, no ERRORS
talosctl -n 10.11.0.10 logs etcd | grep -c -i -E 'bad certificate|unknown authority|handshake'   # 0
kubectl get --raw='/readyz/etcd'; echo                         # ok
kubectl get nodes                                              # all Ready
kubectl -n kube-system logs kube-apiserver-talos-prod-cp1 | grep -c -i x509   # 0
livemc 10.11.0.10 | yq '.cluster.etcd.ca.crt' | b64fp              # matches ca-etcd-new.txt

# etcd serves a certificate from the new CA. Needs reach to port 2379; the two key IDs must match.
openssl s_client -connect 10.11.0.10:2379 </dev/null 2>/dev/null | openssl x509 -noout -ext authorityKeyIdentifier
yq '.cluster.etcd.ca.crt' etcd-ca.patch.yaml | base64 -d | openssl x509 -noout -ext subjectKeyIdentifier
```

Then check ArgoCD (all apps Synced/Healthy) and run the cluster-archiver test job from step 3
again. It runs `etcd snapshot` through Talos's new etcd client certificate.

### If etcd doesn't come back

The Talos API doesn't depend on etcd, so you can still revert:

```shell
talosctl -n 10.11.0.10 apply-config -f cp-pre-etcd.yaml --mode=reboot
```

That restores the old etcd CA, which is still exposed, so treat the revert as temporary. If etcd's
data is damaged, follow the Talos disaster recovery guide: reset the control plane's EPHEMERAL
partition, then run `talosctl bootstrap --recover-from=./etcd-pre.db`.

## 5. Update the secrets bundle

Rebuild the bundle from the live control plane config, then confirm that only the `os` and `etcd`
CAs changed.

```shell
REPO=~/src/homelab        # wherever your checkout is
livemc 10.11.0.10 > cp-current.yaml
talosctl gen secrets --from-controlplane-config cp-current.yaml -o secrets.new.yaml
age -d $REPO/k8s/talos/prod/talos-prod-secrets.yaml.age > secrets.old.yaml

for k in cluster.id cluster.secret secrets.bootstraptoken secrets.secretboxencryptionsecret \
         secrets.aescbcencryptionsecret trustdinfo.token certs.etcd.crt certs.etcd.key certs.k8s.crt \
         certs.k8s.key certs.k8saggregator.crt certs.k8saggregator.key certs.k8sserviceaccount.key \
         certs.os.crt certs.os.key; do
  [ "$(yq ".$k" secrets.old.yaml)" = "$(yq ".$k" secrets.new.yaml)" ] && s=same || s=CHANGED
  printf '%-36s %s\n' "$k" "$s"
done
yq '.certs.os.crt' secrets.new.yaml | b64fp      # matches ca-talos-new.txt
yq '.certs.etcd.crt' secrets.new.yaml | b64fp    # matches ca-etcd-new.txt
```

Expect `CHANGED` only for `certs.os.*` and `certs.etcd.*`. If anything else changed, stop and work
out why before committing.

Re-encrypt the bundle, using the passphrase from the password manager or a new one, and check the
round trip:

```shell
age -p -o $REPO/k8s/talos/prod/talos-prod-secrets.yaml.age secrets.new.yaml
age -d $REPO/k8s/talos/prod/talos-prod-secrets.yaml.age | cmp - secrets.new.yaml && echo round-trip ok
```

Commit it on a branch and open a PR. Merging changes nothing on the cluster. The old ciphertext
stays in git history, but after this rotation its Talos and etcd CA keys are dead.

**Other repo changes:**

- Nothing else in the repo pins the Talos or etcd CA.
- `dotfiles/kubeconfig` embeds the Kubernetes CA, which changes only if you rotate that too.

## 6. Clean up

Wait until step 5 is merged, then remove the working files and the old talosconfig:

```shell
rm -rf ~/talos-rotate ~/.talos/config.pre-rotate
```

The working directory held new CA keys, `etcd-pre.db` and the machine configs. SSDs and APFS don't
make shredding reliable, which is why the directory was private and left out of backups.

Old copies of the old keys elsewhere:

- **Volsync snapshots** of the `orca-home` volume keep 3 daily, 4 weekly, 10 monthly and 4 yearly
  copies. A snapshot from the week of the exposure can therefore be kept for years. After this
  rotation it only holds dead keys, so pruning is optional. To prune, run `restic forget <ids>
  --prune` against the repository in the `volsync-config--orca-home` Secret.
- **cluster-archiver archives** in S3 hold full machine configs, so archives from before the
  rotation contain the old CA keys. Don't restore a machine config from one of them, because it
  would roll the CAs back.
