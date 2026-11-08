# Orca server

Headless [Orca](https://www.onorca.dev/docs/remote-servers) for the laptop and phone apps, reached at
`orca.o.cavnet.cloud:6768` over the Tailnet's existing subnet routes. Written against Orca 1.4.253.

- Replacing the pod ends every running terminal and agent. Projects, pairings and logins stay on the
  volume. An orcad crash alone keeps terminals, because `--supervise` restarts it in place.
- Sessions push as a GitHub App that a ruleset keeps off `main`, so they open PRs for review.
  Egress is limited to DNS, the internet, the API server and Grafana.
- `kubectl` reads the cluster as the `orca` ServiceAccount, bound to `view` and
  `orca-cluster-reader` (`rbac.yaml`): no Secrets, exec, port-forward or proxy. Its token is
  projected, lasts an hour and dies with the pod. To cut access at once, turn off auto-sync for
  `orca` and `all-apps` in ArgoCD, delete both `orca-*` ClusterRoleBindings and delete the pod.
- Grafana logs sessions in as Viewer from a second projected token (audience `grafana`, one hour),
  through its `[auth.jwt]` settings, which accept only this ServiceAccount. To cut access, set
  `[auth.jwt] enabled = false` or disable the `system:serviceaccount:orca:orca` user in Grafana.
- The App's private key lives in KMS. For each GitHub token, `github-app-token` fetches a Defakto JWT
  SVID, assumes an AWS role with it, signs the App JWT with `kms:Sign`, and exchanges that.

## Build and push

`VERSION` must match the image tag in `orca.yaml`. To upgrade Orca, change its version and checksum in
the `Dockerfile` and bump both. Clients refuse a server with an incompatible protocol version.

```shell
docker buildx build --push \
    --platform linux/amd64 \
    -t ghcr.io/dancavallaro/homelab/orca:$(cat k8s/manifests/orca/VERSION) \
    k8s/manifests/orca
```

Make the package public in its GitHub settings if the cluster can't pull it.

## First-time setup

### GitHub App

[Create a GitHub App](https://github.com/settings/apps/new) named `orca-homelab`, with the webhook off
and only Contents and Pull requests set to read and write. Leave Workflows unset. Generate a private
key, then install the App on `homelab` only. The name also appears in the `Dockerfile`'s git identity.

Put the App ID, from its settings page, and the installation ID, the number at the end of the
installation's URL, in `orca.yaml`. Neither is secret.

### AWS

`setup-aws.sh` imports the key and verifies the import, and the `iam` step needs IAM write access. The
role trusts only `spiffe://prod.cavallaro.local/talos-prod/ns/orca/sa/orca`. KMS can't replace imported
material with a different key, so rotating the App key means a new KMS key and repointing the alias.

```shell
k8s/manifests/orca/setup-aws.sh kms KEY.pem
rm KEY.pem
k8s/manifests/orca/setup-aws.sh iam
```

### Ruleset

Block everyone but repository admins from updating `main`, then check that the last command prints
`always`:

```shell
echo '{"name":"main: admins only","target":"branch","enforcement":"active",
  "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],
  "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
  "rules":[{"type":"update"},{"type":"non_fast_forward"},{"type":"deletion"}]}' \
  | gh api -X POST repos/dancavallaro/homelab/rulesets --input -
gh repo edit dancavallaro/homelab --delete-branch-on-merge
gh api repos/dancavallaro/homelab/rulesets --jq '.[0].id' \
  | xargs -I{} gh api repos/dancavallaro/homelab/rulesets/{} --jq .current_user_can_bypass
```

### Pair clients

The `--supervise --no-pairing` server prints no link, and links shouldn't reach Loki, so the entrypoint
has a one-shot mode that writes the link to `~/pairing.txt`. It restarts the pod, so pair before
starting work. Update the laptop's Orca first.

```shell
kubectl -n orca exec deploy/orca -- sh -c 'touch ~/.pair-next-start'
kubectl -n orca delete pod -l app=orca
kubectl -n orca wait --for=condition=Ready pod -l app=orca --timeout=5m
kubectl -n orca exec deploy/orca -- sh -c 'grep "^Pairing URL" ~/pairing.txt'
```

Paste the link into **Settings → Remote Orca Servers → Add Server**. For the phone, repeat with
`echo mobile > ~/.pair-next-start`, and read the whole of `~/pairing.txt` for its QR code. Then delete
the pod once more to return to normal mode, which also removes `pairing.txt`.

### Log in and clone

```shell
kubectl -n orca exec -it deploy/orca -- orca-ide account add --agent claude
kubectl -n orca exec deploy/orca -- sh -c \
    'git clone https://github.com/dancavallaro/homelab ~/workspaces/homelab'
```

Add `~/workspaces/homelab` as a project in the app, connected to this server.

## Verify the restrictions

Each deny is paired with an allow to the same kind of target, because a dead network or a broken
credential would produce the same denial.

```shell
kubectl -n orca exec -it deploy/orca -- bash
```

```shell
github-app-token >/dev/null && echo minted

cd ~/workspaces/homelab
git commit --allow-empty -m 'Test push rules'
git push origin HEAD:refs/heads/orca-push-test  # succeeds
git push origin HEAD:main                       # rejected by the ruleset
git push origin --delete orca-push-test
git reset --hard origin/main

curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://github.com  # 200
curl -sS -m 5 https://172.16.42.3                                  # times out
curl -sS -m 5 http://10.42.42.1                                    # times out

kubectl get nodes,pv,storageclasses                    # lists them
kubectl get applications.argoproj.io -A                # lists them
kubectl -n argocd logs deploy/argocd-server --tail=1   # prints a line
kubectl auth can-i get secrets -A                      # no
kubectl get secrets -A                                 # Forbidden
kubectl auth can-i create pods/exec -A                 # no
kubectl auth can-i get nodes/proxy                     # no
kubectl -n orca delete pod -l app=orca --dry-run=server  # Forbidden
curl -sS -m 5 -k https://10.11.0.10:50000              # times out

g() { curl -sS -m 10 -H "X-JWT-Assertion: $(cat "$GRAFANA_TOKEN_FILE")" "$GRAFANA_URL$@"; }
g /api/user | jq '.login, .orgRole' -r                 # system:serviceaccount:orca:orca, Viewer
loki=$(g /api/frontend/settings | jq -r '.datasources.Loki.uid')
g /api/ds/query -H 'Content-Type: application/json' -d '{"from":"now-5m","to":"now","queries":
  [{"refId":"A","datasource":{"uid":"'$loki'"},"expr":"{namespace=\"orca\"}","queryType":"range"}]}' \
  | jq '.results.A.status'                             # 200
g /api/datasources/proxy/uid/$loki/loki/api/v1/delete -X POST -o /dev/null -w '%{http_code}\n' \
  -G --data-urlencode 'query={namespace="orca-test"}' -d start=0   # 403, never 204
g /api/dashboards/db -X POST -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}\n' \
  -d '{"dashboard":{"title":"orca-write-test"}}'      # 403
curl -sS -m 5 http://loki-http.monitoring/ready        # times out
```
