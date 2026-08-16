# clusters/example/secrets/

SOPS-encrypted secrets for the `example` instance, decrypted by Flux at reconcile time using the
`sops-age` Secret that `bootstrap/install.sh` seeds into `flux-system` (step 4/6 — see
`docs/core/bootstrap-lifecycle.md`). Encryption rules for this directory live in
`clusters/example/.sops.yaml` — no repository-wide config, so each instance owns its own recipients.

**Important, found the hard way: `sops` discovers `.sops.yaml` by walking up from your *current
working directory*, not from the file you point it at — and matches its `path_regex` (unanchored)
against a path relative to whatever config it finds first.** Run `sops` from the wrong directory —
e.g. from inside a *different* Git repository that also happens to have a `.sops.yaml` — and it can
silently walk up into that unrelated config, match by substring, and encrypt to the wrong
recipients with **no error at all**. Always `cd` into this directory (or a descendant of
`clusters/example/`) before running any `sops` command against these files, and pass a bare
filename, not a path. Every example below does this.

## `restic-credentials.sops.yaml`

The one secret `platform/backup/` requires: `RESTIC_PASSWORD`, the password protecting the restic
repository at `${BACKUP_DESTINATION}`. Only `stringData` is ciphertext — `kind`, `apiVersion`, and
`metadata` stay plaintext (`encrypted_regex` in `.sops.yaml`) so Kustomize can still process the
manifest structurally before Flux ever decrypts it.

## `PUBLISHED-NOT-SECRET-reference.agekey`

This checked-in `example` instance needs a real, working secret so `bootstrap/install.sh` can
bootstrap it with **zero manual steps** — the same reason `instance-config.yaml` ships real
placeholder values instead of empty ones. But a committed ciphertext is only ever as good as the
key that decrypts it, and a *public* repository cannot contain anything that decrypts a *real*
secret. The resolution: `restic-credentials.sops.yaml` above is encrypted to a **reference keypair
whose private half is intentionally published right here, in plain sight.** It protects nothing —
the only thing it ever decrypts is the throwaway password above, which itself only ever protects a
disposable local backup repository during a demo or scratch install. Treat this file exactly like
cert-manager's or Kubernetes' own well-known "example" TLS keys: real cryptographic material,
zero secrecy value, committed on purpose.

**This is not how a real instance works.** `bootstrap/install.sh` step 4 generates a fresh
operational + escrow age keypair for every real installation. Before it commits anything, it
rewrites `.sops.yaml`'s recipients to that instance's own fresh public keys and runs
`sops updatekeys` against this file using the reference private key above — a one-time re-encryption
from "the published reference key" to "your own private key," after which the reference key is
deleted from the instance's own copy of the repository. From that point on, nothing published
anywhere can decrypt this instance's secrets. This is the same pattern already established for
`instance-config.yaml`: **copy the template, then it's yours** — applied to secrets, not just
scalars.

If you are setting up a real instance by hand instead of via `install.sh` (Topology B, or any
manual path — see `docs/decisions/0009-repository-topology.md`), do the equivalent yourself:

```sh
age-keygen -o /etc/scrap/age/operational.agekey   # keep private, on this host only
age-keygen -o /etc/scrap/age/escrow.agekey         # keep private, off this host

OP_PUB=$(age-keygen -y /etc/scrap/age/operational.agekey)
ESCROW_PUB=$(age-keygen -y /etc/scrap/age/escrow.agekey)

# Edit clusters/<name>/.sops.yaml: replace the reference "age:" value with
#   age: <OP_PUB>,<ESCROW_PUB>

cd clusters/<name>/secrets   # see the CWD warning above -- this cd is not optional
SOPS_AGE_KEY_FILE=PUBLISHED-NOT-SECRET-reference.agekey \
    sops updatekeys -y restic-credentials.sops.yaml
rm PUBLISHED-NOT-SECRET-reference.agekey
cd -
```

Then replace `example-reference-password-not-secret` with a real, randomly-generated password
(`cd clusters/<name>/secrets && sops restic-credentials.sops.yaml` — `sops` re-encrypts it to your
new recipients automatically on save). **Escrow this password separately from
the age keys** — it is one of the three fatal-if-lost secrets in the whole platform
(`docs/core/recovery-model.md`); losing it makes every existing backup permanently unrecoverable even
with valid access to the storage.
