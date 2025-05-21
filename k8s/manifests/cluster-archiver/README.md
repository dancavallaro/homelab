## Build and push multi-platform image

```shell
docker buildx build --push \
    --platform linux/amd64,linux/arm64 \
    -t ghcr.io/dancavallaro/rpi-config/cluster-archiver:<VERSION> \
    k8s/manifests/cluster-archiver
```