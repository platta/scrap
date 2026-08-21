#!/bin/sh
# Installs a pinned k3s server. --disable=traefik is load-bearing: SCRAP
# manages its own Traefik via Flux (platform/ingress/), and k3s bundling a
# second, un-GitOps'd Traefik would mean two reconcilers fighting over the
# same Gateway API resources. See platform/ingress/README.md.
#
# Version pinned exactly, matching platform/ingress/'s own Kubernetes
# assumptions -- verified against this exact version during this
# repository's own scratch validation, not a guess.
set -eu

K3S_VERSION="${K3S_VERSION:-v1.36.3+k3s1}"

if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "k3s is already active on this host -- refusing to reinstall over a running cluster."
    echo "If you intend to rebuild from scratch, uninstall first: sudo /usr/local/bin/k3s-uninstall.sh"
    exit 1
fi

# REAL SECURITY DEFECT, found via an independent review, confirmed by
# direct inspection: this line USED to also pass
# --write-kubeconfig-mode=644, making /etc/rancher/k3s/k3s.yaml -- a
# credential granting full cluster-admin access -- world-READABLE on
# this host, with no comment or reasoning given for why. Checked every
# place this file is actually read: bootstrap/install.sh and
# bootstrap/postflight.sh both run entirely as root (every caller
# invokes install.sh under `sudo`), and tests/profiles/lib.sh's own
# setup_kubeconfig() reads it via `sudo cp` -- root, either way. Nothing
# in this codebase ever needs a non-root, unprivileged read of this
# specific file; the loosened mode served no purpose here and directly
# contradicted lib.sh's own comment describing this file as "(0600,
# root-owned)". Removed -- k3s's own default (600, root-only) is what
# every caller already assumes and is now what's actually true.
echo "Installing k3s ${K3S_VERSION} (--disable=traefik)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --disable=traefik

echo "Waiting for the node to report Ready..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 30); do
    if kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
        echo "Node Ready."
        kubectl get nodes -o wide
        exit 0
    fi
    sleep 2
done

echo "Node did not report Ready within the expected window -- check 'kubectl get nodes' and"
echo "'journalctl -u k3s' for details."
exit 1
