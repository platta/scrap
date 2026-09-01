# tests/fixtures/

`violations/` holds deliberately-broken, minimal repository trees — one per structural check in
`tests/assertions/` — each violating exactly the rule that check exists to catch.

`valid/` holds deliberately-correct, minimal repository trees for a supported path that's easy to
get wrong silently — used where the real repository tree alone doesn't exercise it (for example,
an app-owned P4 port declaration with no `platform/` directory present at all, proving Topology B
behaves as designed). A check with no fixture proving the supported path passes is only proven not
to false-positive on the *real* repository's own shape, not on every shape it's meant to accept.

`tests/assertions/self_test.py` runs every check against its dedicated `violations/` fixture and
asserts the check *fails* (finds the violation), runs any relevant check against its `valid/`
fixture and asserts it *passes*, then runs every check against the real repository tree and
asserts it *passes* too. A check with no fixture proving it fires is not a trustworthy guardrail —
it's an assertion nobody has verified actually asserts anything.

Do not "fix" anything under `violations/` — breaking it is the entire point. `valid/` fixtures, by
contrast, must stay genuinely valid — that's their entire point.
