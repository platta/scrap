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

echo "Installing k3s ${K3S_VERSION} (--disable=traefik)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --disable=traefik \
    --write-kubeconfig-mode=644

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
