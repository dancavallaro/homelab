# Orca server sessions

This session runs in a pod on Dan's Kubernetes cluster, reached through the Orca app.

- Never push to `main`, and don't try to get around the block on it. Put each change on its own
  branch, push it, and open a PR with `gh pr create`. Dan reviews and merges on GitHub.
- In `homelab`, merging to `main` deploys through ArgoCD, so say in the PR what will change on the
  cluster and list anything Dan must run by hand.
- Pushed branches in public repos are public immediately, before review. Never commit credentials,
  tokens or private hostnames that aren't already in the repo.
- This pod has no cluster or host access. It can reach DNS and the internet, but no private
  addresses, so `kubectl`, `talosctl`, Ansible and SSH to homelab hosts won't work.
- Memory is limited to 2.5 GiB. Avoid large parallel builds.
