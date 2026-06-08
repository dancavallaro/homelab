# oidc-provider — DIY IRSA for the cluster

Publishes the cluster's service-account token issuer publicly at
`https://oidc.cavnet.io` so AWS IAM can federate pod identities via
`sts:AssumeRoleWithWebIdentity` — the same mechanism EKS IRSA uses, without EKS.
A consuming pod gets a projected SA token and the AWS SDK exchanges it for
temporary role credentials, refreshing them automatically. No sidecar, no
per-app cert (contrast with `aws-iamra-manager`, which stays in place for ESO).

## What's here

- `oidc-provider.yaml` — nginx serving `/.well-known/openid-configuration`
  (static) and `/openid/v1/jwks` (cron-refreshed), the `Service`, and the
  `HTTPRoute` on the public gateway. The `*.cavnet.io` tunnel wildcard already
  routes here, so cloudflared is untouched.
- `jwks-refresh.yaml` — daily `CronJob` that re-snapshots the live JWKS into the
  `oidc-provider-jwks` ConfigMap, so a signing-key rotation needs no manual edit.
- `example-app.yaml` — fully commented template for a consuming workload.
- The ArgoCD app (`k8s/infra/oidc-provider.yaml`) sets `ignoreDifferences` on the
  JWKS ConfigMap so `selfHeal` doesn't fight the CronJob.

Both published documents are public by design — the JWKS holds only public keys.

## One-time setup

### 1. Deploy the serving plumbing (GitOps)

Commit this directory and `k8s/infra/oidc-provider.yaml`. After ArgoCD syncs,
confirm it's reachable from outside (served straight away — nothing validates
against it yet):

```shell
curl -s https://oidc.cavnet.io/.well-known/openid-configuration | jq
curl -s https://oidc.cavnet.io/openid/v1/jwks | jq
```

The discovery `issuer` must read `https://oidc.cavnet.io` exactly.

### 2. Switch the apiserver issuer (Talos) — maintenance window

The change lives in `k8s/talos/prod/patches/cp.patch.yaml` (`extraArgs`:
`service-account-issuer` + `service-account-jwks-uri`). It is **not** GitOps-applied;
push it with talosctl against the control-plane node:

```shell
talosctl -n <CP_NODE_IP> patch mc -p @k8s/talos/prod/patches/cp.patch.yaml
```

Caveats (see the inline comment in the patch):
- Talos v1.9 replaces (can't append) the issuer, so existing SA tokens with the
  old `iss` are rejected until they refresh — a few-minute self-healing blip.
- Single control-plane node ⇒ a brief apiserver restart.
- Optionally pin `api-audiences` to the current issuer first to narrow the blast
  radius (commented in the patch).

Verify afterward:

```shell
kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer, .jwks_uri'
# -> https://oidc.cavnet.io  /  https://oidc.cavnet.io/openid/v1/jwks
```

### 3. Register the OIDC provider in AWS (account 484396241422)

```shell
aws iam create-open-id-connect-provider \
  --url https://oidc.cavnet.io \
  --client-id-list sts.amazonaws.com
```

The endpoint is fronted by Cloudflare's publicly-trusted cert, so the thumbprint
AWS records is a non-functional formality — the CLI fetches one for you.

## Per-app: grant a workload a role

1. **IAM role + trust policy**, pinned to one namespace/serviceaccount:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::484396241422:oidc-provider/oidc.cavnet.io" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": { "StringEquals": {
         "oidc.cavnet.io:aud": "sts.amazonaws.com",
         "oidc.cavnet.io:sub": "system:serviceaccount:<namespace>:<serviceaccount>"
       }}
     }]
   }
   ```

   Attach the task-specific permissions policy to the same role.

2. **Wire the pod** — copy the projected-token volume + `AWS_ROLE_ARN` /
   `AWS_WEB_IDENTITY_TOKEN_FILE` env from `example-app.yaml`. The AWS SDK does the
   rest, including refresh.

3. **Verify** from inside the pod: `aws sts get-caller-identity` should return the
   assumed-role ARN.

## Key rotation

Nothing to do. The `jwks-refresh` CronJob republishes the JWKS daily, and
Kubernetes serves old + new keys during the rotation overlap, so tokens keep
verifying with no downtime. To force an immediate refresh:

```shell
kubectl -n oidc-provider create job --from=cronjob/jwks-refresh jwks-refresh-now
```
