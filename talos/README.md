## Bare metal host setup

### Set up bridge

Edit `/etc/netplan/50-cloud-init.yaml` to disable DHCP on enp89s0:

```yaml
network:
    ethernets:
        enp89s0:
            dhcp4: false
    version: 2
    wifis: {}
```

Then (NOTE: this will kill SSH): `sudo netplan apply`

Then:

```shell
sudo ip link add br0 addr 92:B9:36:6D:7F:97 type bridge
sudo ip link set br0 up
# This will kill your SSH connection dummy
sudo ip link set enp89s0 master br0
sudo dhclient br0
```

## Talos cluster setup

### libvirt network

```shell
virsh net-define talos-net.xml --validate
virsh net-start talos-net
virsh net-autostart talos-net
```

### Set up CP nodes

```shell
virt-install --name talos-cp1 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:C0:77:B4:28:80 --network bridge=br0,mac=02:7F:50:1E:B0:55

export BOOTSTRAP_IP=10.42.42.100

talosctl gen config nuc-talos https://$BOOTSTRAP_IP:6443
talosctl machineconfig patch controlplane.yaml --patch @controlplane.patch.yaml -o controlplane.yaml
talosctl config merge ./talosconfig
talosctl config endpoint cavnet.cloud

talosctl apply-config --insecure -n 192.168.100.10 --file controlplane.yaml

talosctl bootstrap -n $BOOTSTRAP_IP
talosctl kubeconfig -n $BOOTSTRAP_IP
```

### Set up worker nodes

```shell
virt-install --name talos-worker1 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:52:A7:0B:1D:89

talosctl machineconfig patch worker.yaml --patch @worker.patch.yaml -o worker.yaml
talosctl apply-config --insecure -n 192.168.100.100 --file worker.yaml
```

---

## Note on Tailscale + routing

```shell
# These routes are necessary on dpu-host in order for it to route Tailscale traffic
# properly (the bastion doesn't need these routes to route traffic through the Mikrotik).
sudo ip r add 172.16.42.0/24 via 10.42.42.100
sudo ip r add 10.96.0.0/12 via 10.42.42.100
```

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

## Setting up AWS IAM Roles Anywhere

### Using Kubernetes cluster CA

Extracted the k8s cluster CA certificate to use as the IAM RA trust anchor:

```shell
kubectl config view \
    -o jsonpath='{.clusters[].cluster.certificate-authority-data}' \
    --raw --minify --flatten | base64 -d > k8s.pem
```

### Set up IAM RA

Upload k8s.pem as an IAM RA Trust Anchor.

Add this policy to the trust relationship of roles I want to use:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Service": "rolesanywhere.amazonaws.com"
  },
  "Action": [
    "sts:AssumeRole",
    "sts:TagSession",
    "sts:SetSourceIdentity"
  ],
  "Condition": {
    "ArnEquals": {
      "aws:SourceArn": "arn:aws:rolesanywhere:us-east-1:484396241422:trust-anchor/1acbff48-4cbe-4593-9fea-caf869c51b1a"
    }
  }
}
```

Then create one `nuc-talos-k8s-iamra` policy and associate all roles that I want to use from
k8s cluster, and use default policy. I'll use conditions in the per-role trust relationship
policies to enforce access controls for per-service k8s certificate identities. 

TODO: need to add additional conditions to enforce authorized principles for each role

### Issuing certs from cluster CA

```shell
openssl genrsa -out iam-ra-test.key 2048

cat > csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
encrypt_key = yes
default_md = sha256
distinguished_name = kube-apiserver-client
req_extensions = v3_req
[ kube-apiserver-client ]
CN = iam-ra-test.default.pod.cluster.local
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = iam-ra-test.default.pod
EOF

openssl req -new -key iam-ra-test.key -out iam-ra-test.csr -config csr.conf

cat > csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
   name: iam-ra-test
spec:
   signerName: kubernetes.io/kube-apiserver-client
   expirationSeconds: 8640000
   request: $(cat iam-ra-test.csr|base64|tr -d '\n')
   usages:
   - digital signature
   - key encipherment
   - client auth
EOF

kubectl create -f csr.yaml

kubectl certificate approve iam-ra-test

kubectl get csr iam-ra-test

kubectl get csr iam-ra-test \
    -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out iam-ra-test.crt
    
openssl storeutl -text -noout -certs iam-ra-test.crt
```

### Issuing certs using cert-manager and self-signed CA

Get the self-signed CA cert and upload that as the trust anchor:

```shell
kubectl -n cert-manager get secret self-signed-issuer-ca -o jsonpath='{.data}' | jq -r '.["tls.crt"]' | base64 -d
```

Issuing a test cert:

```shell
kubectl get secret kuard-tls -o jsonpath='{.data}' | jq -r '.["tls.crt"]' | base64 -d > kuard.crt
kubectl get secret kuard-tls -o jsonpath='{.data}' | jq -r '.["tls.key"]' | base64 -d > kuard.key
openssl storeutl -text -noout -certs kuard.crt
```

### Use k8s cert to get AWS creds

```shell
aws_signing_helper credential-process --region us-east-1 \
    --certificate kuard.crt --private-key kuard.key \
    --trust-anchor-arn arn:aws:rolesanywhere:us-east-1:484396241422:trust-anchor/1acbff48-4cbe-4593-9fea-caf869c51b1a \
    --profile-arn arn:aws:rolesanywhere:us-east-1:484396241422:profile/cf0dca44-1d61-41d5-9963-50f3477b8b02 \
    --role-arn arn:aws:iam::484396241422:role/S3BackupsRole
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

## Cluster backups

### Machine config

```shell
for node in 192.168.100.10 192.168.100.100 192.168.100.101; do 
    talosctl get -n $node mc v1alpha1 -o yaml | yq eval '.spec' - > $node.yaml
done
```

### etcd database

```shell
talosctl etcd snapshot ./etcd.snapshot.db
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
