#!/bin/sh
# Deliberately-broken fixture for tests/assertions/check_dr_quiesce_ordering.py:
# the restic restore runs BEFORE the application tier is scaled to zero --
# exactly the ordering bug docs/runbooks/README.md documents finding live
# (leaving server/worker running while Postgres was reloaded corrupted
# Django's migration bookkeeping). The statefulset scale-to-zero is
# missing entirely.
set -eu

cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: restore
spec:
  template:
    spec:
      containers:
        - name: restore
          command: ["sh", "-c", "restic restore latest --host=x --path=/hostdata --target=/"]
EOF

for d in authentik-server authentik-worker; do
    kc scale -n authentik "deployment/$d" --replicas=0
done
