# bootstrap/preflight/

Not yet implemented. Will contain one script per check, each failing loudly with a specific,
actionable message rather than a generic error:

- required ports free (6443, 80, 443, plus any declared in `platform/ingress/reserved-ports.yaml`)
- the node's own `/etc/resolv.conf` does not resolve through a service this cluster will host
- system clock within an acceptable skew of a reference time source
- cgroup v2 available
- sufficient free disk for images and initial platform state
- architecture is x86-64 or arm64

See `bootstrap/README.md` for how these compose into `install.sh`.
