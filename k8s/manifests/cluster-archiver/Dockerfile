FROM alpine:3

RUN apk add --no-cache bash jq yq curl aws-cli

RUN wget -O /usr/local/bin/talosctl \
        https://github.com/siderolabs/talos/releases/download/v1.9.5/talosctl-linux-amd64 && \
    chmod +x /usr/local/bin/talosctl

ADD backup.sh /cluster-archiver/backup.sh

ENTRYPOINT [ "/cluster-archiver/backup.sh" ]
