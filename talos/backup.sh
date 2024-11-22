#!/usr/bin/env bash
set -eu

timestamp=$(date -u -Iseconds | sed 's/+.*$//' | sed 's/[-:]//g')
workdir_root=$(mktemp -d)
workdir="${workdir_root}/$timestamp"
mkdir -p "$workdir/machineconfig"

# Export machine configs
for node in 192.168.100.10 192.168.100.100 192.168.100.101; do
    talosctl get -n $node mc v1alpha1 -o yaml | yq eval '.spec' - > "$workdir/machineconfig/$node.yaml"
done

# Take snapshot of etcd database
talosctl etcd snapshot "$workdir/etcd.snapshot.db" > /dev/null

# Copy talosctl config
cp ~/.talos/config "$workdir/talos.config"

tar czvf "${workdir_root}/$timestamp.tar.gz" -C "$workdir_root" "$timestamp" 2> /dev/null

aws s3 cp "${workdir_root}/$timestamp.tar.gz" "s3://nuc-talos-backups/cluster/$timestamp.tar.gz"

rm -rf "$workdir_root"
