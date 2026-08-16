# bootstrap/

**Tier 0.** Everything here runs *outside* the cluster, before Flux exists to reconcile anything.

```
sudo sh bootstrap/install.sh
```

runs the full sequence: preflight → k3s install → flux CLI → age keys (verified escrow) → Git
source → seed the SOPS decryption secret → `flux bootstrap` → postflight. See
`docs/core/bootstrap-lifecycle.md` for the documented sequence this implements, and the comment
block at the top of `install.sh` for every configuration variable (all optional, sensible
defaults).

**Topology-agnostic** (`docs/decisions/0009-repository-topology.md`): `install.sh` only needs a Git
URL and a path. It does not care whether that URL is a fork of this repository, a separate
Topology B consumer repository, or — the default when `REPO_URL` is unset — a local bare
repository seeded with a snapshot of this checkout, satisfying D5's minimum path with no hosted
Git required at all.

## `preflight/`

Fail-loud checks, run first, that block installation on a FAIL (not just warn): required ports
free (`check-ports.sh`, reading `platform/ingress/reserved-ports.yaml` as its source of truth), the
node's own DNS resolver is not itself cluster-hosted or an unconfirmed loopback
(`check-resolver.sh`), a roughly correct clock (`check-clock.sh`), cgroup v2 (`check-cgroups.sh`),
sufficient disk (`check-disk.sh`), and a supported architecture (`check-arch.sh`). Run individually
or all together via `run-all.sh`.

**Two real bugs found testing these against actually-running hosts, not just reading the code back:**
`check-ports.sh`'s original `ss` invocation concatenated two flags into one invalid argument and
read the wrong output column, so it silently reported every port free regardless of what was
listening — caught by testing against a host with a real production Kubernetes API already bound
to :6443, which it should have (and, once fixed, did) flag. `check-resolver.sh`'s original loopback
handling silently passed a bare `nameserver 127.0.0.1` with no way to confirm what was actually
answering there — tested directly against a real host with exactly that configuration (from this
project's own migration history) and found to give a false "ok" on the precise shape of a real,
previously-documented incident. Both fixed before this milestone shipped; see the scripts'
docstrings for the detail.

## `host/`

`install-k3s.sh` — the pinned k3s install (`--disable=traefik`, so Flux is the only reconciler for
platform infrastructure — see `platform/ingress/README.md`). Refuses to run over an
already-running k3s rather than silently reinstalling on top of it.

## `install.sh` / `postflight.sh`

`install.sh` is the orchestration described above. `postflight.sh` (called at the end, but also
safe to re-run standalone) waits for every Flux `Kustomization` to report Ready, exports the
private CA root with trust instructions, and states the Alertmanager receiver's actual
configuration plainly — including, honestly, when there isn't one.

**Not yet in postflight:** a backup ran and a restore was verified. `platform/backup/` (the restic
engine) doesn't exist yet — this step is added alongside it, not stubbed out speculatively ahead of
the thing it verifies.
