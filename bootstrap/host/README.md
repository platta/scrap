# bootstrap/host/

Not yet implemented. Will contain the pinned k3s install (exact version, `--disable=traefik` so
Flux is the sole reconciler for platform infrastructure — see `platform/ingress/README.md`), node
labeling, and documented minimum OS/package expectations for the supported host distributions
(`docs/core/`).

This directory existing and being populated is itself an architectural commitment: a fresh or
recovering node must be reconstructible from what's checked in here plus Git, not from
undocumented, one-off operator knowledge.
