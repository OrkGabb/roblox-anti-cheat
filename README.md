# AC — Roblox Anti-Cheat (beta)

Anti-cheat system for Roblox, still in development.

Right now it covers the economy side: rate limiting on click/action spam, macro
(timing) detection, a single choke point for all currency mutations, purchase and
receipt validation, gamepass ownership fail-safes, and anti-duplication claim
tickets. Movement/exploit detection (speed, teleport, fly, etc.) isn't in here yet.

- `Core/` — the actual modules, config-injected, drop into `ServerScriptService`
- `Core/README.md` — wiring guide
- `STATUS.md` — where each module's design decisions came from

## Editor setup

Install the **Luau LSP** VS Code extension (`JohnnyMorganz.luau-lsp`). The
repo's `.vscode/settings.json` binds `*.luau` to it and `default.project.json`
lets it generate a Rojo sourcemap for require resolution. Do NOT open these
files under the plain-Lua extension — a Lua 5.x parser does not know Luau
type syntax (`number?`, `export type`, `::`) and will report hundreds of
phantom syntax errors starting at the first type declaration.

Not production-ready yet. Treat everything here as subject to change.
