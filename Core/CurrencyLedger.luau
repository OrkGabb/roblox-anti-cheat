--!strict
-- @Author @OrkGabb
-- AC/Core/CurrencyLedger.luau
--
-- THE single choke point for every currency mutation. No service may write a
-- currency field directly — all credits go through Add and all spends through
-- Deduct, so auditing the economy means auditing this one file (plus grepping
-- that nothing else touches the wallet table).
--
-- This generalizes ClickGame DataService's AddCurrency/DeductCurrency shape
-- (single audit point, atomic check-then-write) to named currencies. The PSU
-- codebase had no equivalent — ClickService, UpgradeService, and
-- MonetizationService each mutated profile.Data.Currencies.* directly and
-- independently, which is exactly the structural gap this module closes.
--
-- Guards that live HERE, not in callers:
--   * NaN / Infinity / negative-amount rejection. Generalized from PSU
--     UpgradeService's overflow hardening ("cost ~= cost or cost == math.huge
--     or cost < 0"). One NaN reaching a balance poisons every later `>=`
--     comparison against it (NaN compares false to everything), silently
--     breaking all subsequent purchase validation — so the rejection belongs
--     at the choke point where no caller can bypass it.
--   * Atomic spend: Deduct checks and writes in one non-yielding function.
--     There is no separate read-balance-then-write window for another request
--     to interleave into (Luau tasks only switch at yields).
--   * Corrupt STORED balance rejection. Validating only the amount is not
--     enough: a NaN already sitting in the wallet (tampered/legacy save, or a
--     direct write that bypassed the ledger before this module was adopted)
--     makes `balance < amount` false for EVERY amount — every Deduct would
--     succeed, which is unlimited free purchases. A non-finite/negative/
--     non-number stored balance therefore fails the mutation (and reads as 0
--     from Get, so no caller's comparison math is poisoned either).
--   * Overflow rejection: a credit that would push the balance to Infinity is
--     refused instead of written.
--   * Contained wallet-layer rejection. The wallet returned by getWallet may
--     be a validating proxy (MatrixGuard) that raises on an illegal write.
--     The write is pcall-contained here so a rejection reads as a failed
--     mutation (return false) — never phantom success, and never an unwound
--     Heartbeat loop that starves every player iterated after the rejected
--     one (PassiveAccrual credits inside such a loop).

local Contract = require(script.Parent.Contract)

local CurrencyLedger = {}

export type MutationHook = (player: Player, currency: string, delta: number, newBalance: number, reason: string) -> ()

export type Config = {
	-- Returns the player's mutable currency table (e.g. profile.Data.Currencies),
	-- or nil while the profile is not loaded. Missing keys are treated as 0.
	getWallet: (player: Player) -> { [string]: number }?,
	-- Optional audit hook, called after every successful mutation. Wire your
	-- analytics / anti-cheat logging here and every credit and spend in the
	-- game flows through it.
	onMutation: MutationHook?,
}

local _config: Config? = nil

local function getConfig(): Config
	local config = _config
	if not config then
		error("[CurrencyLedger] Init() must be called before use", 3)
	end
	return config
end

-- Amounts must be finite and non-negative. Callers express direction by
-- choosing Add vs Deduct, never by sign — a negative Add is a spend that
-- skipped the balance check, so it is rejected.
local function isValidAmount(amount: number): boolean
	return typeof(amount) == "number" and amount == amount and amount < math.huge and amount >= 0
end

-- Raw write, isolated so it can be pcall-contained without a per-call closure:
-- a validating wallet proxy (MatrixGuard) raises on an illegal write, and that
-- rejection must become `false` from Add/Deduct, not an error unwinding the
-- caller's crediting loop.
local function writeBalance(wallet: { [string]: number }, currency: string, value: number): ()
	wallet[currency] = value
end

-- The stored config is a guarded copy — the integrator's table is never
-- mutated. getWallet and onMutation both run inside the atomic mutation path,
-- so both carry the non-yielding contract (see Contract.luau); a violating
-- callback is contained and the mutation fails closed.
--
-- One-shot by design: the module table is frozen and Init refuses a second
-- call, so runtime code can never re-point getWallet at an unguarded wallet
-- or swap the audit hook after boot.
function CurrencyLedger.Init(config: Config): ()
	if _config then
		error("[CurrencyLedger] Init() may only be called once", 2)
	end
	_config = {
		getWallet = Contract.NonYielding("CurrencyLedger.getWallet", config.getWallet),
		onMutation = Contract.NonYieldingOpt("CurrencyLedger.onMutation", config.onMutation),
	}
end

function CurrencyLedger.Get(player: Player, currency: string): number
	local wallet = getConfig().getWallet(player)
	if not wallet then
		return 0
	end
	local balance = wallet[currency] or 0
	-- Corrupt stored balance reads as 0 (see header): a NaN returned here
	-- would poison every caller-side `>=` affordability check.
	if not isValidAmount(balance) then
		return 0
	end
	return balance
end

-- Credits `amount` of `currency`. Returns false (and mutates nothing) if the
-- profile is unavailable or the amount is invalid. `reason` is a short audit
-- tag ("click", "passive", "receipt:12345", ...) passed to onMutation.
function CurrencyLedger.Add(player: Player, currency: string, amount: number, reason: string?): boolean
	local config = getConfig()
	if not isValidAmount(amount) then
		warn(string.format(
			"[CurrencyLedger] Rejected Add of %s %s for %s (%s)",
			tostring(amount),
			currency,
			player.Name,
			reason or "?"
		))
		return false
	end

	local wallet = config.getWallet(player)
	if not wallet then
		return false
	end

	local balance = wallet[currency] or 0
	if not isValidAmount(balance) then
		warn(string.format(
			"[CurrencyLedger] %s.%s stored balance is corrupt (%s) — Add rejected (%s)",
			player.Name,
			currency,
			tostring(balance),
			reason or "?"
		))
		return false
	end

	local newBalance = balance + amount
	if newBalance >= math.huge then
		warn(string.format(
			"[CurrencyLedger] Add of %.6g %s for %s overflows the balance — rejected (%s)",
			amount,
			currency,
			player.Name,
			reason or "?"
		))
		return false
	end

	-- Cast: pcall's typed overload models only the success returns of a
	-- () -> () function; the error value on the failure path needs ...any.
	local okWrite, writeErr = pcall(writeBalance :: any, wallet, currency, newBalance)
	if not okWrite then
		warn(string.format(
			"[CurrencyLedger] wallet layer rejected Add for %s.%s: %s",
			player.Name,
			currency,
			tostring(writeErr)
		))
		return false
	end
	if config.onMutation then
		config.onMutation(player, currency, amount, newBalance, reason or "add")
	end
	return true
end

-- Spends `amount` of `currency` if — and only if — the balance covers it.
-- Check and write happen in this single non-yielding call: no caller-side
-- balance check can race against the deduction.
function CurrencyLedger.Deduct(player: Player, currency: string, amount: number, reason: string?): boolean
	local config = getConfig()
	if not isValidAmount(amount) then
		warn(string.format(
			"[CurrencyLedger] Rejected Deduct of %s %s for %s (%s)",
			tostring(amount),
			currency,
			player.Name,
			reason or "?"
		))
		return false
	end

	local wallet = config.getWallet(player)
	if not wallet then
		return false
	end

	local balance = wallet[currency] or 0
	-- A corrupt stored balance MUST fail here, not fall through: NaN compares
	-- false to everything, so `balance < amount` below would approve every
	-- spend against a NaN balance — unlimited free purchases (see header).
	if not isValidAmount(balance) then
		warn(string.format(
			"[CurrencyLedger] %s.%s stored balance is corrupt (%s) — Deduct rejected (%s)",
			player.Name,
			currency,
			tostring(balance),
			reason or "?"
		))
		return false
	end
	if balance < amount then
		return false
	end

	local newBalance = balance - amount
	-- Cast: pcall's typed overload models only the success returns of a
	-- () -> () function; the error value on the failure path needs ...any.
	local okWrite, writeErr = pcall(writeBalance :: any, wallet, currency, newBalance)
	if not okWrite then
		warn(string.format(
			"[CurrencyLedger] wallet layer rejected Deduct for %s.%s: %s",
			player.Name,
			currency,
			tostring(writeErr)
		))
		return false
	end
	if config.onMutation then
		config.onMutation(player, currency, -amount, newBalance, reason or "deduct")
	end
	return true
end

return CurrencyLedger
