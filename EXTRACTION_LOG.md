# AC/ — Economy & Currency Validation Extraction Log

> **SUPERSEDED — historical record.** The extracted reference copies this log
> describes (`AC/ClickGame/`, `AC/PSU/`, `AC/Shared/`) were unified into the
> canonical module set in `AC/Core/` and then removed (see `AC/STATUS.md` for
> per-concern decisions). The untouched originals remain in `ClickGame/` and
> `PSU/` at repo root; the source paths cited below still resolve there.

Extracted from `PSU/` and `ClickGame/`. Scope: server-authoritative rate
limiting, double-credit prevention, S2C transaction validation, and
anti-duplication for currency/inventory. Explicitly excludes FPS/raycast code,
UI/VFX, and genre-specific gameplay (aura rolling, pet hatching, click input
mechanics, Golden Cookie event content).

## Files created

### AC/ClickGame/

| File | Source | What it does |
|---|---|---|
| `RateLimiter.luau` | `ClickGame/src/Shared/Util/RateLimiter.luau` | Per-player, per-action call-count-per-window limiter. Verbatim. |
| `EconomyMath.luau` | `ClickGame/src/Shared/Util/EconomyMath.luau` | Server-side recompute of CPC, passive/sec, upgrade cost, milestone cupcake cost — the "never trust the client's number" core. Verbatim. |
| `ValidationSystem.luau` | `ClickGame/src/Server/Systems/ValidationSystem.luau` | Authoritative click→currency pipeline; single entry point for manual clicks and the Auto-Clicker gamepass. Contains the CPK accumulator fix (mod-based carry-forward, no delta-tracking against a stale total). Verbatim (Quest/Achievement calls left in-place, out of scope — see below). |
| `PurchaseSystem.luau` | `ClickGame/src/Server/Systems/PurchaseSystem.luau` | S2C upgrade purchase: re-derives cost + milestone cost server-side, atomic `DeductCurrency` check-then-write. Verbatim. |
| `ShopService.luau` | `ClickGame/src/Server/Systems/ShopService.luau` | Idempotent `MarketplaceService.ProcessReceipt` (persisted `processedReceipts` ledger) + gamepass grant dedup. Verbatim. |
| `ServerPassiveSystem.luau` | `ClickGame/src/Server/Systems/ServerPassiveSystem.luau` | Server-authoritative passive-income accrual; in-memory-only `lastAccrual` timestamp prevents rejoin double-credit and startup bursts. Verbatim. |
| `PlayerEffectsService.luau` | `ClickGame/src/Server/Systems/PlayerEffectsService.luau` | **Trimmed.** Kept: gamepass-ownership cache + `GetMultiplier` fail-safe (a MarketplaceService/pcall error never grants an effect — ownership only ever gets set to `true`, never defaults to it). **Removed:** `HasAutoClicker` + the auto-clicker `task.spawn` loop — that's the Auto-Clicker gamepass's simulated-click gameplay loop, not currency validation. |
| `DataService_CurrencyOps.luau` | `ClickGame/src/Server/Services/DataService.luau` | **Trimmed.** Kept: `AddCurrency`/`AddCupcake`/`DeductCurrency`/`DeductCupcake` + minimal `GetProfileData`/`Profiles` context — the atomic check-then-write choke point every economy system goes through. **Removed:** profile load/create, remote handlers (`GetPlayerData`/`GetBalance`), and the legacy-store migration. See "Flagged for review" below re: the migration code. |

### AC/PSU/

| File | Source | What it does |
|---|---|---|
| `ClickService_Economy.luau` | `PSU/src/Server/Services/ClickService.luau` | PSU's generalized descendant of RateLimiter+ValidationSystem+CPK-accumulator: inline token bucket (`Bucket` type, burst+refill), primary-currency crediting, and mod-based accumulator carry-forward for secondary-currency minting. Verbatim (LevelService/QuestService calls left in-place, out of scope). |
| `UpgradeService.luau` | `PSU/src/Server/Services/UpgradeService.luau` | Server-authoritative upgrade purchase: registry-derived cost/milestone gates, explicit NaN/Infinity rejection on computed cost before any balance check. Verbatim. |
| `MonetizationService.luau` | `PSU/src/Server/Services/MonetizationService.luau` | Idempotent `ProcessReceipt` (Currency/Item/VIP delivery, `PurchaseHistory` ledger), gamepass ownership cache with ProfileService fallback, and `BuyInGameItem` — a server-validated soft-currency purchase that recomputes price/balance from `StoreRegistry`, never the client. Verbatim. |
| `AntiExploitService_ClickValidation.luau` | `PSU/src/Server/Services/AntiExploitService.luau` | **Heavily trimmed.** Kept: token-bucket + rolling-window standard-deviation ("sigma") click-macro detection (`ValidateAction`) — flags near-identical click intervals (machine-perfect timing) independently of raw rate, a stronger anti-macro signal than a bare rate limiter. **Removed:** teleport detection, fly detection, R15 rig-type enforcement, `ValidateAlive`, `ValidateFireRate`, and the `RunService.Heartbeat`/`stateSyncEvent` wiring — all movement/combat anti-cheat, not economy. |

### AC/Shared/

| File | Source | What it does |
|---|---|---|
| `GuidClaimTicket.luau` | `ClickGame/src/Server/Systems/GoldenCookieService.luau` + `PSU/src/Server/Services/GoldenDropService.luau` | The GUID one-shot claim-validation shape common to both Golden Cookie/Drop implementations, factored out on its own: issue a GUID, delete it from the pending-set the instant it's claimed (before the expiry check), reject unknown/expired/reused GUIDs. Spawn cadence, reward-tier rolling, and descent timers are **not** included — those stay event content, per scope. See "Flagged for review" item 1 below for why this one was pulled out while the rest of both files was left alone. |

## Explicitly excluded (per scope, no ambiguity)

- `AC/` does **not** include `AntiExploitController.luau` (PSU client controller). Checked its full contents: it only drains the debug `S2C_AntiCheatStateSync` event with an empty callback to stop console-queue-exhaustion warnings. It contains no validation logic of any kind (economy or otherwise) — nothing to extract.
- FPS/weapon/raycast code (`WeaponService`, `WeaponController`, `ViewmodelController`, hit/headshot remotes).
- All UI controllers, VFX controllers/services, cosmetics.
- Genre gameplay: `AuraService`, `PetService`, `QuestService`, `AchievementService`, `LevelService`, `GoldenCookieService`/`GoldenDropService` reward/spawn logic, shop UI panels.
- `FeatureResolver`, `UpgradeRegistry`, `CommerceRegistry`, `StoreRegistry`, `Constants`, `Types`, `ProfileService` (the library itself) — generic config/registry/infra modules that economy code depends on but aren't themselves validation logic. Left as external `require`s in the extracted files; wire them to your own equivalents.

## Flagged for review (found relevant-looking, not extracted — your call)

1. **Resolved — extracted.** GUID-based "consume immediately" anti-duplication pattern, present in both `ClickGame/src/Server/Systems/GoldenCookieService.luau` (~line 78, "destroy cache to prevent double-claiming") and `PSU/src/Server/Services/GoldenDropService.luau` (`onClaim`, line 122, "consume immediately: double-claims impossible"). Pulled into `AC/Shared/GuidClaimTicket.luau` — just the claim-validation shape (issue GUID, delete from pending-set on claim, reject unknown/expired/reused), not the spawn cadence/reward-tier logic, which stays event content and was left in the source files.
2. **ClickGame's `DataService.migrateLegacyProfile`/`hasProgress`** (`ClickGame/src/Server/Services/DataService.luau`, lines 51-98): guards against clobbering a profile that already holds currency/cupcake progress when pulling a legacy save forward. It's data-loss-prevention adjacent to currency integrity, but it's really profile-lifecycle/migration logic, not a currency validation rule — left out of `DataService_CurrencyOps.luau`. Flagging in case you consider "never lose a player's currency on migration" in-scope for this folder.
3. **Asymmetry between the two codebases' DataService**: ClickGame's `DataService` centralizes currency mutation behind `AddCurrency`/`DeductCurrency` (single choke point, easy to audit). PSU's `DataService` has **no equivalent** — `ClickService`, `UpgradeService`, and `MonetizationService` all mutate `profile.Data.Currencies.*` directly and independently. Nothing broken today, but it's a structural gap relative to the pattern this whole extraction is trying to preserve; worth knowing if PSU's economy code gets touched again.
4. **`AntiExploitService.ValidateAction`/`ValidateFireRate` are not currently called by any economy service** in PSU (only referenced from `FrameworkTestRunner.server.luau`'s self-test). The click-macro detector exists and is tested but isn't wired into `ClickService.OnClickReward`. Flagging in case that integration was intended but never landed — extracting it here doesn't wire it up for you.
