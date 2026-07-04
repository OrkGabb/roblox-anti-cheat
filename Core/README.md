# AC/Core — Economy Validation Layer

Server-authoritative currency/inventory integrity for any Roblox game:
rate limiting (token bucket + macro detection), one auditable choke point for
every currency mutation, server-side purchase validation, idempotent receipt
processing, anti-duplication claim tickets, and a fail-safe gamepass cache.

All modules are `--!strict`, dependency-free besides each other, and
config-injected — they never `require` your game's registries. Drop the folder
into `ServerScriptService` and wire your own data/config in through `Init`.

## Modules

| Module | Concern |
|---|---|
| `CurrencyLedger` | **The choke point.** Every credit is `Add`, every spend is `Deduct` (atomic check-then-write). NaN/Infinity/negative amounts rejected here, unbypassable. |
| `RateLimiter` | Reusable per-player token bucket (burst + sustained rate) with optional sigma-based macro detection (flags machine-*regular* timing, not just fast timing). |
| `ClickEconomy` | Click→currency pipeline: sanitized untrusted remote path and trusted server path share one payout/accumulator route. Mod-based carry-forward secondary minting (the double-credit-proof shape). |
| `PassiveAccrual` | Passive income with in-memory-only accrual clock — rejoin can never double-credit, profile-load lag never pays a startup burst. |
| `PurchaseValidator` | S2C upgrade purchases: cost/cap/milestone recomputed server-side from your registry, saved-level sanitization, ledger-only mutation. |
| `ReceiptProcessor` | Single idempotent `ProcessReceipt` owner: persisted PurchaseId ledger, mark-after-grant, in-flight guard against re-delivery mid-grant. |
| `GamepassCache` | O(1) ownership checks with the fail-safe-to-false pattern: a MarketplaceService error can never grant a paid effect. Optional persisted-history fallback. |
| `GuidClaimTicket` | One-shot GUID claim tickets: consumed on first sight, so double-claims/replays are structurally impossible. |

## Wiring (one server script)

```luau
local Core = ServerScriptService.Core -- this folder
local CurrencyLedger = require(Core.CurrencyLedger)
local ClickEconomy = require(Core.ClickEconomy)
local PassiveAccrual = require(Core.PassiveAccrual)
local PurchaseValidator = require(Core.PurchaseValidator)
local ReceiptProcessor = require(Core.ReceiptProcessor)
local GamepassCache = require(Core.GamepassCache)

-- 1) The choke point. getWallet returns your profile's currency table.
CurrencyLedger.Init({
	getWallet = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.Currencies
	end,
	onMutation = function(player, currency, delta, newBalance, reason)
		-- optional: analytics / audit log
	end,
})

-- 2) Gamepasses (fail-safe cache).
GamepassCache.Init({
	passes = { VIP = 12345678, Golden = 87654321 },
	getPersistedHistory = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.PurchaseHistory
	end,
})

-- 3) Clicks. Recompute payout from YOUR registry — never the client.
ClickEconomy.Init({
	getClickPower = function(player)
		return 1 + MyUpgrades.ComputeStat(player, "PerClick")
	end,
	getIncomeMultiplier = function(player)
		return GamepassCache.GetStackedMultiplier(player, { VIP = 2 })
	end,
	maxClickBurst = 30,
	clickRefillRate = 20,
	-- macroDetection = { onFlagged = ... }, -- ONLY if one remote call = one physical click
	secondaryMint = {
		currency = "Secondary",
		clicksPerMint = 50,
		getState = function(player)
			local profile = MyData.Profiles[player]
			return profile and profile.Data.ClickerState
		end,
	},
})
clickRemote.OnServerEvent:Connect(function(player, batch)
	ClickEconomy.ProcessClicks(player, batch)
end)
-- Auto-clicker gamepass loop calls ClickEconomy.CreditServerClicks(player, 1).

-- 4) Passive income (server truth; client tickers are prediction only).
PassiveAccrual.Init({
	getRates = function(player)
		return { Primary = MyUpgrades.ComputeStat(player, "Passive") }
	end,
})

-- 5) Upgrade purchases (client sends an id, nothing else).
PurchaseValidator.Init({
	getMaxLevel = function(id) return MyUpgrades.Defs[id] and MyUpgrades.Defs[id].MaxLevel end,
	getCost = function(id, level) return MyUpgrades.GetCost(id, level) end,
	getUpgrades = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.Upgrades
	end,
})
upgradeRemote.OnServerEvent:Connect(function(player, id)
	PurchaseValidator.TryPurchase(player, id)
end)
-- After each profile loads: PurchaseValidator.SanitizeOwned(player)

-- 6) Dev products (this is the game's ONLY ProcessReceipt assignment).
ReceiptProcessor.Init({
	getReceiptLedger = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.PurchaseHistory
	end,
	grant = function(player, productId)
		local product = MyProducts[productId]
		if not product then return false end -- Roblox retries until configured
		return CurrencyLedger.Add(player, product.currency, product.amount, "receipt")
	end,
})
```

## The one rule

**No service ever writes a currency field directly.** Everything —
clicks, passive, receipts, refunds, admin grants — goes through
`CurrencyLedger.Add`/`Deduct`. If you add a system that touches money,
it takes the ledger as its only write path.
