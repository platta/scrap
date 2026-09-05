# Contributing

Thanks for considering a contribution. This project favors small, well-scoped changes over large
ones — see [`docs/decisions/`](docs/decisions/) for the architecture decisions any change should
be consistent with, and [Understanding SCRAP](docs/understanding-scrap.md) for the shape of the
system before touching it.

## Which branch to target

**Target `develop`.** That's the default for ordinary work — bug fixes, docs, new capabilities,
anything that isn't itself an adjudicated fix to an already-tagged release
([`docs/decisions/0016-post-rc-branching-policy.md`](docs/decisions/0016-post-rc-branching-policy.md)).

`main` is the release-quality line during the current RC-stabilization window: it only accepts
independently-adjudicated fixes to release-blocking gaps, opened by whoever adjudicates that
work. As an external contributor you should not need to target `main` directly — if you believe
you've found a release-blocking defect, open an issue first (see the README's
[Reporting problems](README.md#reporting-problems)) rather than opening a PR against `main`.

## Before you open a pull request

Run the structural checks locally — they're fast, require no cluster, and are the same checks CI
runs on every pull request:

```sh
python3 -m pip install pyyaml
bash tests/assertions/run_all.sh
```

See [`tests/assertions/README.md`](tests/assertions/README.md) for what each check encodes. If
your change touches a capability that has a live acceptance profile
(`tests/profiles/t-a-*.sh`, `tests/profiles/t-b-standard.sh`), those run automatically against
your pull request via GitHub Actions — you don't need cluster access to trigger them, but expect
them to take longer than the structural checks.

Two invariants hold everywhere in this repository and are enforced by CI, not just documented:

- **T1** — delete every application (`apps/`) and the platform still works.
- **T2** — adding a normal application never requires touching `platform/` or `capabilities/`.

A pull request that needs to violate either of these for an application-level change is a sign
the change belongs somewhere else in the repository, not an exception to request.

## License

This repository is licensed under the [Apache License 2.0](LICENSE). By opening a pull request
you agree your contribution is licensed under the same terms. There is no separate CLA or DCO
sign-off required today.

## Reporting problems instead

Found a bug but don't want to fix it yourself? See the README's
[Reporting problems](README.md#reporting-problems) section. Security-sensitive issues follow a
different, private path — see [`SECURITY.md`](SECURITY.md).
