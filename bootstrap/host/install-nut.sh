#!/bin/sh
# Installs and arms host-level NUT (Network UPS Tools): upsd + upsmon, with
# upsmon's own SHUTDOWNCMD holding the authority to power off this node on
# sustained low battery. Decided in docs/decisions/0013-ups-shutdown-authority.md:
# this lives outside anything Flux reconciles, delivered by an operator-run
# script in exactly the shape install-k3s.sh already established -- a
# one-shot script that installs a persistent, distro-packaged systemd
# service. Refuses to run if NUT already looks active on this host, the
# same "don't silently reinstall over a running thing" stance
# install-k3s.sh takes for k3s.
#
# This script owns the HOST half only. The in-cluster half (metrics +
# alerting over upsd's own read-only TCP protocol) is a normal capability,
# enabled the normal Kustomization-copy way -- see capabilities/ups/README.md.
#
# Required env:
#   NUT_UPS_NAME       -- short name for the UPS, e.g. "ups". Used in
#                          ups.conf's [section] and by every NUT client
#                          (upsc, upsmon, this capability's exporter) to
#                          address it.
#   NUT_DRIVER         -- the NUT driver binary, e.g. "usbhid-ups" for the
#                          overwhelming majority of USB UPS models (NUT's
#                          own hardware-compatibility list documents which
#                          driver a specific model needs), or "dummy-ups"
#                          for the simulated device tests/profiles/t-a-ups.sh
#                          uses in CI -- never a default: guessing a driver
#                          for hardware this script has never seen is worse
#                          than requiring the operator name it, the same
#                          reasoning capabilities/dyndns/README.md gives for
#                          not defaulting DYNDNS_IP_LOOKUP_URL.
#   NUT_PORT           -- the driver's own "port" value in ups.conf: a
#                          device node (e.g. "auto" for usbhid-ups, which
#                          scans for the first matching USB device) or,
#                          for dummy-ups, a path to its own data file.
#
# Optional env:
#   NUT_MONITOR_PASSWORD  -- password for the "upsmon" primary-monitor NUT
#                             user (upsd.users), which grants upsmon the
#                             authority to log in and receive FSD (forced
#                             shutdown) broadcasts. Generated with
#                             /dev/urandom if unset -- this password never
#                             leaves the host (upsmon.conf and upsd.users
#                             are both root:nut, mode 640, read by nothing
#                             outside this host).
#   NUT_READONLY_USER      -- NUT user for the in-cluster capability's own
#                              read-only client. Default "k8s-monitor" --
#                              must match clusters/<name>/secrets/ups/'s
#                              NUT_USERNAME.
#   NUT_READONLY_PASSWORD  -- password for NUT_READONLY_USER. Required if
#                              NUT_READONLY_USER is used for anything (this
#                              script fails loudly, not silently, if unset
#                              and no existing upsd.users entry already has
#                              one) -- must match clusters/<name>/secrets/ups/'s
#                              NUT_PASSWORD.
#   NUT_SHUTDOWNCMD        -- the command upsmon runs when it decides the
#                              host must power off (sustained "on battery,
#                              low battery" from every monitored UPS, or an
#                              FSD broadcast with nothing to override it).
#                              Defaults to a real, orderly poweroff --
#                              "/sbin/shutdown -h +0" -- the clean-shutdown
#                              path ADR-0013 requires so stateful workloads
#                              get their normal termination window.
#                              tests/profiles/t-a-ups.sh overrides this to a
#                              sentinel-file write instead of a real
#                              poweroff, precisely so CI can observe the
#                              trigger path fire without actually powering
#                              off the runner -- see that script's own
#                              comment.
#   NUT_LISTEN_ADDRESS     -- the address upsd's LISTEN directive binds.
#                              Defaults to 0.0.0.0 (every interface) so the
#                              in-cluster capability, running as a pod
#                              reaching this host over its LAN address
#                              (instance-config.yaml's NODE_ADDRESS), can
#                              connect -- this host's own firewall, not
#                              anything SCRAP configures, is the real
#                              boundary here (docs/out-of-scope/README.md's
#                              "general host management beyond bootstrap/").
#                              A single-host LAN-only deployment (no
#                              capabilities/public-ingress/) never exposes
#                              this port to anything but the LAN regardless.
set -eu

: "${NUT_UPS_NAME:?NUT_UPS_NAME is required, e.g. NUT_UPS_NAME=ups}"
: "${NUT_DRIVER:?NUT_DRIVER is required, e.g. NUT_DRIVER=usbhid-ups (real hardware) or dummy-ups (testing)}"
: "${NUT_PORT:?NUT_PORT is required -- the driver's own device/port value, e.g. NUT_PORT=auto for usbhid-ups}"

NUT_READONLY_USER="${NUT_READONLY_USER:-k8s-monitor}"
NUT_SHUTDOWNCMD="${NUT_SHUTDOWNCMD:-/sbin/shutdown -h +0}"
NUT_LISTEN_ADDRESS="${NUT_LISTEN_ADDRESS:-0.0.0.0}"

if [ -z "${NUT_READONLY_PASSWORD:-}" ]; then
    echo "NUT_READONLY_PASSWORD is required -- the in-cluster capability's own read-only NUT"
    echo "user needs a real password, matching clusters/<name>/secrets/ups/'s NUT_PASSWORD."
    exit 1
fi

if systemctl is-active --quiet nut-server 2>/dev/null || systemctl is-active --quiet nut-monitor 2>/dev/null; then
    echo "NUT (nut-server or nut-monitor) is already active on this host -- refusing to"
    echo "reconfigure over a running install. Run uninstall-nut.sh first if you intend to"
    echo "rebuild its configuration from scratch."
    exit 1
fi

if [ -z "${NUT_MONITOR_PASSWORD:-}" ]; then
    NUT_MONITOR_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
    echo "NUT_MONITOR_PASSWORD not set -- generated a random one for upsmon's own primary-monitor login."
fi

echo "Installing NUT (Network UPS Tools)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nut

echo "Writing /etc/nut/nut.conf (MODE=netserver -- this host serves upsd to the LAN, not just itself)..."
cat >/etc/nut/nut.conf <<EOF
MODE=netserver
EOF

echo "Writing /etc/nut/ups.conf..."
cat >/etc/nut/ups.conf <<EOF
[${NUT_UPS_NAME}]
    driver = ${NUT_DRIVER}
    port = ${NUT_PORT}
    desc = "SCRAP-managed UPS (bootstrap/host/install-nut.sh)"
EOF

echo "Writing /etc/nut/upsd.conf (LISTEN ${NUT_LISTEN_ADDRESS} 3493)..."
cat >/etc/nut/upsd.conf <<EOF
LISTEN ${NUT_LISTEN_ADDRESS} 3493
EOF

echo "Writing /etc/nut/upsd.users..."
# Two distinct users, two distinct privilege levels -- ADR-0013's own
# "no SCRAP-shipped workload ever holds host power authority" is enforced
# structurally here, not just by convention: [monitor] is the only user
# with "upsmon primary" (FSD-eligible, the privilege that lets upsmon
# itself decide to shut the host down); [${NUT_READONLY_USER}] has a
# password and nothing else -- it can LOGIN and read (LIST VAR/GET VAR),
# never receive FSD, never SET VAR, never INSTCMD. This is the "read-only
# NUT user" docs/decisions/0013's own text names for the in-cluster half.
cat >/etc/nut/upsd.users <<EOF
[monitor]
    password = ${NUT_MONITOR_PASSWORD}
    upsmon primary

[${NUT_READONLY_USER}]
    password = ${NUT_READONLY_PASSWORD}
EOF

echo "Writing /etc/nut/upsmon.conf..."
cat >/etc/nut/upsmon.conf <<EOF
MONITOR ${NUT_UPS_NAME}@localhost 1 monitor ${NUT_MONITOR_PASSWORD} primary
MINSUPPLIES 1
SHUTDOWNCMD "${NUT_SHUTDOWNCMD}"
NOTIFYCMD /etc/nut/notify.sh
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
NOTIFYFLAG ONLINE    SYSLOG+EXEC
NOTIFYFLAG ONBATT    SYSLOG+EXEC
NOTIFYFLAG LOWBATT   SYSLOG+EXEC
NOTIFYFLAG FSD       SYSLOG+EXEC
NOTIFYFLAG COMMOK    SYSLOG+EXEC
NOTIFYFLAG COMMBAD   SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN  SYSLOG+EXEC
EOF

# A minimal NOTIFYCMD -- upsmon calls it with the notify-type as $1 (also
# NOTIFYTYPE in the environment) and the full message on stdin's own
# argv already passed by upsmon; the syslog tag is what
# tests/profiles/t-a-ups.sh's own negative/positive checks read to confirm
# state transitions happened, independent of whether SHUTDOWNCMD itself
# fired (SHUTDOWNCMD only fires once, at the end of a sustained
# on-battery+low-battery condition -- the individual ONBATT/LOWBATT
# transitions are real, independently observable events on their own).
cat >/etc/nut/notify.sh <<'EOF'
#!/bin/sh
logger -t scrap-nut-notify "$*"
EOF
chmod 755 /etc/nut/notify.sh

echo "Setting NUT config ownership/permissions (upsd.users and upsmon.conf hold passwords)..."
chown root:nut /etc/nut/nut.conf /etc/nut/ups.conf /etc/nut/upsd.conf /etc/nut/upsd.users /etc/nut/upsmon.conf
chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
chmod 644 /etc/nut/nut.conf /etc/nut/ups.conf /etc/nut/upsd.conf

echo "Starting the ${NUT_UPS_NAME} driver..."
/usr/sbin/upsdrvctl start "${NUT_UPS_NAME}"

echo "Enabling and starting nut-server (upsd) and nut-monitor (upsmon)..."
systemctl enable --now nut-server nut-monitor
# Best-effort: modern Debian/Ubuntu packaging also ships a udev/enumerator
# path unit that re-starts driver instances on boot by reading ups.conf --
# arm it if present, but don't fail this script if this exact unit name
# isn't shipped by the installed package version; upsdrvctl start above is
# what actually proves the driver runs, right now, verified below.
systemctl enable nut-driver-enumerator.service 2>/dev/null || true

echo "Waiting for upsd to report ${NUT_UPS_NAME} status..."
i=0
while [ "$i" -lt 30 ]; do
    if upsc "${NUT_UPS_NAME}@localhost" ups.status >/dev/null 2>&1; then
        echo "ok: upsd is serving ${NUT_UPS_NAME}."
        upsc "${NUT_UPS_NAME}@localhost"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

echo "NUT did not report ${NUT_UPS_NAME} status within the expected window -- check"
echo "'systemctl status nut-server nut-monitor', 'journalctl -u nut-server -u nut-monitor',"
echo "and 'upsdrvctl start ${NUT_UPS_NAME}' output above for details."
exit 1
