# AC — Roblox Anti-Cheat (beta)

Anti-cheat system for Roblox, still in development.

Right now it covers the economy side: rate limiting on click/action spam, macro
(timing) detection, a single choke point for all currency mutations, purchase and
receipt validation, gamepass ownership fail-safes, and anti-duplication claim
tickets. Movement/exploit detection (speed, teleport, fly, etc.) isn't in here yet.

- `Core/` — the actual modules, config-injected, drop into `ServerScriptService`
- `Core/README.md` — wiring guide
- `STATUS.md` — where each module's design decisions came from
- `EXTRACTION_LOG.md` — history of what was pulled from earlier projects and why

Not production-ready yet. Treat everything here as subject to change.
