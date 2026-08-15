#!/usr/bin/env bash
# Runs every structural CI assertion against the real repository tree.
#
# Used by .github/workflows/ci.yml, and safe to run locally:
#   python3 -m pip install pyyaml
#   bash tests/assertions/run_all.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CHECKS=(
  check_core_boundary
  check_app_addition_boundary
  check_image_pinning
  check_no_cert_in_apps
  check_reserved_ports
  check_instance_literals
  check_kustomization_dag
  check_helm_strict
)

FAIL=0
for check in "${CHECKS[@]}"; do
  echo "--- ${check} ---"
  python3 "${check}.py" || FAIL=1
  echo
done

if [ "$FAIL" -ne 0 ]; then
  echo "One or more structural assertions failed."
  exit 1
fi
echo "All structural assertions passed."
