# Getting started

This is the linear path from "I've never seen SCRAP before" to a running platform you can verify
yourself. It intentionally does not require reading any architecture documentation first — if you
want the full conceptual picture before or after installing, see
[Understanding SCRAP](understanding-scrap.md) and [Where to go next](#where-to-go-next) below.

## 1. Check your host

SCRAP wants one Linux host (a spare machine, an old desktop, a cheap VPS — hence the name) with:

- 2 cores, 4 GB RAM, 32 GB SSD, as a floor.
- A supported kernel: cgroup v2, the usual container-runtime prerequisites. Any current Debian or
  Ubuntu works; other modern distributions generally do too.
- A stable way for clients on your network (or the internet, if you choose that later) to reach it —
  a static IP, a DHCP reservation, or a LAN DNS/mDNS name.
- A roughly correct clock and internet access **once, at install time**, to pull container images.
- x86-64 is what's continuously tested. arm64 is accepted (the preflight checks allow it) but isn't
  yet verified the same way — see [`docs/release-readiness.md`](release-readiness.md) if that
  matters for your hardware.

You do **not** need a public IP, a domain, a cloud account, S3/object storage, or a second machine
for the minimum install. Those unlock optional capabilities later — see
[Choosing your capabilities](choosing-capabilities.md).

The install script checks all of this for you before touching anything (step 2 below) and refuses
to continue on a real failure — but knowing the floor up front saves you a wasted attempt.

## 2. Clone the repository

```sh
git clone https://github.com/<your-fork-or-upstream>/scrap.git
cd scrap
```

Running SCRAP does not require you to keep working out of this clone forever — see
[Choosing your capabilities](choosing-capabilities.md#one-more-option-a-separate-operator-repository)
if you'd rather maintain a small separate repository pinned to a released SCRAP version. For a
first install, working directly in this clone is the simplest path and what this repository's own
tests exercise.

## 3. Make your minimum configuration choices

You can accept every default below and get a working platform with no public-facing dependencies at
all. Two things are worth deciding before you run the installer, because they're awkward to change
later:

- **A name for this instance** (`INSTANCE_NAME`) — short and unique, never an application name. It
  tags every backup snapshot this instance writes, so it can't ever be mixed up with another
  instance's backups.
- **A base domain** (`BASE_DOMAIN`) — if you don't have a real domain yet, any name under the
  reserved `.internal` namespace works fine (e.g. `home.internal`) and needs nothing further.

Everything else in the configuration file has a safe, working default. If you want more than the
minimum — a real public domain, off-site backup, single sign-on — see
[Choosing your capabilities](choosing-capabilities.md) **before** you run the installer; it's a
short checklist and easier to do now than to retrofit.

To apply your choices:

```sh
cp -r clusters/example clusters/<your-instance-name>
```

Edit `clusters/<your-instance-name>/instance-config.yaml` and replace the placeholder values —
every field is commented with what it's for and what a safe value looks like.

## 4. Install

```sh
sudo CLUSTER_PATH=./clusters/<your-instance-name> sh bootstrap/install.sh
```

This runs, in order: a preflight check (fails loudly and touches nothing if your host isn't ready),
a pinned k3s install, generation of your encryption keys (with escrow verification — losing these
would mean losing the ability to decrypt your own secrets), initialization of the Git source of
truth, and a `flux bootstrap` that reconciles the whole platform: certificates, routing, storage,
backup, and observability.

Expect this to take a few minutes. It's meant to be re-runnable if something transient fails — read
the on-screen messages; a genuine preflight failure will tell you exactly what to fix.

## 5. Confirm it worked

At the end of the install, `postflight.sh` prints a report. Look for:

- Every Flux `Kustomization` reporting `Ready`.
- The private CA root certificate exported, with instructions for trusting it on your own devices
  (only needed if you didn't enable a public certificate authority).
- A backup run confirmed to have succeeded.
- The alerting-receiver status stated plainly — by default this will say **no receiver is
  configured**, meaning you won't be notified if something later goes wrong. That's an honest
  default, not a bug; configuring a real one (email, ntfy, a webhook) is worth doing early.

Then check the platform itself is actually reachable:

```sh
curl --cacert <the exported CA, printed above> https://p1.<your BASE_DOMAIN>/
```

(or `-k` instead of `--cacert` if you just want a quick check and aren't worried about certificate
validation yet). A response identifying itself as `whoami` confirms a real request reached a real
pod through TLS termination and routing — the whole core platform, working end to end.

## 6. If something didn't work

- **Preflight failed:** the message names the exact check and why — fix that specific thing (a port
  in use, insufficient disk, wrong clock) and re-run. Nothing was installed yet.
- **Install failed partway through:** re-running `bootstrap/install.sh` is expected to be safe; it's
  built to resume rather than corrupt a partial state. If it isn't behaving that way, that's a real
  bug worth reporting.
- **Everything reports `Ready` but the `curl` check fails:** check `kubectl get pods -A` for
  anything not `Running` — there is no SCRAP-specific inspection tool; ordinary `kubectl`, `flux get
  kustomizations`, and each component's own logs are the whole story, on purpose (see
  [Understanding SCRAP](understanding-scrap.md)).
- **No receiver configured, and you want to fix that now:** that's the first thing worth doing after
  a successful install — see [`platform/observability/README.md`](../platform/observability/README.md)
  or [Choosing your capabilities](choosing-capabilities.md) for the alert-delivery capability's
  current status.

## Where to go next

- **Add your first real application** — [Adding an application](adding-an-application.md).
- **Turn on optional capabilities** — single sign-on, off-site backup, publicly-trusted
  certificates, and more — [Choosing your capabilities](choosing-capabilities.md).
- **Understand what's actually running and why** — [Understanding SCRAP](understanding-scrap.md), a
  10–15 minute layer-by-layer walkthrough.
- **See exactly what's proven versus still open** for the version you're running —
  [`docs/release-readiness.md`](release-readiness.md).
- **Understand how SCRAP knows any of its claims are true** —
  [How SCRAP knows its claims are true](engineering-evidence.md).
