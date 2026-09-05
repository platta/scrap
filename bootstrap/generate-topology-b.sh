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
#   OP_AGE_PUB             If BOTH this and ESCROW_AGE_PUB are set, EVERY
#                         *.sops.yaml this generator ships under
#                         clusters/<name>/secrets/ -- the restic credential
#                         and one per credential-bearing capability, in their
#                         own subdirectories -- is re-encrypted to these two
#                         age public keys instead of the published,
#                         non-secret reference keypair, which is then
#                         removed. The same one-time re-encryption
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

# instance-name contract: an RFC 1123 DNS label -- lowercase letters,
# digits, and '-' only, starting and ending with a letter or digit, at
# most 63 characters. The same contract Kubernetes itself enforces on
# object names, chosen because INSTANCE_NAME is interpolated throughout
# this script: into filesystem paths (CLUSTER_DIR), sed replacement text,
# generated YAML content, generated Markdown documentation, and the final
# commit message. A weaker check here is a real bug, not a style
# preference: an earlier version of this script rejected only an empty
# name or one containing '/', which let "." and ".." through --
# CLUSTER_DIR="$OUT_DIR/clusters/.." resolves to $OUT_DIR ITSELF, so the
# generator silently wrote clusters/, secrets/, and capabilities/ content
# into the wrong location and still committed the malformed result instead
# of failing safely (found in review, PLAT-38). Validating BEFORE touching
# the filesystem at all -- this is the first substantive check in the
# script -- closes that class of defect structurally: every character this
# contract forbids ('.', '/', whitespace, '$', '`', ';', quotes, and every
# other shell/YAML-significant character) is exactly the set that made the
# interpolation sites above unsafe.
case "$INSTANCE_NAME" in
    "")
        echo "instance-name must not be empty" >&2
        exit 1
        ;;
esac
case "$INSTANCE_NAME" in
    *[!a-z0-9-]*)
        echo "instance-name must contain only lowercase letters, digits, and '-' (got '$INSTANCE_NAME')" >&2
        exit 1
        ;;
esac
case "$INSTANCE_NAME" in
    -*|*-)
        echo "instance-name must start and end with a letter or digit, not '-' (got '$INSTANCE_NAME')" >&2
        exit 1
        ;;
esac
if [ "${#INSTANCE_NAME}" -gt 63 ]; then
    echo "instance-name must be 63 characters or fewer, an RFC 1123 DNS label (got ${#INSTANCE_NAME}: '$INSTANCE_NAME')" >&2
    exit 1
fi

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
\`clusters/$INSTANCE_NAME/secrets/\`, part of this repository, not the pinned upstream. That
directory really does ship here: \`clusters/$INSTANCE_NAME/secrets/\` carries a subdirectory for
every credential-bearing capability, already re-keyed to this instance.

**One edit that copied file does need, though:** its \`spec.path\` is hardcoded to
\`./clusters/example/secrets/<name>\` -- the upstream repository's own reference instance -- and
must be changed to \`./clusters/$INSTANCE_NAME/secrets/<name>\`. Renaming the copied file does
not change \`spec.path\`, and left as shipped it points Flux at a directory this repository does
not contain. See \`clusters/$INSTANCE_NAME/secrets/README.md\`.
EOF

# ---------------------------------------------------------------------------
log "secrets/ -- the WHOLE reference secrets tree, re-keyed if OP_AGE_PUB/ESCROW_AGE_PUB were given"
# REAL DEFECT, found in the PLAT-167 external-adoption review (E5): this
# block used to copy exactly three files -- secrets/kustomization.yaml,
# restic-credentials.sops.yaml, and the reference key -- while the
# capabilities/README.md this same script generates told the operator that a
# capability's credentials Kustomization "targets clusters/<name>/secrets/,
# part of this repository". The per-capability secret subdirectories that
# claim names (identity/, grafana/, public-tls/, alert-delivery/,
# heartbeat/, dyndns/, ups/) were never created, so a Topology B operator
# enabling any credential-bearing capability got a Flux path-not-found
# against a directory they had no documented way to reconstruct -- the
# templates live in the upstream repository their whole topology exists to
# avoid checking out.
#
# Copying the whole tree, rather than an enumerated file list, is the
# structural half of the fix: an enumeration is exactly what drifted here,
# and would drift again the next time a capability adds a secret directory.
# README.md is the one deliberate exclusion -- it documents clusters/example/
# specifically, and this script writes an instance-accurate replacement below.
cp -R "$REF_CLUSTER_DIR/secrets/." "$CLUSTER_DIR/secrets/"
rm -f "$CLUSTER_DIR/secrets/README.md"
cp "$REF_CLUSTER_DIR/.sops.yaml" "$CLUSTER_DIR/.sops.yaml"
# The copied .sops.yaml's own comments carry the sops CWD warning and point
# at clusters/example/ paths that do not exist in this repository at all.
# Retarget them so the warning is actionable where it actually lands.
sed -i "s|clusters/example/|clusters/$INSTANCE_NAME/|g" "$CLUSTER_DIR/.sops.yaml"

# The per-capability secret directories actually produced above, discovered
# rather than hardcoded, so the generated documentation below can never
# claim a directory this run didn't create.
CAP_SECRET_DIRS=$(find "$CLUSTER_DIR/secrets" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)

REKEYED=0
if [ -n "$OP_AGE_PUB" ] && [ -n "$ESCROW_AGE_PUB" ]; then
    REKEYED=1
    # Same one-time re-encryption clusters/example/secrets/README.md documents
    # by hand for Topology B / any manual setup, done here instead: rewrite
    # .sops.yaml's recipients, re-encrypt using the published reference
    # private key (never secret -- see that README), then remove it.
    sed -i "s|^\( *age: \).*|\1${OP_AGE_PUB},${ESCROW_AGE_PUB}|" "$CLUSTER_DIR/.sops.yaml"
    # `find`, not one hardcoded filename: bootstrap/install.sh:280-298
    # records finding this exact class of bug the hard way on its own side --
    # a flat `*.sops.yaml` glob never reached
    # secrets/identity/identity-credentials.sops.yaml one directory deeper,
    # whose only usable key was then deleted two lines later, producing
    # "age: identity did not match any of the recipients" the first time Flux
    # tried to decrypt it. This generator shipped the narrower version of the
    # same defect (a single named file) and, now that it copies every shipped
    # ciphertext rather than one, would strand all but the restic credential.
    # The `cd` is not optional either: sops resolves .sops.yaml by walking up
    # from the CURRENT WORKING DIRECTORY, so this must run from inside
    # secrets/ against bare relative paths -- exactly as a human must.
    #
    # Both guards below exist because the failure they prevent is silent and
    # irreversible: the very next statement deletes the only key that can
    # still decrypt anything this loop missed. `set -e` does NOT cover either
    # case on its own -- a `while` loop's status is its last iteration's, so a
    # sops failure partway through is swallowed, and an empty loop succeeds
    # vacuously. Fail loudly instead of shipping a repository whose secrets
    # nobody can ever decrypt again.
    SOPS_FILE_COUNT=$(find "$CLUSTER_DIR/secrets" -name '*.sops.yaml' | wc -l | tr -d ' ')
    if [ "$SOPS_FILE_COUNT" -eq 0 ]; then
        echo "No *.sops.yaml found under $CLUSTER_DIR/secrets -- refusing to remove the reference key." >&2
        exit 1
    fi
    if ! ( cd "$CLUSTER_DIR/secrets" && find . -name '*.sops.yaml' -print | sed 's#^\./##' | \
        while IFS= read -r f; do
            SOPS_AGE_KEY_FILE="./PUBLISHED-NOT-SECRET-reference.agekey" \
                sops updatekeys -y "$f" >/dev/null || exit 1
        done ); then
        echo "Failed to re-key every *.sops.yaml under $CLUSTER_DIR/secrets -- refusing to remove the" >&2
        echo "reference key, which is still the only thing that can decrypt them. Nothing was deleted." >&2
        exit 1
    fi
    log "re-keyed $SOPS_FILE_COUNT encrypted secret(s) to this instance's own age keys"
    rm -f "$CLUSTER_DIR/secrets/PUBLISHED-NOT-SECRET-reference.agekey"
elif [ -n "$OP_AGE_PUB" ] || [ -n "$ESCROW_AGE_PUB" ]; then
    echo "OP_AGE_PUB and ESCROW_AGE_PUB must both be set to re-key, or neither -- got only one." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
log "secrets/README.md -- instance-accurate: what was actually produced, and its re-key state"
# Written from what the copy above actually produced (CAP_SECRET_DIRS is
# discovered, not hardcoded) rather than restating upstream's own
# clusters/example/secrets/README.md, which describes a directory this
# repository does not contain and whose paths would all be wrong here.
#
# Deliberately built from QUOTED heredocs plus one @INSTANCE@ substitution,
# unlike the unquoted heredocs elsewhere in this script: the re-keying
# procedure below is a shell snippet the operator copies verbatim, thick with
# `$(...)`, "$f" and backticks that must survive into the generated file
# untouched. Escaping each one by hand is precisely how generated
# documentation silently ends up wrong.
cat > "$CLUSTER_DIR/secrets/README.md" <<'EOF'
# clusters/@INSTANCE@/secrets/

SOPS-encrypted secrets for this instance, decrypted by Flux at reconcile time using the
`sops-age` Secret that `bootstrap/install.sh` seeds into `flux-system`. Encryption rules live in
`clusters/@INSTANCE@/.sops.yaml`.

**Read that file's own comments before running `sops` by hand.** In short: `sops` discovers
`.sops.yaml` by walking up from your *current working directory*, not from the file you point it
at, so always `cd` into this directory (or a descendant) first and pass a bare filename, never a
path. Run it from somewhere else and it can silently encrypt to the wrong recipients with no
error at all.

Generated by `bootstrap/generate-topology-b.sh`; this file describes what that generator actually
produced here. The upstream SCRAP repository's own `clusters/example/secrets/README.md` carries
the background this summarises -- what the published reference keypair is and why it exists, the
restic credential's contents, and the escrow rules for `RESTIC_PASSWORD`.

## What is here

- `restic-credentials.sops.yaml` -- read unconditionally by `platform/backup/`; every install has
  it, enabled or not. It is the only entry in this directory's own `kustomization.yaml`.
- One subdirectory per credential-bearing capability, each carrying its own `kustomization.yaml`
  and ciphertext, and applied **only** once you enable that capability:
EOF
for d in $CAP_SECRET_DIRS; do
    printf '  - `%s/`' "$d"
    for f in "$CLUSTER_DIR/secrets/$d"/*.sops.yaml; do
        # `if`, not `[ -e "$f" ] && printf ...`: under `set -e` a failing
        # AND-list is itself a failed command, so the short-circuit form
        # aborts the whole generator the first time a secret directory
        # contains no ciphertext and the glob stays unexpanded.
        if [ -e "$f" ]; then
            printf ' -- `%s`' "$(basename "$f")"
        fi
    done
    printf '\n'
done >> "$CLUSTER_DIR/secrets/README.md"
cat >> "$CLUSTER_DIR/secrets/README.md" <<'EOF'

What applies one of those directories is the matching capability's own
`cluster-secrets-kustomization.yaml`, which lives in the pinned upstream under
`capabilities/<name>/`. Copy it into `clusters/@INSTANCE@/capabilities/` to enable that
capability, and **edit its `spec.path`**: it ships hardcoded as
`./clusters/example/secrets/<name>` and has to point at `./clusters/@INSTANCE@/secrets/<name>`,
this instance's own path. Renaming the copied *file* is not enough and does not change
`spec.path`.

## Re-keying state

EOF
if [ "$REKEYED" -eq 1 ]; then
    cat >> "$CLUSTER_DIR/secrets/README.md" <<'EOF'
**Re-keyed.** Every `*.sops.yaml` above -- the restic credential and each per-capability file --
was re-encrypted at generation time to the operational and escrow age public keys supplied via
`OP_AGE_PUB`/`ESCROW_AGE_PUB`, and the published reference key was then removed from this
repository. Nothing published anywhere can decrypt these files.

The *values* inside them are still upstream's placeholders. Replace them before this instance
holds anything real: `cd` into this directory and run `sops <file>` -- it re-encrypts to your own
recipients on save. See each capability's own README in the upstream repository for which keys it
reads and what they must contain.
EOF
else
    cat >> "$CLUSTER_DIR/secrets/README.md" <<'EOF'
**NOT re-keyed -- demo only.** Every `*.sops.yaml` above is still encrypted to the published,
non-secret reference keypair whose private half is sitting right here in
`PUBLISHED-NOT-SECRET-reference.agekey`. Anyone who can read this repository can decrypt all of
them. Fine for a local demo; **not fine for anything real.**

Before this repository holds any real secret, re-key **every** file -- not just the restic one:

```sh
age-keygen -o /etc/scrap/age/operational.agekey   # keep private, on this host only
age-keygen -o /etc/scrap/age/escrow.agekey        # keep private, off this host

OP_PUB=$(age-keygen -y /etc/scrap/age/operational.agekey)
ESCROW_PUB=$(age-keygen -y /etc/scrap/age/escrow.agekey)

# Edit clusters/@INSTANCE@/.sops.yaml: replace the reference "age:" value with
#   age: <OP_PUB>,<ESCROW_PUB>

cd clusters/@INSTANCE@/secrets   # not optional -- see the CWD warning above
find . -name '*.sops.yaml' -print | sed 's#^\./##' | while IFS= read -r f; do
    SOPS_AGE_KEY_FILE=PUBLISHED-NOT-SECRET-reference.agekey sops updatekeys -y "$f"
done
rm PUBLISHED-NOT-SECRET-reference.agekey
cd -
```

`find`, not a `*.sops.yaml` glob: a flat glob matches only the restic credential directly in this
directory and silently misses every per-capability file above, one level deeper. Re-key some of
them, delete the reference key, and this instance is permanently locked out of the rest -- Flux
fails with `age: no identity matched` the first time it tries to decrypt one, and nothing
connects that error back to this step.

Then replace the placeholder *values* too (`sops <file>`, from this directory -- it re-encrypts to
your new recipients on save). `RESTIC_PASSWORD` in particular is one of the platform's
fatal-if-lost secrets: escrow it separately from the age keys.
EOF
fi
sed -i "s|@INSTANCE@|$INSTANCE_NAME|g" "$CLUSTER_DIR/secrets/README.md"

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
REKEY_NOTE="**Secrets are re-keyed:** every \`*.sops.yaml\` under \`clusters/$INSTANCE_NAME/secrets/\` -- the restic credential and one per credential-bearing capability -- was re-encrypted to the operational/escrow age keys supplied at generation time. The published reference key was removed. The values inside them are still placeholders: see \`clusters/$INSTANCE_NAME/secrets/README.md\`."
if [ "$REKEYED" -eq 0 ]; then
    REKEY_NOTE="**Secrets are NOT yet re-keyed.** Every \`*.sops.yaml\` under \`clusters/$INSTANCE_NAME/secrets/\` is still encrypted to the published, non-secret reference keypair (\`clusters/$INSTANCE_NAME/secrets/PUBLISHED-NOT-SECRET-reference.agekey\`) -- fine for a local demo, **not fine for anything real**. Before this repository holds any real secret, re-key **all** of them -- not just the restic one -- following the procedure in \`clusters/$INSTANCE_NAME/secrets/README.md\`."
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
