# bootstrap/preflight/

One script per check, plus `run-all.sh` to run them together and report every failure at once
rather than stopping at the first. Each is standalone, POSIX `sh` (no Python or other runtime
assumed — this runs before anything is installed on the host), and prints `ok` / `WARN` / `FAIL`
per line.

| Script | Checks | Blocks on failure? |
|---|---|---|
| `check-prerequisites.sh` | `curl`, `git`, `age-keygen`, `sops` are installed; if `REPO_URL` is unset (the D5 local-git minimum path), an SSH server is actually listening on port 22 -- Flux's own ongoing reconciliation depends on it, not just this script's one-time seeding | yes |
| `check-arch.sh` | x86-64 or arm64 | yes |
| `check-cgroups.sh` | cgroup v2 (unified hierarchy) active | yes |
| `check-disk.sh` | ≥10GB free on the filesystem `/var/lib` will live on | yes |
| `check-clock.sh` | Clock within 5 minutes of a live time source | yes |
| `check-ports.sh` | 6443, plus every port in `platform/ingress/reserved-ports.yaml`, are free | yes |
| `check-resolver.sh` | DNS resolves right now; the configured nameserver isn't this host's own LAN address or an unconfirmed loopback | WARN only — see below |

`check-resolver.sh`'s address-shape warning is intentionally a WARN, not a FAIL: it's a heuristic
(preflight can't know in advance what an operator will deploy), and a false FAIL here would block
legitimate configurations. A broken resolver *right now* (the live resolution test) is still a
hard FAIL.

Run all of them: `sh run-all.sh`. `bootstrap/install.sh` calls this and refuses to continue if it
exits non-zero.

**`check-ports.sh`, `check-resolver.sh`, and the very existence of `check-prerequisites.sh` were all
found wrong or missing on the first pass — by running against real hosts, not by review.** A
genuinely bare Debian cloud image does not ship `git` — without `check-prerequisites.sh`,
`install.sh` would have installed k3s and only failed three steps later trying to create the local
Git repository, leaving a stray half-bootstrapped cluster behind. See `bootstrap/README.md` for the
port/resolver findings; the corrected and completed set is what's checked in.
