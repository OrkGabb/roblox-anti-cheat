--!strict
-- @Author @OrkGabb
-- AC/Core/PassiveAccrual.luau
--
-- Server-authoritative passive-income accrual. Any client-side passive ticker
-- is pure prediction; this is the source of truth purchases validate against.
--
-- Unified from ClickGame ServerPassiveSystem and PSU ClickService's
-- accruePassive — both descend from the same design and were near-identical.
-- The double-credit-prevention pattern both proved out, preserved exactly:
--
--   * `lastAccrual` is IN-MEMORY ONLY, never persisted, and reset on join —
--     so a rejoin can never re-credit time that already elapsed (persisting
--     the timestamp is the classic offline-earnings double-credit bug).
--   * The clock is ALWAYS advanced each tick, even while the profile has not
--     loaded yet — otherwise the first tick after a slow profile load would
--     credit the whole load time as a startup burst.
--   * Payouts are elapsed-time based (rate * seconds since last credit), so
--     Heartbeat jitter can never over- or under-pay.
--   * Accrual is per-player serialized. getRates is contractually
--     non-yielding, but if one ever yields anyway, overlapping Heartbeat
--     handlers would resume with stale timestamps, rewind `lastAccrual` below
--     the credited watermark, and re-credit the rewound window every
--     occurrence. A player with a getRates call still in flight is skipped
--     (not queued) until it returns, and each player's timestamps are taken
--     inside their own iteration so a resume can never write an old clock.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Contract = require(script.Parent.Contract)
local CurrencyLedger = require(script.Parent.CurrencyLedger)

local PassiveAccrual = {}

export type Config = {
	tickInterval: number?, -- seconds between accrual ticks (default 1)
	-- Server-side recompute of the player's passive rates from owned upgrades
	-- / gamepasses: returns { [currencyKey] = unitsPerSecond }, or nil while
	-- the profile is unavailable. Fold auto-clicker-style gamepass income in
	-- here if it should pay out as a passive rate.
	getRates: (player: Player) -> { [string]: number }?,
}

-- Wall-clock of the last credited accrual per player (see header for why this
-- must stay in-memory).
local lastAccrual: { [Player]: number } = {}

-- Players with a getRates call in flight (see the serialization bullet in the
-- header). Entries are cleared on return, error, and PlayerRemoving, so a
-- violation can never wedge a player's accrual shut past their session.
local processing: { [Player]: boolean } = {}

local _initialized = false

function PassiveAccrual.Init(config: Config): ()
	-- One-shot: a second Init would connect a second Heartbeat accrual loop
	-- (and a second set of player-lifecycle handlers) over the same shared
	-- clock table.
	if _initialized then
		error("[PassiveAccrual] Init() may only be called once", 2)
	end
	_initialized = true

	-- Guarded copy; the integrator's table is never mutated. A yielding
	-- getRates is contained by the wrapper (reads as nil -> tick skipped), so
	-- the processing lock below becomes belt-and-braces rather than the only
	-- line of defense.
	config = {
		tickInterval = config.tickInterval,
		getRates = Contract.NonYielding("PassiveAccrual.getRates", config.getRates),
	}

	Players.PlayerAdded:Connect(function(player: Player)
		lastAccrual[player] = os.clock()
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastAccrual[player] = nil
		processing[player] = nil
	end)
	-- Players already present when the server boots (Studio Play solo, late require).
	for _, player in ipairs(Players:GetPlayers()) do
		lastAccrual[player] = os.clock()
	end

	local tickInterval = config.tickInterval or 1
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < tickInterval then
			return
		end
		acc = 0

		for _, player in ipairs(Players:GetPlayers()) do
			if processing[player] then
				continue
			end

			-- Taken per-iteration, never hoisted: a handler resuming from a
			-- yielded getRates continues this loop, and a hoisted `now` would
			-- be stale by then (the clock-rewind in the header).
			local now = os.clock()
			-- Always advance the clock, even before the profile loads (no
			-- startup burst — see header).
			local last = lastAccrual[player] or now
			lastAccrual[player] = now

			processing[player] = true
			local ok, rates = pcall(config.getRates, player)
			processing[player] = nil

			if not ok then
				warn(string.format("[PassiveAccrual] getRates errored for %s: %s", player.Name, tostring(rates)))
				continue
			end
			if not rates then
				continue
			end

			local elapsed = now - last
			for currency, perSecond in pairs(rates) do
				if perSecond > 0 then
					-- Fractional amounts are fine; the ledger rejects
					-- NaN/Infinity if a rate recompute goes bad.
					CurrencyLedger.Add(player, currency, perSecond * elapsed, "passive")
				end
			end
		end
	end)
end

return table.freeze(PassiveAccrual)
