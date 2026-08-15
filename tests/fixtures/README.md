# tests/fixtures/

`violations/` holds deliberately-broken, minimal repository trees — one per structural check in
`tests/assertions/` — each violating exactly the rule that check exists to catch.

`tests/assertions/self_test.py` runs every check against its dedicated fixture and asserts the
check *fails* (finds the violation), then runs every check against the real repository tree and
asserts it *passes*. A check with no fixture proving it fires is not a trustworthy guardrail — it's
an assertion nobody has verified actually asserts anything.

Do not "fix" anything under `violations/` — breaking it is the entire point.
