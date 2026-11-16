### Deploying rules

Each file here is a `PrometheusRule`. Argo CD applies them, and the `mimir.rules.kubernetes`
component in the `alloy` Deployment (`conf/alloy/rules.alloy`) loads every `PrometheusRule` in
the cluster into the Mimir ruler. Rule namespaces in Mimir are named
`alloy/<k8s namespace>/<name>/<uid>`; Alloy creates, updates and deletes only namespaces with that
shape.

Alloy syncs a rule shortly after its resource changes, and re-checks Mimir every 5 minutes.

### List rule groups

```shell
mimirtool rules list --address=http://mimir.o.cavnet.cloud
```

### Get rules

```shell
mimirtool rules print --address=http://mimir.o.cavnet.cloud
```
