### Load rules

```shell
mimirtool rules load --address=http://mimir.o.cavnet.cloud --id 1 manifests/monitoring/alerts/mimir.yaml
```

### List rule groups

```shell
mimirtool rules list --address=http://mimir.o.cavnet.cloud --id 1
```

### Get rules

```shell
mimirtool rules get --address=http://mimir.o.cavnet.cloud --id 1 kubernetes alerts
```