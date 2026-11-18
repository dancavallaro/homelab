# k8s_gateway (dns-gateway)

Serves the private `*.o.cavnet.cloud` zone at 172.16.42.53. Deployed by the
`dns-gateway` Argo app (`k8s/infra/dns-gateway.yaml`).

Upstream publishes both the Helm chart and the image only on Codeberg, which
has had frequent outages (timeouts, and DNS for codeberg.org failing outright).
So nothing here pulls from Codeberg at runtime:

- `chart/` is the upstream chart, vendored unmodified. Argo renders it from
  this repo, with `values.yaml` layered on top.
- The image is copied once per version to
  `ghcr.io/dancavallaro/mirror/k8s_gateway`, and `values.yaml` pins it by
  upstream's digest.

Current versions: chart **3.7.3**, image **1.8.3**.

## Upgrading

Find the new chart version (and the `appVersion` it ships) at
<https://codeberg.org/k8s-gateway/-/packages>. Needs `helm`, `crane`
(`brew install crane`) and `gh`.

1. **Vendor the chart.** Replace `chart/` with the new version so the PR diff
   shows exactly what changed upstream:

   ```shell
   cd k8s/manifests/k8s_gateway
   rm -rf chart
   helm pull oci://codeberg.org/k8s-gateway/charts/k8s-gateway --version <CHART_VERSION> --untar --untardir .
   mv k8s-gateway chart
   grep appVersion chart/Chart.yaml
   ```

2. **Mirror the image.** `crane copy` copies the whole multi-arch index, so
   the digest on ghcr matches Codeberg's. Pushing needs a token with
   `write:packages`:

   ```shell
   gh auth refresh -s write:packages      # once
   gh auth token | crane auth login ghcr.io -u dancavallaro --password-stdin
   crane copy codeberg.org/k8s-gateway/k8s_gateway:<APP_VERSION> ghcr.io/dancavallaro/mirror/k8s_gateway:<APP_VERSION>
   crane digest codeberg.org/k8s-gateway/k8s_gateway:<APP_VERSION>
   crane digest ghcr.io/dancavallaro/mirror/k8s_gateway:<APP_VERSION>   # must match
   ```

   The first push creates the package as **private**. The cluster pulls
   anonymously, so make it public: GitHub → Packages →
   `mirror/k8s_gateway` → Package settings → Change visibility → Public. This
   setting persists for later versions.

3. **Bump `values.yaml`.** Set `image.tag` to `<APP_VERSION>@<digest>`.
   Check that an anonymous pull works before merging. Otherwise the new pod
   sits in ImagePullBackOff, and the old one keeps serving.

   ```shell
   docker logout ghcr.io; docker pull ghcr.io/dancavallaro/mirror/k8s_gateway:<APP_VERSION>
   ```

4. **Check the render** (optional) by comparing old and new, e.g.
   `helm template dns-gateway chart -n dns-gateway -f values.yaml`. The
   `checksum/config` annotation hashes all values, so it changes on any
   values edit. That's expected.

Using Claude for this: ask it to "upgrade k8s_gateway per
k8s/manifests/k8s_gateway/README.md". It can vendor the chart, look up
digests, and open the PR. The `crane copy` push and the visibility change
need your GitHub credentials, so you run those.
