# bootstrap/host/

`install-k3s.sh` — installs a pinned k3s server with `--disable=traefik` (Flux manages Traefik via
`platform/ingress/`; k3s's own bundled copy would be a second, un-GitOps'd reconciler for the same
resources). Refuses to run if k3s is already active on the host, rather than silently reinstalling
over a running cluster.

Version pinned via the `K3S_VERSION` environment variable (default set in the script), matching the
exact version this repository's own scratch validation used — not a guess, not "latest."

No node-role labeling: SCRAP v1 is single-node only (multi-node is explicitly out of scope,
`docs/out-of-scope/README.md`), so there is no role to label yet.
