--!strict
-- @Author @OrkGabb
-- AC/Core/MatrixGuard.luau
--
-- Standalone economic-invariant layer: a mathematical hard ceiling on wealth
-- creation that holds even if every validation module above it is bypassed,
-- buggy, or misconfigured. It requires nothing from the rest of Core and the
-- rest of Core requires nothing from it — wiring is one call at the wallet
-- boundary, and the guarantees are pure numeric caps, not gameplay policy.
--
-- Threat model: NOT the exploiter's client (server modules already own that),
-- but the server's own code — a payout formula fed a corrupt saved level, a
-- multiplier stack that overflows, a new feature that writes the wallet
-- directly and skips the ledger. Whatever the source, illegitimate wealth
-- ultimately materializes as a WRITE to the wallet table, so that write is
-- where the last line of defense lives.
--
-- WrapWallet(player, realTable) returns a proxy standing in for the wallet.
-- Reads/iteration pass straight through; every WRITE is validated against
-- the frozen boot-time caps before it lands in the real table:
--
--   * type gate — non-number, NaN, Infinity, or negative balances never land;
--   * unknown currency — a key with no cap entry (and no "*" default) is
--     rejected: fail-closed, a currency nobody budgeted for has no business
--     appearing (a misconfiguration surfaces in testing instead of shipping
--     uncapped);
--   * gain budget — a per-currency token bucket refilled at
--     maxGainPerMinute/60. Over ANY window of T seconds, accepted gains
--     provably total <= maxGainBurst + rate*T, regardless of how many code
--     paths credit or how fast: an absolute cap per unit time, independent
--     of click power, multipliers, or bugs upstream;
--   * delta envelope — a single gain more than ENVELOPE_FACTOR (10x) the
--     largest previously accepted gain this session (seeded by
--     maxExpectedDelta) HALTS the transaction and journals it for manual
--     reconciliation. Legit economies grow smoothly; a 10x step is a
--     formula gone wrong;
--   * absolute balance ceiling (maxBalance).
--
-- Spends (delta <= 0) bypass the gain machinery — losing money is never an
-- inflation event — but still pass the type gate, so a spend can't write NaN
-- or a negative balance either.
--
-- FAIL CLOSED, twice over: a rejected write raises an error instead of
-- silently dropping — the calling transaction aborts loudly and can never
-- report phantom success over a write that didn't land. And the validator
-- itself runs under pcall: if MatrixGuard's own logic ever errors, the write
-- is rejected, never waved through.
--
-- Immutable by construction: Init deep-copies the caps and table.freeze's
-- every level plus this module itself. There are no setters; changing a cap
-- means changing the boot config and restarting — an exploited server thread
-- cannot loosen the ceiling at runtime.
--
-- Wire it by wrapping what getWallet RETURNS — never assign the proxy into
-- profile.Data (it must not be serialized):
--
--   local proxies: { [Player]: any } = {}
--   CurrencyLedger.Init({
--       getWallet = function(player)
--           local profile = MyData.Profiles[player]
--           if not profile then return nil end
--           local proxy = proxies[player]
--           if not proxy then
--               proxy = MatrixGuard.WrapWallet(player, profile.Data.Currencies)
--               proxies[player] = proxy
--           end
--           return proxy
--       end,
--   })
--   -- and clear proxies[player] on PlayerRemoving.
--
-- Luau iteration caveat: `pairs(proxy)` bypasses metamethods and sees an
-- EMPTY table. Iterate the wallet with generalized iteration
-- (`for currency, balance in wallet do`), which the proxy supports via
-- __iter, or read single balances via CurrencyLedger.Get. Serialization code
-- must keep operating on the REAL table (which it already does if the proxy
-- was never assigned into profile.Data, per the wiring above).

local MatrixGuard = {}

local ENVELOPE_FACTOR = 10
local JOURNAL_LIMIT = 200

export type CurrencyCaps = {
	-- Hard ceiling on accepted gains per minute (token-bucket rate). The one
	-- required field: without it there is no cap and no reason to wrap.
	maxGainPerMinute: number,
	-- Bucket capacity: the most gain acceptable "at once" after idle time.
	-- Default maxGainPerMinute / 4.
	maxGainBurst: number?,
	-- Seed for the delta envelope: the largest single legitimate credit you
	-- expect (biggest dev product, jackpot, offline payout). Default
	-- maxGainPerMinute / 4. A single gain > 10x the running maximum halts.
	maxExpectedDelta: number?,
	-- Absolute balance ceiling. Default math.huge (envelope/budget still apply).
	maxBalance: number?,
}

export type ViolationRecord = {
	playerName: string,
	userId: number,
	currency: string,
	rule: string, -- "type" | "unknown-currency" | "gain-budget" | "delta-envelope" | "max-balance" | "guard-error"
	attempted: number?, -- attempted new balance (nil for non-number writes)
	balance: number, -- balance at decision time (unchanged by the rejection)
	detail: string,
	at: number, -- os.clock()
}

export type Config = {
	-- Per-currency caps, "*" as the default for currencies without their own
	-- entry. A currency matching neither is rejected outright (fail-closed).
	caps: { [string]: CurrencyCaps },
	-- Observational only: called (in its own task) AFTER a violation has
	-- already been rejected and journaled. It cannot overturn the decision.
	onViolation: ((record: ViolationRecord) -> ())?,
}

type BudgetState = {
	tokens: number,
	lastRefill: number,
	sessionMaxDelta: number,
}

local _caps: { [string]: CurrencyCaps }? = nil
local _onViolation: ((record: ViolationRecord) -> ())? = nil

-- Bounded ring of recent violations for manual reconciliation.
local journal: { ViolationRecord } = {}
local journalNext = 1

local function record(player: Player, currency: string, rule: string, attempted: number?, balance: number, detail: string): ()
	local entry: ViolationRecord = {
		playerName = player.Name,
		userId = player.UserId,
		currency = currency,
		rule = rule,
		attempted = attempted,
		balance = balance,
		detail = detail,
		at = os.clock(),
	}
	journal[journalNext] = entry
	journalNext = if journalNext >= JOURNAL_LIMIT then 1 else journalNext + 1

	warn(string.format(
		"[MatrixGuard] HALT %s.%s (%s): %s [manual reconciliation required]",
		player.Name,
		currency,
		rule,
		detail
	))
	local hook = _onViolation
	if hook then
		task.spawn(function()
			local ok, err = pcall(hook :: any, entry)
			if not ok then
				warn("[MatrixGuard] onViolation errored: " .. tostring(err))
			end
		end)
	end
end

local function capsFor(currency: string): CurrencyCaps?
	local caps = _caps
	if not caps then
		return nil
	end
	return caps[currency] or caps["*"]
end

-- Core decision. Pure with respect to `budget` mutation; returns
-- (ok, rule, detail) and never touches the wallet.
local function evaluate(
	currency: string,
	balance: number,
	value: any,
	budget: BudgetState?,
	now: number
): (boolean, string, string)
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return false, "type", "non-finite or non-number balance write: " .. tostring(value)
	end
	if value < 0 then
		return false, "type", string.format("negative balance write: %.6g", value)
	end

	local caps = capsFor(currency)
	if not caps then
		return false, "unknown-currency", "no cap entry (and no \"*\" default) for this currency"
	end

	local maxBalance = caps.maxBalance or math.huge
	if value > maxBalance then
		return false, "max-balance", string.format("write %.6g exceeds maxBalance %.6g", value, maxBalance)
	end

	local delta = value - balance
	-- A corrupt pre-existing balance (NaN/inf from legacy data) makes delta
	-- non-finite, and NaN slips every `>` comparison below — reject instead.
	if delta ~= delta or delta == math.huge then
		return false, "type", string.format("non-finite delta (stored balance %.6g is corrupt)", balance)
	end
	if delta <= 0 then
		return true, "", ""
	end

	-- budget is nil only when caps resolution failed, handled above.
	local state = budget :: BudgetState

	local envelope = state.sessionMaxDelta * ENVELOPE_FACTOR
	if delta > envelope then
		return false, "delta-envelope", string.format(
			"single gain %.6g exceeds %dx largest accepted session gain (%.6g)",
			delta,
			ENVELOPE_FACTOR,
			state.sessionMaxDelta
		)
	end

	local rate = caps.maxGainPerMinute / 60
	local burst = caps.maxGainBurst or caps.maxGainPerMinute / 4
	state.tokens = math.min(burst, state.tokens + (now - state.lastRefill) * rate)
	state.lastRefill = now
	if delta > state.tokens then
		return false, "gain-budget", string.format(
			"gain %.6g exceeds remaining budget %.6g (%.6g/min, burst %.6g)",
			delta,
			state.tokens,
			caps.maxGainPerMinute,
			burst
		)
	end

	state.tokens -= delta
	if delta > state.sessionMaxDelta then
		state.sessionMaxDelta = delta
	end
	return true, "", ""
end

function MatrixGuard.Init(config: Config): ()
	if _caps then
		error("[MatrixGuard] Init() may only be called once", 2)
	end

	local caps: { [string]: CurrencyCaps } = {}
	for currency, entry in pairs(config.caps) do
		if typeof(entry.maxGainPerMinute) ~= "number"
			or entry.maxGainPerMinute ~= entry.maxGainPerMinute
			or entry.maxGainPerMinute <= 0
			or entry.maxGainPerMinute == math.huge
		then
			error(string.format("[MatrixGuard] caps[%q].maxGainPerMinute must be a finite positive number", currency), 2)
		end
		caps[currency] = table.freeze({
			maxGainPerMinute = entry.maxGainPerMinute,
			maxGainBurst = entry.maxGainBurst,
			maxExpectedDelta = entry.maxExpectedDelta,
			maxBalance = entry.maxBalance,
		})
	end

	_caps = table.freeze(caps)
	_onViolation = config.onViolation
end

-- Advisory pre-check: would writing `newValue` to `currency` at `balance` be
-- accepted right now? Consumes NO budget and journals nothing — use it to
-- reject cheaply before running an expensive grant. The wrapped write remains
-- the authority.
function MatrixGuard.Validate(currency: string, balance: number, newValue: number): (boolean, string?)
	if not _caps then
		error("[MatrixGuard] Init() must be called before use", 2)
	end
	local caps = capsFor(currency)
	local probe: BudgetState? = if caps
		then {
			tokens = caps.maxGainBurst or caps.maxGainPerMinute / 4,
			lastRefill = os.clock(),
			sessionMaxDelta = math.max(caps.maxExpectedDelta or caps.maxGainPerMinute / 4, 0),
		}
		else nil
	local ok, rule, detail = evaluate(currency, balance, newValue, probe, os.clock())
	return ok, if ok then nil else rule .. ": " .. detail
end

-- Returns the wallet proxy for one player-session (see header for wiring).
-- The proxy is transparent for reads and iteration; writes go through
-- validation into `real`. Budget/envelope state lives in this closure — it
-- dies with the proxy, so per-session accounting can never leak across
-- players or sessions.
function MatrixGuard.WrapWallet(player: Player, real: { [string]: number }): { [string]: number }
	if not _caps then
		error("[MatrixGuard] Init() must be called before use", 2)
	end
	if typeof(real) ~= "table" then
		error("[MatrixGuard] WrapWallet expects the real wallet table", 2)
	end

	local budgets: { [string]: BudgetState } = {}

	local proxy = setmetatable({}, {
		__index = function(_, key: string): number?
			return real[key]
		end,
		__newindex = function(_, key: any, value: any): ()
			local currency = if typeof(key) == "string" then key else tostring(key)
			local balance = if typeof(key) == "string" then (real[key] :: number?) or 0 else 0

			if typeof(key) ~= "string" then
				record(player, currency, "type", nil, balance, "non-string currency key")
				error("[MatrixGuard] wallet write rejected (type)", 2)
			end

			local now = os.clock()
			local budget = budgets[key]
			if not budget then
				local caps = capsFor(key)
				if caps then
					budget = {
						tokens = caps.maxGainBurst or caps.maxGainPerMinute / 4,
						lastRefill = now,
						sessionMaxDelta = math.max(caps.maxExpectedDelta or caps.maxGainPerMinute / 4, 0),
					}
					budgets[key] = budget
				end
			end

			local evalOk, ok, rule, detail = pcall(evaluate, key, balance, value, budget, now)
			if not evalOk then
				-- The guard itself failed: reject, never wave through.
				record(player, key, "guard-error", nil, balance, tostring(ok))
				error("[MatrixGuard] wallet write rejected (guard-error)", 2)
			end
			if not ok then
				local attempted = if typeof(value) == "number" then value else nil
				record(player, key, rule, attempted, balance, detail)
				error(string.format("[MatrixGuard] wallet write rejected (%s)", rule), 2)
			end

			real[key] = value
		end,
		__iter = function()
			return next, real
		end,
		__metatable = "MatrixGuard", -- getmetatable/setmetatable can't reach the hooks
	})

	return (proxy :: any) :: { [string]: number }
end

-- Snapshot (copy) of the bounded violation journal, newest last. Feed this to
-- your reconciliation tooling; rejected writes never mutated a balance, so
-- reconciliation means investigating the SOURCE, not repairing the wallet.
function MatrixGuard.GetJournal(): { ViolationRecord }
	local out: { ViolationRecord } = {}
	for i = 1, JOURNAL_LIMIT do
		local idx = ((journalNext - 1 + i - 1) % JOURNAL_LIMIT) + 1
		local entry = journal[idx]
		if entry then
			table.insert(out, entry)
		end
	end
	return out
end

return table.freeze(MatrixGuard)
