# Security policy

SCRAP terminates TLS for every application it fronts and, when the identity capability is
enabled, runs a single sign-on provider other applications trust. A security defect here can
affect every application and user behind an install, not just SCRAP itself — treat it
accordingly when reporting.

## Reporting a vulnerability

**Do not open a public GitHub issue for a security-sensitive report.** Use GitHub's private
vulnerability reporting instead: [Report a vulnerability](https://github.com/platta/scrap/security/advisories/new).

This keeps the report visible only to the maintainer until a fix is available. If that option
doesn't appear on the repository for you, it means private vulnerability reporting hasn't been
enabled yet — please still avoid a public issue; open a normal issue that says only "I have a
security report and can't reach the private channel," with no technical detail, and the
maintainer will follow up with a private way to reach you.

This applies in particular to:

- credential or secret exposure (including in example/reference configuration you believe is
  reachable in a real install, not just the intentionally-public reference values under
  `clusters/example/`);
- authentication or authorization bypass, including anything touching the identity/SSO or
  forward-auth capabilities;
- a way to reach the platform or an application from outside its intended network exposure.

## What isn't a security report

A capability that's merely undocumented, a confusing error message, or a bug that doesn't cross
a trust boundary is an ordinary [bug report](https://github.com/platta/scrap/issues/new/choose) —
filing it publicly is fine and preferred, since it's the same channel everything else uses.
