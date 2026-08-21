#!/usr/bin/env bash
set -eu

VOLUME_PATH=/var/mnt/data/local-path-provisioner

timestamp=$(date -u -Iseconds | sed 's/+.*$//' | sed 's/[-:]//g')
workdir_root=$(mktemp -d)
workdir="${workdir_root}/$timestamp"

MEMBERS_JSON=$(talosctl -n "$NODE_IP" get members -o json)
CP_IP=$(echo "$MEMBERS_JSON" | jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' | head -n1)

# Export machine configs, named by node hostname (addresses[0] is an unstable
# choice on multi-homed nodes)
mkdir -p "$workdir/machineconfig"
echo "$MEMBERS_JSON" | jq -r '[.spec.addresses[0], .spec.hostname] | @tsv' |
while IFS=$'\t' read -r node name; do
    talosctl -n "$node" get mc v1alpha1 -o yaml | yq eval '.spec' - > "$workdir/machineconfig/$name.yaml"
done

# Take snapshot of etcd database
talosctl -n "$CP_IP" etcd snapshot "$workdir/etcd.snapshot.db"

tar czvf "${workdir_root}/$timestamp.tar.gz" -C "$workdir_root" "$timestamp"

echo "$workdir_root"
aws s3 cp "${workdir_root}/$timestamp.tar.gz" "s3://nuc-talos-backups/cluster/$timestamp.tar.gz"
