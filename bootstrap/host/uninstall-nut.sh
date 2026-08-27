#!/bin/sh
# The documented disable/uninstall path for install-nut.sh --
# docs/decisions/0013-ups-shutdown-authority.md's own text: "the host half
# is enabled by running its bootstrap/host/ script and disabled by its
# documented uninstall path". Stops and disables both services, stops the
# driver, and removes the config this project wrote -- never touches
# /etc/nut/ if NUT was never installed by this script, and leaves the
# `nut` package itself installed (uninstalling a distro package is the
# operator's own call, same reasoning install-k3s.sh's own
# k3s-uninstall.sh pointer leaves the choice to the operator rather than
# silently purging).
set -eu

NUT_UPS_NAME="${NUT_UPS_NAME:-}"

echo "Stopping nut-monitor and nut-server..."
systemctl disable --now nut-monitor 2>/dev/null || true
systemctl disable --now nut-server 2>/dev/null || true
systemctl disable nut-driver-enumerator.service 2>/dev/null || true

if [ -n "$NUT_UPS_NAME" ]; then
    echo "Stopping the ${NUT_UPS_NAME} driver..."
    /usr/sbin/upsdrvctl stop "${NUT_UPS_NAME}" 2>/dev/null || true
else
    echo "NUT_UPS_NAME not set -- stopping every configured driver instead."
    /usr/sbin/upsdrvctl stop 2>/dev/null || true
fi

echo "Removing SCRAP-written config (/etc/nut/{nut.conf,ups.conf,upsd.conf,upsd.users,upsmon.conf,notify.sh})..."
rm -f /etc/nut/nut.conf /etc/nut/ups.conf /etc/nut/upsd.conf /etc/nut/upsd.users /etc/nut/upsmon.conf /etc/nut/notify.sh

echo "Host-level NUT disabled. The 'nut' package itself is left installed --"
echo "'sudo apt remove nut' if you want it fully gone."
