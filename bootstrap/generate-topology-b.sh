#!/bin/sh
# bootstrap/generate-topology-b.sh -- ADR-0009 Topology B generator.
#
# SCRAP introduces no scaffolding framework here, only ordinary
# Flux/Kustomize/SOPS manifests: this script's entire job is producing that
# ordinary output with the one mechanical diff ADR-0009 documents applied
# consistently -- every platform-tier Kustomization's sourceRef swapped from
# flux-system to a new, separately-pinned "scrap-platform" GitRepository --
# so an operator never has to reconstruct that diff by hand. See
# docs/decisions/0009-repository-topology.md, "Topology B" and "Required for
# v1".
#
# The generated repository contains ONLY clusters/<name>/ (instance config,
# the platform-tier Kustomization pointers, and an empty capabilities/), the
# operator's own (empty, ready-to-use) apps/, and clusters/<name>/secrets/ --
# no copy of platform/, capabilities/, or components/ at all, exactly as
# ADR-0009 requires. It is a normal Git repository (git init + one commit);
# hosting it anywhere -- a local bare repo over SSH, GitHub, GitLab,
# Forgejo, anything else with a Git remote -- is the operator's own choice,
# never something this script assumes or bakes in.
#
# Usage:
#   sh bootstrap/generate-topology-b.sh <output-dir> [instance-name]
#
# <output-dir> must not already exist, or must be empty -- this script
# always produces a fresh, deterministic result; it never merges into
# existing content. [instance-name] defaults to "instance".
#
# Configuration via environment variables, all optional:
#
#   UPSTREAM_URL         Git URL the generated "scrap-platform"
#                         GitRepository pins to. Default:
#                         https://github.com/platta/scrap -- the real,
#                         public upstream. Point this at a fork, mirror, or
#                         local host instead if you need to.
#   UPSTREAM_REF          Commit SHA to pin scrap-platform to. Default: this
#                         checkout's own HEAD (`git rev-parse HEAD`) -- SCRAP
#                         does not yet cut tagged releases
#                         (docs/decisions/0009-repository-topology.md), and a
#                         commit SHA "works identically" per that decision.
#   UPSTREAM_TAG          If set, pins via `ref: {tag: ...}` instead of a
#                         commit SHA. Takes precedence over UPSTREAM_REF.
#   UPSTREAM_SECRET_REF   If set, the generated scrap-platform GitRepository
#                         references this Secret name for authentication
#                         (spec.secretRef.name) -- needed for a ssh:// (or
#                         private https://) UPSTREAM_URL. Left unset (no
#                         secretRef at all) when UPSTREAM_URL is http(s)://,
#                         correct for the documented default (a public,
#                         anonymous-read HTTPS URL). Defaults to
#                         "scrap-platform-upstream" when UPSTREAM_URL is
#                         ssh:// and this is left unset -- a Secret name the
#                         operator must create themselves (an SSH keypair
#                         Flux can present to that host), documented in the
#                         generated repository's own README.
#   OP_AGE_PUB             If BOTH this and ESCROW_AGE_PUB are set, the
#                         reference secret this generator ships
#                         (clusters/<name>/secrets/restic-credentials.sops.yaml)
#                         is re-encrypted to these two age public keys
#                         instead of the published, non-secret reference
#                         keypair -- the same one-time re-encryption
#                         clusters/example/secrets/README.md documents for a
#                         real instance, done here instead of by hand.
#   ESCROW_AGE_PUB         See OP_AGE_PUB above. Leave both unset to get the
#                         reference (demo-only, publicly decryptable) secret
#                         plus a prominent warning in the generated README
#                         instead.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REF_CLUSTER_DIR="$REPO_ROOT/clusters/example"

log() { echo "==> $*"; }

OUT_DIR="${1:-}"
INSTANCE_NAME="${2:-instance}"
if [ -z "$OUT_DIR" ]; then
    echo "Usage: sh bootstrap/generate-topology-b.sh <output-dir> [instance-name]" >&2
    exit 1
fi
case "$INSTANCE_NAME" in
    */*|"") echo "instance-name must be a single non-empty path segment (got '$INSTANCE_NAME')" >&2; exit 1 ;;
esac

if [ -e "$OUT_DIR" ]; then
    if [ ! -d "$OUT_DIR" ] || [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
        echo "$OUT_DIR already exists and is not an empty directory -- refusing to merge into it." >&2
        echo "This script always produces a fresh, deterministic result. Remove it first, or pick a different output-dir." >&2
        exit 1
    fi
fi

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/platta/scrap}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
UPSTREAM_REF="${UPSTREAM_REF:-}"
if [ -z "$UPSTREAM_TAG" ] && [ -z "$UPSTREAM_REF" ]; then
    UPSTREAM_REF="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
UPSTREAM_SECRET_REF="${UPSTREAM_SECRET_REF:-}"
if [ -z "$UPSTREAM_SECRET_REF" ]; then
    case "$UPSTREAM_URL" in
        ssh://*) UPSTREAM_SECRET_REF="scrap-platform-upstream" ;;
    esac
fi
OP_AGE_PUB="${OP_AGE_PUB:-}"
ESCROW_AGE_PUB="${ESCROW_AGE_PUB:-}"

if ! command -v sops >/dev/null 2>&1; then
    echo "'sops' not found -- required to produce clusters/$INSTANCE_NAME/secrets/. See" >&2
    echo "bootstrap/preflight/check-prerequisites.sh for the install pointer." >&2
    exit 1
fi

CLUSTER_DIR="$OUT_DIR/clusters/$INSTANCE_NAME"
mkdir -p "$CLUSTER_DIR/capabilities" "$CLUSTER_DIR/secrets" "$OUT_DIR/apps"

# ---------------------------------------------------------------------------
log "instance-config.yaml -- same schema as clusters/example/, INSTANCE_NAME set"
sed "s|^\(  INSTANCE_NAME: \).*|\1\"$INSTANCE_NAME\"|" \
    "$REF_CLUSTER_DIR/instance-config.yaml" > "$CLUSTER_DIR/instance-config.yaml"

# ---------------------------------------------------------------------------
log "platform-tier Kustomizations -- sourceRef swapped flux-system -> scrap-platform"
# The one mechanical diff ADR-0009's own "Topology B" section documents,
# applied identically to every Kustomization whose path resolves under
# ./platform/ -- these files exist only in the pinned upstream, never in
# this generated repository. sourceRef's "name: flux-system" is always
# 4-space indented (under spec.sourceRef), distinct from metadata.name's
# 2-space indent -- see any of these files' own layout -- so this
# substitution can't collide with a Kustomization's own name.
for f in platform-crds.yaml platform-cert-manager.yaml platform-cert-manager-config.yaml \
         platform-ingress.yaml platform-observability.yaml platform-observability-config.yaml \
         platform-backup.yaml; do
    sed 's/^    name: flux-system$/    name: scrap-platform/' \
        "$REF_CLUSTER_DIR/$f" > "$CLUSTER_DIR/$f"
done

# ---------------------------------------------------------------------------
log "instance-specific pointers -- sourceRef stays flux-system (this repo), path retargeted"
# platform-secrets.yaml and capabilities.yaml resolve inside THIS
# repository, never the pinned upstream -- only their path needs
# clusters/example -> clusters/$INSTANCE_NAME; sourceRef is untouched.
sed "s|path: ./clusters/example/secrets|path: ./clusters/$INSTANCE_NAME/secrets|" \
    "$REF_CLUSTER_DIR/platform-secrets.yaml" > "$CLUSTER_DIR/platform-secrets.yaml"
sed "s|path: ./clusters/example/capabilities|path: ./clusters/$INSTANCE_NAME/capabilities|" \
    "$REF_CLUSTER_DIR/capabilities.yaml" > "$CLUSTER_DIR/capabilities.yaml"

# ---------------------------------------------------------------------------
log "scrap-platform GitRepository -- the pinned upstream source itself"
{
    echo "# Pinned upstream SCRAP source -- see"
    echo "# docs/decisions/0009-repository-topology.md \"Topology B\". Bump this"
    echo "# file's ref deliberately when you want to pull in a newer SCRAP"
    echo "# release; Flux never does this on its own."
    echo "apiVersion: source.toolkit.fluxcd.io/v1"
    echo "kind: GitRepository"
    echo "metadata:"
    echo "  name: scrap-platform"
    echo "  namespace: flux-system"
    echo "spec:"
    echo "  interval: 1h"
    if [ -n "$UPSTREAM_TAG" ]; then
        echo "  ref:"
        echo "    tag: $UPSTREAM_TAG"
    else
        echo "  ref:"
        echo "    commit: $UPSTREAM_REF"
    fi
    echo "  url: $UPSTREAM_URL"
    if [ -n "$UPSTREAM_SECRET_REF" ]; then
        echo "  secretRef:"
        echo "    name: $UPSTREAM_SECRET_REF"
    fi
} > "$CLUSTER_DIR/scrap-platform-source.yaml"

# ---------------------------------------------------------------------------
log "apps/ -- the operator's own, empty and ready to use (never a copy of apps/examples/)"
cat > "$OUT_DIR/apps/README.md" <<'EOF'
# apps/

Your own applications. Empty by default -- T1 (docs/README.md's own architectural invariant)
holds here exactly as it does in the main SCRAP repository: delete everything under this
directory and the platform remains complete and useful.

Add an application by adding files here plus exactly one Flux `Kustomization` file under
`clusters/<name>/` that enables it (T2) -- see `docs/patterns/` in the upstream SCRAP repository
for the six supported application-integration patterns, and `apps.yaml` next to this file's
parent `clusters/<name>/` directory for the Kustomization already wired to this path.
EOF
cat > "$CLUSTER_DIR/apps.yaml" <<EOF
# Enables this repository's own apps/ -- see apps/README.md. Deliberately
# sourceRef: flux-system (this repository), never scrap-platform: an
# operator's applications are never part of the pinned upstream.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: platform-ingress
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: instance-config
  wait: true
  timeout: 5m0s
EOF

# ---------------------------------------------------------------------------
log "capabilities/ -- empty (the minimal profile), same fallback semantics as clusters/example/"
cat > "$CLUSTER_DIR/capabilities/README.md" <<EOF
# clusters/$INSTANCE_NAME/capabilities/

Empty. See the upstream SCRAP repository's \`capabilities/README.md\` for what's available.

**Topology B note:** enabling a capability here is the same "copy its Kustomization file(s) in"
mechanism documented there, with one addition -- each capability's own \`cluster-kustomization.yaml\`
targets \`./capabilities/<name>\`, which (like \`platform/\`) exists only in the pinned
\`scrap-platform\` source, never in this repository. Change that copied file's
\`spec.sourceRef.name\` from \`flux-system\` to \`scrap-platform\`, the exact same one-line diff
this generator already applied to every platform-tier Kustomization -- see
\`docs/decisions/0009-repository-topology.md\`. A capability's own credentials Kustomization
(when it has one) stays \`sourceRef: flux-system\` unchanged -- it targets
\`clusters/$INSTANCE_NAME/secrets/\`, part of this repository, not the pinned upstream.
EOF

# ---------------------------------------------------------------------------
log "secrets/ -- the reference restic credential, re-keyed if OP_AGE_PUB/ESCROW_AGE_PUB were given"
cp "$REF_CLUSTER_DIR/secrets/kustomization.yaml" "$CLUSTER_DIR/secrets/kustomization.yaml"
cp "$REF_CLUSTER_DIR/secrets/restic-credentials.sops.yaml" "$CLUSTER_DIR/secrets/restic-credentials.sops.yaml"
cp "$REF_CLUSTER_DIR/secrets/PUBLISHED-NOT-SECRET-reference.agekey" "$CLUSTER_DIR/secrets/PUBLISHED-NOT-SECRET-reference.agekey"
cp "$REF_CLUSTER_DIR/.sops.yaml" "$CLUSTER_DIR/.sops.yaml"

REKEYED=0
if [ -n "$OP_AGE_PUB" ] && [ -n "$ESCROW_AGE_PUB" ]; then
    REKEYED=1
    # Same one-time re-encryption clusters/example/secrets/README.md documents
    # by hand for Topology B / any manual setup, done here instead: rewrite
    # .sops.yaml's recipients, re-encrypt using the published reference
    # private key (never secret -- see that README), then remove it.
    sed -i "s|^\( *age: \).*|\1${OP_AGE_PUB},${ESCROW_AGE_PUB}|" "$CLUSTER_DIR/.sops.yaml"
    ( cd "$CLUSTER_DIR/secrets" && \
        SOPS_AGE_KEY_FILE="./PUBLISHED-NOT-SECRET-reference.agekey" \
        sops updatekeys -y restic-credentials.sops.yaml >/dev/null )
    rm -f "$CLUSTER_DIR/secrets/PUBLISHED-NOT-SECRET-reference.agekey"
elif [ -n "$OP_AGE_PUB" ] || [ -n "$ESCROW_AGE_PUB" ]; then
    echo "OP_AGE_PUB and ESCROW_AGE_PUB must both be set to re-key, or neither -- got only one." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
log "clusters/$INSTANCE_NAME/kustomization.yaml -- explicit resource list (never auto-flatten secrets/)"
cat > "$CLUSTER_DIR/kustomization.yaml" <<EOF
# Explicit, not auto-discovered -- same reason as clusters/example/'s own
# kustomization.yaml: secrets/ has its own dedicated Kustomization
# (platform-secrets.yaml, decryption.provider: sops), and must never be
# picked up implicitly by this one.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - instance-config.yaml
  - scrap-platform-source.yaml
  - platform-crds.yaml
  - platform-cert-manager.yaml
  - platform-cert-manager-config.yaml
  - platform-ingress.yaml
  - platform-observability.yaml
  - platform-observability-config.yaml
  - platform-secrets.yaml
  - platform-backup.yaml
  - apps.yaml
  - capabilities.yaml
EOF

# ---------------------------------------------------------------------------
log "README.md -- what this repository is and how to bootstrap it"
REKEY_NOTE="**Secrets are re-keyed:** \`clusters/$INSTANCE_NAME/secrets/restic-credentials.sops.yaml\` was re-encrypted to the operational/escrow age keys supplied at generation time. The published reference key was removed."
if [ "$REKEYED" -eq 0 ]; then
    REKEY_NOTE="**Secrets are NOT yet re-keyed.** \`clusters/$INSTANCE_NAME/secrets/restic-credentials.sops.yaml\` is still encrypted to the published, non-secret reference keypair (\`clusters/$INSTANCE_NAME/secrets/PUBLISHED-NOT-SECRET-reference.agekey\`) -- fine for a local demo, **not fine for anything real**. Before this repository holds any real secret, follow the same manual re-keying procedure the upstream SCRAP repository documents at \`clusters/example/secrets/README.md\` (\"If you are setting up a real instance by hand\")."
fi
if [ -n "$UPSTREAM_TAG" ]; then
    PIN_LINE="- Pinned tag: \`$UPSTREAM_TAG\`"
else
    PIN_LINE="- Pinned commit: \`$UPSTREAM_REF\`"
fi
cat > "$OUT_DIR/README.md" <<EOF
# SCRAP instance: $INSTANCE_NAME (Topology B)

Generated by \`bootstrap/generate-topology-b.sh\` -- see
\`docs/decisions/0009-repository-topology.md\` ("Topology B") in the upstream SCRAP repository
for the full mechanism this repository implements. It contains **only**
\`clusters/$INSTANCE_NAME/\` (instance config, capability selection, secrets) and this
repository's own \`apps/\` -- no copy of \`platform/\`, \`capabilities/\`, or \`components/\` at all.
Everything else is consumed from a separately pinned upstream source, wired via
\`clusters/$INSTANCE_NAME/scrap-platform-source.yaml\`:

- URL: \`$UPSTREAM_URL\`
$PIN_LINE

## Bootstrapping this repository

1. Host this repository anywhere with a Git remote -- a local bare repository over SSH, GitHub,
   GitLab, Forgejo, anything else. Hosting choice is yours; nothing here assumes one.
2. On the target host, run the upstream SCRAP repository's own installer against THIS
   repository's URL and this instance's path:
   \`\`\`sh
   REPO_URL=<this-repository's-URL> CLUSTER_PATH=./clusters/$INSTANCE_NAME sudo -E sh bootstrap/install.sh
   \`\`\`
3. Edit \`clusters/$INSTANCE_NAME/instance-config.yaml\` with your own values before (or after --
   Flux re-reconciles either way) your first real bootstrap. Every value ships as a documented
   placeholder, never a value that's silently correct for a real install.

$REKEY_NOTE

## Enabling a capability

Same mechanism as the upstream repository's own \`clusters/<name>/capabilities/\` -- copy a
capability's Kustomization file(s) in, delete to disable -- with one addition specific to
Topology B: see \`clusters/$INSTANCE_NAME/capabilities/README.md\`.

## Adding an application

Add files under \`apps/\`, plus your own Flux \`Kustomization\` enabling them (\`apps.yaml\` already
wires this repository's whole \`apps/\` directory in) -- see the upstream repository's
\`docs/patterns/\` for the supported integration patterns.
EOF

# ---------------------------------------------------------------------------
log "git init + one commit"
( cd "$OUT_DIR" && git init -q -b main && git add -A && \
    git -c user.name=scrap-generate-topology-b -c user.email=generate-topology-b@localhost \
        commit -q -m "Generated Topology B instance: $INSTANCE_NAME" )

echo
echo "Generated a Topology B operator repository at: $OUT_DIR"
echo "Instance: clusters/$INSTANCE_NAME/  Pinned upstream: $UPSTREAM_URL"
echo "Next: host it, then run bootstrap/install.sh with REPO_URL set to that host and"
echo "CLUSTER_PATH=./clusters/$INSTANCE_NAME -- see the generated README.md."
