#!/usr/bin/env python3
"""
${TLS_ISSUER} -- the instance-config value platform/ingress/wildcard-
certificate.yaml's issuerRef uses to select which ClusterIssuer produces
the one wildcard certificate (capabilities/public-tls/'s ACME issuers, or
platform/cert-manager-config/'s private CA) -- must never be referenced
anywhere under apps/.

This is the precise, mechanical form of the frozen architecture's own CI
obligation: "swapping the ClusterIssuer changes no file under apps/."
Flux's postBuild.substituteFrom is a repository-wide, dumb ${VAR} token
substitution -- it does not know or care what an application is; it
substitutes ${TLS_ISSUER} wherever the literal token appears, full stop.
Given that mechanism, "no file under apps/ changes when TLS_ISSUER's
value changes" is exactly equivalent to "the token never occurs under
apps/ in the first place" -- there's nothing there for a changed value to
substitute into. A live build-twice-and-diff test would prove nothing
this check doesn't already prove, given how substitution actually works;
this is the honest, minimal form of the same claim.

Deliberately checked separately from check_no_cert_in_apps.py: that check
proves no app declares its OWN issuer reference (a Certificate, a
ClusterIssuer, an issuerRef field) -- a structural claim about what kind
of object exists. This one proves no app is even TEXTUALLY coupled to
which issuer the PLATFORM happens to be using -- a narrower, config-level
claim that would survive even if some future, legitimate reason existed
for an app to mention issuers in general.
"""
from __future__ import annotations

import sys
from pathlib import Path

from common import find_repo_root, iter_yaml_files, rel

TOKEN = "${TLS_ISSUER}"


def run(root: Path) -> list[str]:
    violations: list[str] = []
    for path in iter_yaml_files(root, "apps"):
        for lineno, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
            if TOKEN in line:
                violations.append(
                    f"{rel(root, path)}:{lineno}: ${{TLS_ISSUER}} referenced under apps/ -- "
                    "applications must never be coupled to which issuer the platform is using "
                    "(docs/decisions/0006-tls-wildcard-and-issuer-independence.md)"
                )
    return violations


if __name__ == "__main__":
    root = find_repo_root()
    violations = run(root)
    if violations:
        print("FAIL: check_tls_issuer_not_in_apps")
        for v in violations:
            print(f"  - {v}")
        sys.exit(1)
    print("PASS: check_tls_issuer_not_in_apps")
