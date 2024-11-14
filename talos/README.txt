<network>
  <name>talos-net</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="virbr2" />
  <ip address="192.168.100.1" netmask="255.255.255.0">
    <dhcp>
      <host mac="02:C0:77:B4:28:80" ip="192.168.100.10" name="talos-cp1" />
      <host mac="02:52:A7:0B:1D:89" ip="192.168.100.100" name="talos-worker1" />
    </dhcp>
  </ip>
</network>

---

virsh net-define talos-net.xml --validate
virsh net-start talos-net
virsh net-autostart talos-net

====================================================================================

$ cat controlplane.patch.yaml
machine:
  certSANs:
    - cavnet.cloud
  install:
    disk: /dev/vda
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: '02:7f:50:1e:b0:55'
        # Configure this interface statically, since it gets a default route from DHCP that
        # conflicts with the default route on the private network.
        dhcp: false
        addresses:
          - 10.42.42.100/16
        routes:
          - network: 10.42.0.0/16
cluster:
  apiServer:
    certSANs:
      - cavnet.cloud
  controlPlane:
    endpoint: https://cavnet.cloud:6443

====================================================================================

virt-install --name talos-cp1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:C0:77:B4:28:80 --network bridge=br0,mac=02:7F:50:1E:B0:55

virsh console talos-cp1

export BOOTSTRAP_IP=10.42.42.100

talosctl gen config nuc-talos https://$BOOTSTRAP_IP:6443
talosctl machineconfig patch controlplane.yaml --patch @controlplane.patch.yaml -o controlplane.yaml
talosctl config merge ./talosconfig
talosctl config endpoint cavnet.cloud

talosctl apply-config --insecure -n 192.168.100.10 --file controlplane.yaml

talosctl bootstrap -n $BOOTSTRAP_IP
talosctl kubeconfig -n $BOOTSTRAP_IP

====================================================================================

$ cat worker.patch.yaml
machine:
  install:
    disk: /dev/vda
  disks:
    - device: /dev/vdb
      partitions:
        - mountpoint: /var/mnt/data

====================================================================================

virt-install --name talos-worker1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:52:A7:0B:1D:89

virsh console talos-worker1

talosctl machineconfig patch worker.yaml --patch @worker.patch.yaml -o worker.yaml
talosctl apply-config --insecure -n 192.168.100.100 --file worker.yaml
