#!/usr/bin/env bash
set -eu

VOLUME_PATH=/var/mnt/data/local-path-provisioner

timestamp=$(date -u -Iseconds | sed 's/+.*$//' | sed 's/[-:]//g')
workdir_root=$(mktemp -d)
workdir="${workdir_root}/$timestamp"

MEMBERS_JSON=$(talosctl -n "$NODE_IP" get members -o json)
ALL_IPS=$(echo "$MEMBERS_JSON" | jq -r '.spec.addresses[0]')
CP_IP=$(echo "$MEMBERS_JSON" | jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' | head -n1)
WORKER_IPS=$(echo "$MEMBERS_JSON" | jq -r 'select(.spec.machineType == "worker") | .spec.addresses[0]')

# Export machine configs
mkdir -p "$workdir/machineconfig"
for node in $ALL_IPS; do
    talosctl -n "$node" get mc v1alpha1 -o yaml | yq eval '.spec' - > "$workdir/machineconfig/$node.yaml"
done

# Take snapshot of etcd database
talosctl -n "$CP_IP" etcd snapshot "$workdir/etcd.snapshot.db"

# Take snapshots of local persistent volumes under /var/mnt/data/local-path-provisioner
mkdir -p "$workdir/local-volumes"
for node in $WORKER_IPS; do
    if ! talosctl -n "$node" ls "$VOLUME_PATH" > /dev/null ; then
        echo "Skipping $node as $VOLUME_PATH doesn't exist"
    else
        echo "Copying backup from $node"
        talosctl -n "$node" copy "$VOLUME_PATH" - > "$workdir/local-volumes/$node.tar.gz"
    fi
done

tar czvf "${workdir_root}/$timestamp.tar.gz" -C "$workdir_root" "$timestamp"

echo "$workdir_root"
aws s3 cp "${workdir_root}/$timestamp.tar.gz" "s3://nuc-talos-backups/cluster/$timestamp.tar.gz"
