#!/usr/bin/env sh

apk add --no-cache bash jq yq curl aws-cli

wget -O /usr/local/bin/talosctl \
    https://github.com/siderolabs/talos/releases/download/v1.9.5/talosctl-linux-amd64
chmod +x /usr/local/bin/talosctl
