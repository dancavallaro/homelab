### Building

```shell
docker build -t flicd:latest .
```

### Publishing

```shell
docker tag flicd:latest ghcr.io/dancavallaro/rpi-config/flicd:latest
docker push ghcr.io/dancavallaro/rpi-config/flicd:latest
```
