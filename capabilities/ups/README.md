# capabilities/ups/

**FULLY SUPPORTED.** No dependency on other capabilities.

NUT (Network UPS Tools) integration for graceful shutdown on power loss — real corruption
protection for stateful applications with local-disk databases, which is most of what SCRAP hosts.
An unclean shutdown is a realistic and previously-observed failure mode for a single-node,
single-disk install.

## New assumptions this introduces

A UPS with a data connection to the host (USB or network). No cloud dependency.
