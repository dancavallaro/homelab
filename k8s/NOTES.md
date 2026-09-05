## Note on DNS delegation

Delegation of the k.cavnet.cloud zone from Route 53 to my private k8s_gateway nameserver
at 172.16.42.53 doesn't work when using a typical public recursive resolver (e.g. ISP),
even if the client is on the private network -- it only works when using a recursive
resolver with access to the private nameserver. For now I'm just relying on Tailscale's
DNS delegation since all of my clients are running Tailscale anyway, but if I ever want
this to work for non-Tailscale clients on the LAN (e.g. open it to the home network)
I'll need to run a recursive resolver and vend that via DHCP (Mikrotik's built-in "resolver"
only forwards and caches, it doesn't do recursion itself, so the queries will still fail
when a public resolver tries to reach the k.cavnet.cloud zone).

After that, I'd left the k.cavnet.cloud DNS record in Route54 since it seemed harmless
and at some point I want to get this working with non-Tailscale clients on the LAN.
But it was a problem for the LetsEncrypt validation, since it was trying to query the
private nameserver. So I deleted the NS record, and I actually don't think I'll need
it again. When I set up a private recursive resolver I won't need any actual delegation
from Route53, I can just return whatever I want from the resolver.

## TLS certs w/ LetsEncrypt and certbot

certbot-dns-updater-role with certbot-dns-updater-policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZones",
                "route53:GetChange"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/Z05015042OJX42009787V"
            ]
        }
    ]
}
```

```shell
aws sts assume-role --role-arn arn:aws:iam::484396241422:role/certbot-dns-updater-role --role-session-name certbot-cert-request

// TODO: try running this with --manual?
docker run -it --rm --name certbot \
    -v "/etc/letsencrypt:/etc/letsencrypt" \
    -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
    -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
    -e "AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN" \
    certbot/dns-route53 certonly --preferred-challenges dns

sudo openssl storeutl -noout -text -certs /etc/letsencrypt/live/o.cavnet.cloud/cert.pem

sudo kubectl create secret tls o.cavnet-wildcard-cert \
    --cert /etc/letsencrypt/live/o.cavnet.cloud/fullchain.pem \
    --key /etc/letsencrypt/live/o.cavnet.cloud/privkey.pem
```

## Multi-homing with homenet

On the Mikrotik I created a new VLAN interface on the port connected to dpu-host, tagged
with VLAN 192, and bridged to dtcnet. Then on dpu-host, I create a tagged interface:

```shell
sudo ip link add link br0 name dtcnet0 type vlan id 192
sudo ip link set dtcnet0 up
sudo dhclient dtcnet0
```

```shell
$ ip a show dev dtcnet0
206: dtcnet0@br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.6.9/22 brd 192.168.7.255 scope global dynamic dtcnet0
```

NOTE: This interface isn't actually necessary! The Talos worker has its own VLAN 
interface, and this one winds up having no use in the end.

### Set up dtcnet worker node

```shell
virt-install --name talos-worker2 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=de:6f:9f:0d:15:96 --network bridge=br0,mac=1e:03:e4:b3:4f:47

talosctl machineconfig patch worker.yaml --patch @worker2.patch.yaml -o worker2.yaml
talosctl apply-config --insecure -n 192.168.100.101 --file worker2.yaml

# Needs to be added manually
kubectl taint nodes talos-worker2 dtcnet:NoSchedule
```

Here's what the label and taint look like:

```shell
dan@dpu-host:~/rpi-config/talos$ kubectl get node talos-worker2 --show-labels
NAME            STATUS   ROLES    AGE   VERSION   LABELS
talos-worker2   Ready    <none>   25m   v1.30.3   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=talos-worker2,kubernetes.io/os=linux,network=dtcnet

dan@dpu-host:~/rpi-config/talos$ kubectl get nodes -o json | jq '.items[] | select(.metadata.name == "talos-worker2") | .spec.taints'
[
  {
    "effect": "NoSchedule",
    "key": "dtcnet",
  }
]
```

To see what's running on the node:

```shell
dan@dpu-host:~/rpi-config/talos$ kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=talos-worker2
NAMESPACE     NAME                 READY   STATUS    RESTARTS      AGE   IP              NODE            NOMINATED NODE   READINESS GATES
kube-system   kube-flannel-gq55j   1/1     Running   1 (14m ago)   27m   192.168.6.100   talos-worker2   <none>           <none>
kube-system   kube-proxy-68jqc     1/1     Running   0             14m   192.168.6.100   talos-worker2   <none>           <none>
```

### Running on host network on dtcnet 

First, need to allow pods to run with host networking:

```shell
kubectl label ns default pod-security.kubernetes.io/enforce=privileged
```

Then, run a pod with host networking, the dtcnet node selector, and toleration:

```yaml
  hostNetwork: true
  nodeSelector:
    network: dtcnet
  tolerations:
    - key: dtcnet
      operator: Exists
      effect: NoSchedule
```

## Upgrading Talos

### Worker nodes

```shell
for node in 192.168.100.100 192.168.100.101; do
    talosctl upgrade -n $node \
      --image ghcr.io/siderolabs/installer:v1.8.0
done
```

### Control plane nodes

NOTE: Make sure to upgrade CP node with --preserve=true, while I only have one CP node.

```shell
talosctl upgrade --preserve=true -n 192.168.100.10 \
    --image ghcr.io/siderolabs/installer:v1.8.0
```

## Bluetooth

Getting the NUC's Bluetooth adapter working on Kubernetes in the Talos VM was a two-step
process. Making this Bluetooth adapter available inside a VM was relatively straightforward
once I found this excellent comment: https://github.com/home-assistant/operating-system/issues/2611#issuecomment-2081271327.
By passing through both the PCI device and the USB Bluetooth device, I was able to see
and access the Bluetooth adapter from within an Ubuntu VM. These steps are documented in
talos/prod/README.md.

Getting it to work in a *Talos* VM was trickier because Talos's kernel is compiled without
BT support (confirmed in https://github.com/siderolabs/pkgs/issues/486). There's an open
request for a Talos System Extension for BT support (https://github.com/siderolabs/extensions/issues/247),
but in the meantime the solution is to just build the kernel with BT-related modules.

I originally got this working with the built-in AX201, but after a reboot it stopped working
and I never got it working again. I switched to a TP-Link UB500, and that's working after
building in the Realtek firmware system extension image which has the necessary firmware.

### Building Talos with Bluetooth support

1. Start container registry if not one already:
   ```
   docker run -d -p 5005:5000 --restart always --name local registry:2
   ```
2. **Kernel config** (`pkgs` → `kernel/build/config-amd64`): replace the single `# CONFIG_BT is not set`
   line with the full BT block from the [BT config + module reference](#bt-config--module-reference)
   below, then canonicalize:
   ```
   make kernel-olddefconfig PLATFORM=linux/amd64      # pkgs target: runs olddefconfig inside the
                                                      # kernel build container, writes config-amd64 back
   git diff kernel/build/config-amd64                 # confirm CONFIG_BT_HCIBTUSB=m and CONFIG_BT_RTL=m
   ```
   Note it's `kernel-olddefconfig`, **not** bare `make olddefconfig` (not a target here). Setting only
   `CONFIG_BT=m` is **not** enough — the HCI USB / Realtek drivers default to off and `olddefconfig`
   won't enable them, so you'd build only `bluetooth.ko` core with no adapter. (`make kernel-menuconfig`
   gives the interactive editor as an alternative.)
3. Build kernel image: 
   ```
   time make kernel REGISTRY=127.0.0.1:5005 PUSH=true PLATFORM=linux/amd64
   ```
4. **Modules** (`talos` → `hack/modules-amd64.txt`): prepend the BT module lines from the
   [reference](#bt-config--module-reference) below. This only controls which built modules get copied
   into the initramfs — the kernel builds all ~25 BT modules regardless. **Gate before the imager:**
   the modules live in the kernel image from step 3 (a near-scratch image with no shell, so export its
   filesystem rather than `docker run`) — confirm at least `btusb`/`btrtl`/`bluetooth` are present. If
   they're missing, the `CONFIG_BT` edit didn't take; fix and rebuild the kernel before going further.
   ```
   KIMG=127.0.0.1:5005/siderolabs/kernel:<TAG>        # same ref you pass as PKG_KERNEL in step 5
   docker create --name ktmp "$KIMG" true >/dev/null  # dummy cmd; never runs, just lets us export
   docker export ktmp | tar -tf - | grep -iE 'bluetooth|drivers/bluetooth/bt|bnep' | sort
   docker rm ktmp >/dev/null
   ```
5. Build kernel and initramfs:
   ```
   time make kernel initramfs PKG_KERNEL=127.0.0.1:5005/siderolabs/kernel:<TAG> PLATFORM=linux/amd64
   ```
6. Build imager image:
   ```
   time make imager PKG_KERNEL=127.0.0.1:5005/siderolabs/kernel:<TAG> PLATFORM=linux/amd64 INSTALLER_ARCH=targetarch PUSH=true REGISTRY=127.0.0.1:5005
   ```
7. May need to explicitly pull imager image if it's been updated: `docker pull 127.0.0.1:5005/siderolabs/imager:<TAG>`
8. Build ISO:
   ```
   docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> iso \
       --system-extension-image ghcr.io/siderolabs/realtek-firmware:20250211@sha256:6c22784b86d781eba07a4025b9dfb4ae5679e05e3577d54c6c4283ba5dd7cec5 \
       --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.1.6@sha256:8ad7cd682f06198a6df7906d439939cc3f5feaa8a32f38ab2563268a17862baa
   ```
9. Build installer image:
   ```
   docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> installer \
       --base-installer-image ghcr.io/siderolabs/installer:v1.9.5 \
       --system-extension-image ghcr.io/siderolabs/realtek-firmware:20250211@sha256:6c22784b86d781eba07a4025b9dfb4ae5679e05e3577d54c6c4283ba5dd7cec5 \
       --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.1.6@sha256:8ad7cd682f06198a6df7906d439939cc3f5feaa8a32f38ab2563268a17862baa
   ```

#### BT config + module reference

Recovered ground truth for steps 2 and 4 — these lived only on the old build host and the
`dancavallaro/talos` `v1.9.5` fork branch, so they're pinned here to survive.

**Kernel config** — paste this whole block over the `# CONFIG_BT is not set` line in `config-amd64`,
then run `make kernel-olddefconfig PLATFORM=linux/amd64` to canonicalize (it keeps these explicit
values and fills in any new-kernel symbols). This is the BT section taken from a running node
(`talosctl -n <ip> read /proc/config.gz | gunzip`); a newer kernel may add a symbol (e.g.
`CONFIG_BT_INTEL_PCIE`), which is fine — the point is that BT **and the HCI USB / RTL drivers** are on
(not just `CONFIG_BT=m`, which alone builds only the core):

```
CONFIG_BT=m
CONFIG_BT_BREDR=y
CONFIG_BT_RFCOMM=m
CONFIG_BT_RFCOMM_TTY=y
CONFIG_BT_BNEP=m
CONFIG_BT_BNEP_MC_FILTER=y
CONFIG_BT_BNEP_PROTO_FILTER=y
CONFIG_BT_HIDP=m
CONFIG_BT_LE=y
CONFIG_BT_LE_L2CAP_ECRED=y
CONFIG_BT_LEDS=y
CONFIG_BT_MSFTEXT=y
CONFIG_BT_AOSPEXT=y
CONFIG_BT_DEBUGFS=y
# CONFIG_BT_SELFTEST is not set
# CONFIG_BT_FEATURE_DEBUG is not set
#
# Bluetooth device drivers
#
CONFIG_BT_INTEL=m
CONFIG_BT_BCM=m
CONFIG_BT_RTL=m
CONFIG_BT_MTK=m
CONFIG_BT_HCIBTUSB=m
CONFIG_BT_HCIBTUSB_AUTOSUSPEND=y
CONFIG_BT_HCIBTUSB_POLL_SYNC=y
CONFIG_BT_HCIBTUSB_BCM=y
CONFIG_BT_HCIBTUSB_MTK=y
CONFIG_BT_HCIBTUSB_RTL=y
CONFIG_BT_HCIBTSDIO=m
CONFIG_BT_HCIUART=m
CONFIG_BT_HCIUART_H4=y
CONFIG_BT_HCIUART_BCSP=y
CONFIG_BT_HCIUART_ATH3K=y
CONFIG_BT_HCIUART_AG6XX=y
CONFIG_BT_HCIBCM203X=m
# CONFIG_BT_HCIBCM4377 is not set
CONFIG_BT_HCIBPA10X=m
CONFIG_BT_HCIBFUSB=m
CONFIG_BT_HCIVHCI=m
CONFIG_BT_MRVL=m
CONFIG_BT_MRVL_SDIO=m
CONFIG_BT_ATH3K=m
CONFIG_BT_MTKSDIO=m
CONFIG_BT_VIRTIO=m
# CONFIG_BT_INTEL_PCIE is not set
```

**Modules** — prepend to `hack/modules-amd64.txt`:

```
kernel/net/bluetooth/bluetooth.ko
kernel/net/bluetooth/bnep/bnep.ko
kernel/drivers/bluetooth/btusb.ko
kernel/drivers/bluetooth/btintel.ko
kernel/drivers/bluetooth/btbcm.ko
kernel/drivers/bluetooth/btrtl.ko
kernel/drivers/bluetooth/btmtk.ko
```

For the UB500 (Realtek RTL8761BU) only `bluetooth` + `btusb` + `btrtl` are functionally needed, but as
built `btusb` links `btintel` (force-`select`ed by `CONFIG_BT_HCIBTUSB`), `btbcm`, and `btmtk` at load
time — so those six ship and load together (confirmed via `/proc/modules` on worker2). `bnep`
(PAN/tethering) never loads and is the one line safe to drop; don't drop the others without a matching
config change or `btusb` fails with unresolved symbols.

To upgrade a node:

```shell
talosctl upgrade -n <NODE IP> --image ghcr.io/dancavallaro/talos/installer:v1.9.5
```

### Build machine (temporary EC2 spot box)

**One-time IAM for SSM access** (avoids opening inbound SSH; Ubuntu's AMI ships the SSM agent). Needs
the Session Manager plugin locally (`brew install --cask session-manager-plugin`):

```bash
aws iam create-role --role-name talos-build-ssm \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name talos-build-ssm \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name talos-build-ssm
aws iam add-role-to-instance-profile --instance-profile-name talos-build-ssm --role-name talos-build-ssm

# This account encrypts SSM sessions with a customer-managed KMS key (SSM-SessionManagerRunShell
# -> kmsKeyId), so the instance role ALSO needs kms:Decrypt on that key, or the session handshake
# fails with "AccessDeniedException ... kms:Decrypt". Confirm the key id with
# `aws ssm get-document --name SSM-SessionManagerRunShell`.
aws iam put-role-policy --role-name talos-build-ssm \
  --policy-name ssm-session-kms-decrypt \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"kms:Decrypt","Resource":"arn:aws:kms:us-east-1:484396241422:key/4ed99242-e89c-4780-b289-b944a7915225"}]}'
```

**Launch** (resolve a fresh Ubuntu 24.04 amd64 AMI + a default subnet in the cheapest AZ first):

```bash
AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=availability-zone,Values=us-east-1d Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)

aws ec2 run-instances \
  --image-id "$AMI" --instance-type c7a.8xlarge --subnet-id "$SUBNET" \
  --iam-instance-profile Name=talos-build-ssm \
  --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}' \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=200,VolumeType=gp3,Throughput=250,DeleteOnTermination=true}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=talos-build},{Key=purpose,Value=throwaway}]' \
  --query 'Instances[0].InstanceId' --output text
```

`DeleteOnTermination=true` means the disk dies with the instance — no orphaned EBS. Connect and
become root:

```bash
aws ssm start-session --target <instance-id>
sudo -i
```

**Provision the box** — Docker with a buildx builder on the host network (so BuildKit can reach the
local registry at `127.0.0.1:5005`):

```bash
curl -fsSL https://get.docker.com | sh          # docker-ce + buildx + compose
apt-get update && apt-get install -y git make tmux
docker buildx create --name talos --driver docker-container --driver-opt network=host --use
docker run -d -p 5005:5000 --restart always --name local registry:2
export GHCR_PAT=<PAT with write:packages>
echo "$GHCR_PAT" | docker login ghcr.io -u dancavallaro --password-stdin
git clone https://github.com/siderolabs/pkgs.git
git clone https://github.com/siderolabs/talos.git
```

**Run builds inside tmux.** SSM sessions don't resume — if the session drops (network, laptop sleep,
the 20-min idle timeout in `SSM-SessionManagerRunShell`), a foreground `make` is SIGHUP'd and dies.
tmux keeps it alive server-side so you can reattach (this guards against *session* drops, not a spot
reclaim of the whole box — that takes tmux with it):

```bash
tmux new -s build                  # you're already root via sudo -i, so the tmux server is root's
export BUILDKIT_PROGRESS=plain     # line-by-line build output that scrolls and tees cleanly
make kernel … 2>&1 | tee ~/build.log   # keep a log to grep (e.g. for btusb.ko/btrtl.ko)
# detach any time: Ctrl-b then d
```

Reconnect after a drop — Run As lands you as `pi`, so become root, then reattach:

```bash
aws ssm start-session --target <instance-id>
sudo -i
tmux attach -t build               # build's been running the whole time
```

**Scrolling in tmux:** the wheel/arrows just print `^[[A`/`^[[B` escapes by default (tmux owns its own
scrollback). Either enter copy mode — `Ctrl-b [`, scroll with PageUp/PageDown/arrows, `q` to exit — or
enable the wheel with `Ctrl-b :` then `set -g mouse on` (persist it in `/root/.tmux.conf`).

Then run the build steps above once per version. Check out the matching release tag in **both**
repos and re-apply the two BT customizations each pass (keep them as a patch/branch so it's
mechanical): the `CONFIG_BT*` kernel-config change in `pkgs`, and the `hack/modules-amd64.txt`
additions in `talos`. Watch `df -h` — multiple kernel trees plus the registry eat disk. `time` each
`make` to see the per-version cost.

> **Scope for the current upgrade (Aug 2026):** build only **1.10 → 1.11 → 1.12** now — K8s 1.36
> (Talos 1.13.9) is deferred behind the Kyverno gate (see `k8s/talos/prod/UPGRADE.md`). Pin the 1.12
> build to a patch where [talos#12951] (iscsi-tools binaries moved off `/usr/local/sbin/`, breaking
> Synology CSI) is fixed — latest 1.12 is 1.12.11. Build 1.13.9 on a second short-lived box when 1.36
> unblocks.
>
> [talos#12951]: https://github.com/siderolabs/talos/issues/12951

**Tear down** when the pushed installers verify:

```bash
docker manifest inspect ghcr.io/dancavallaro/talos/installer:v1.12.11-bluetooth-iscsi   # from your Mac
aws ec2 terminate-instances --instance-ids <instance-id>   # EBS goes with it
```

## Loki

### Log volume analysis

See log stream size by service name in the last day:

```
sum by(service_name) (bytes_over_time({service_name=~".+"} [24h]))
```

(spoiler alert, it was Talos service logs)

Break it down by service and level:

```
sum by(talos_service, level) (bytes_over_time({service_name="talos.service_logs"} [24h]))
```

### Deleting logs

To find log streams using the HTTP API:

```shell
curl -s loki.o.cavnet.cloud/loki/api/v1/series \
  --data-urlencode 'match[]={service_name="kubernetes.pod_logs.hass"}' \
  --data-urlencode "start=$(orb date --date='2025-04-04T00:00:00Z' +%s%N)" \
  --data-urlencode "end=$(orb date --date='2025-05-20T00:00:00Z' +%s%N)"
```

Times must be in nanoseconds, and this API doesn't support line filters.

The delete API expects times in seconds, and supports line filters:

```shell
curl -X POST --get -s loki.o.cavnet.cloud/loki/api/v1/delete \
  --data-urlencode 'query={service_name="talos.service_logs", talos_service="machined"}' \
  --data-urlencode "start=$(orb date --date='2025-05-04T00:00:00Z' +%s)" \
  --data-urlencode "end=$(orb date --date='2025-05-08T00:00:00Z' +%s)"
```

To view requests:

```shell
curl -s loki.o.cavnet.cloud/loki/api/v1/delete | jq
```

To cancel an in-flight request:

```shell
curl -s -X DELETE "loki.o.cavnet.cloud/loki/api/v1/delete?request_id=<REQUEST_ID>&force=true"
```

## Use Pocket ID to get token to access k8s APIs from CLI

First get a token:

```shell
export CLIENT_SECRET="$(kubectl -n headlamp get secret headlamp-oidc -o jsonpath="{.data['client-secret']}" | base64 -d)"
export TOKEN="$(kubectl oidc-login get-token --oidc-issuer-url=https://pocket-id.o.cavnet.cloud --oidc-client-id=816acb21-3d87-470c-8d90-8c17ee9da65c --oidc-client-secret="$CLIENT_SECRET" --oidc-extra-scope=email,groups | jq -r .status.token)"
```

Then use the token to access an authenticated API:

```shell
curl -s -k -H "Authorization: Bearer $TOKEN" https://10.42.42.100:6443/metrics
```

## Resize libvirt disk image

To find the path to the image:

```shell
virsh domblklist <VM>
```

Then shut down the VM and run:

```shell
sudo qemu-img resize <IMAGE> +30G
```

## iSCSI troubleshooting

```shell
export ISCSI_ADDR=10.42.42.12
```

### List targets

```shell
sudo iscsiadm -m discovery -t sendtargets -p $ISCSI_ADDR
```

### Log in to target

```shell
sudo iscsiadm -m node --targetname=iqn.2000-01.com.synology:syn-ds923.pvc-174fe7f7-c60e-4341-83cf-6b09fddf2129 --portal $ISCSI_ADDR --login
```

### List logged-in targets and associated drives

```shell
ls -l /dev/disk/by-path | grep iscsi
```

### Log out of all targets

```shell
sudo iscsiadm -m node --logoutall=all
```
