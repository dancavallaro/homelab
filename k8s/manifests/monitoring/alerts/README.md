### Load rules

```shell
mimirtool rules load --address=http://172.16.42.2 --id 1 manifests/monitoring/alerts/mimir.yaml
```

### List rule groups

```shell
mimirtool rules list --address=http://172.16.42.2 --id 1
```

### Get rules

```shell
mimirtool rules get --address=http://172.16.42.2 --id 1 kubernetes alerts
```