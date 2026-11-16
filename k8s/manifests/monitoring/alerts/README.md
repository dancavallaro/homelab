### Where rules live

Alerts about one app live next to that app, in an `alerts.yaml` `PrometheusRule` in its
manifest directory (for example `home-assistant/`, `nut-exporter/`, `volsync/`). This directory
holds the rest: cluster-wide alerts (`kubernetes.yaml`, including Argo CD, which isn't deployed
from this repo) and alerts about hosts outside the cluster (`hosts.yaml`).

### Deploying rules

Argo CD applies each `PrometheusRule` with its app, and the `mimir.rules.kubernetes`
component in the `alloy` Deployment (`conf/alloy/rules.alloy`) loads every `PrometheusRule` in
the cluster into the Mimir ruler. Rule namespaces in Mimir are named
`alloy/<k8s namespace>/<name>/<uid>`; Alloy creates, updates and deletes only namespaces with that
shape.

Alloy syncs a rule shortly after its resource changes, and re-checks Mimir every 5 minutes.

### List rule groups

```shell
mimirtool rules list --address=http://mimir.o.cavnet.cloud --id 1
```

### Get rules

```shell
mimirtool rules print --address=http://mimir.o.cavnet.cloud --id 1
```

`mimirtool` requires `--id`, but Mimir runs with multitenancy disabled and ignores the value.
