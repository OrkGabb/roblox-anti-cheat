--!strict
-- @Author @OrkGabb
-- AC/Core/RateLimiter.luau
--
-- Canonical per-player rate limiter for currency-earning actions: a lazily
-- refilled token bucket (burst + sustained-rate control) with optional
-- machine-timing ("macro") detection layered on top of the same Consume call.
--
-- Unified from two proven implementations:
--   * PSU ClickService's inline token bucket — kept as the core algorithm. A
--     token bucket bounds BOTH burst size and sustained rate and degrades
--     gracefully (partial grants) under network jitter. The fixed
--     calls-per-window counter it replaces (ClickGame RateLimiter) permits a
--     2x burst straddling every window boundary and can only accept-or-drop
--     a whole batch.
--   * PSU AntiExploitService's rolling-window standard-deviation ("sigma")
--     analysis, rebuilt here into the multi-signal detector below. In the
--     source codebase the detector was built and self-tested but never wired
--     into any crediting path; here it gates the same Consume() call as the
--     bucket, so every consumer gets both signals with no extra integration
--     step.
--
-- Refill is computed lazily from elapsed wall-clock on each Consume() — no
-- Heartbeat wiring. (The source AntiExploitService required the integrator to
-- drive RefillTokens() every frame; forgetting that silently froze every
-- bucket at its starting token count.)
--
-- MACRO DETECTION (multi-signal, cumulative). A single stddev threshold on
-- inter-arrival times is statistically broken at both ends: server arrivals
-- are quantized to frame boundaries, so a steady HUMAN can measure near-zero
-- sigma across a window (false positive), while any macro adding more jitter
-- than the threshold sails through (false negative). Detection instead runs
-- parallel heuristics per full window and accumulates weighted evidence:
--   * Regularity: sigma below max(absolute floor, CV floor * mean). Grounded
--     in motor-control literature: human inter-tap stddev is tens of
--     milliseconds (elite paced tapping ~5ms) and scales with tempo — hence
--     the coefficient-of-variation term, not a lone absolute threshold.
--   * Interval entropy: Shannon entropy of frame-quantized gap counts,
--     robust to the arrival quantization above — a steady human spans
--     neighboring frame bins (high entropy) while a locked timer occupies one
--     bin (zero bits) even when quantization makes its sigma look "human".
--   * Bounded support: macro authors add UNIFORM jitter, and a uniform's
--     quantized support is HARD-bounded — once its frame-bin envelope is
--     learned, the probability of an arrival outside it is exactly zero,
--     while every human gap distribution has tails that admit a new outer
--     bin every few dozen arrivals. The channel learns the envelope over one
--     window, locks it, and fires only when a run survives several windows
--     unbroken (humans reset it relentlessly), spans enough bins to carry
--     shape information, and shows no dominant bin — a locked-in rhythmic
--     human is center-peaked, a uniform physically cannot be. Deliberately
--     NOT a goodness-of-fit test: frame quantization dithers a uniform into
--     a trapezoid whose mismatch against any flat model grows with sample
--     count, so chi-square-style tests degrade exactly where this channel
--     needs power.
--   * Claimed-timestamp consistency (optional: forward per-action client
--     timestamps to Consume). Untrusted and only ever self-incriminating:
--     machine-regular claims admit the macro outright, and claimed jitter
--     that the arrival stream physically lacks proves fabrication — network
--     delay ADDS variance to a send schedule, it never removes it. Honest
--     human data contributes nothing; absent data disables the channel.
--   * Batching signature, flagged SEPARATELY: repeated same-frame
--     multi-action bursts arriving at a near-constant period are a
--     client-side aggregator, not human input — reported under its own
--     reason so game policy can differ. Same-frame deltas are also excluded
--     from the timing statistics: they are transport artifacts, and counting
--     them as zero-intervals is what let empty-bucket spam and coalesced
--     deliveries collapse the old sigma into false positives.
--
-- Evidence accrues per unit of OBSERVED ACTIVITY TIME (each window
-- evaluation's contribution is scaled by that arrival's gap), then decays per
-- second — so the dynamics are click-rate independent: a fast legit clicker
-- cannot be pinned by a weak channel merely for clicking fast, one freak
-- window washes out, no single weak channel outruns decay, and several weak
-- signals together still accumulate to a flag.
--
-- Flagging NEVER refunds tokens (a flagged call still spends), and while the
-- accumulated evidence sits above the threshold every call is denied — being
-- flagged must never be cheaper than being rate-limited.
--
-- Known residuals, deliberately accepted to keep the false-positive posture
-- conservative: a macro whose jitter is narrower than about 1.5 server
-- frames (~25ms) spans too few bins for the support channel, and a macro
-- drawing its jitter from a heavy-tailed human-like distribution defeats
-- shape analysis by construction. Both gain nothing a human spammer cannot —
-- the bucket caps their earn rate identically; timing detection only removes
-- the automation comfort, never the rate bound.
--
-- WHERE MACRO DETECTION BELONGS: enable `macroDetection` only for actions
-- fired directly by human input (one call per click/tap). Do NOT enable it on
-- fixed-cadence batch remotes — a legit client that batches clicks on a 0.5s
-- timer has machine-perfect send timing BY DESIGN and will trip the batching
-- signature instantly — nor on server-internal callers (auto-clicker gamepass
-- loops). Both would self-flag.

local Players = game:GetService("Players")

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- Grounding for the floors is in the header. Weights + GAIN_RATE are chosen
-- against the 0.25/s decay so that: strong channels (regularity, timestamp
-- fraud) flag alone within seconds; flatness flags alone only when sustained
-- for tens of seconds; entropy alone can at most hold ground, never flag.
local FRAME_QUANTUM = 1 / 60
local BURST_EPSILON = 0.005
local CV_FLOOR = 0.03
local ENTROPY_FLOOR = 0.9
local FLAT_SPAN_MIN = 4
local FLAT_GATE_WINDOWS = 6
local FLAT_MAX_SHARE = 1 / 3
local FLAT_INTERIOR_FILL = 0.25
local WEIGHT_REGULARITY = 1.5
local WEIGHT_ENTROPY = 1.0
local WEIGHT_FLATNESS = 1.25
local WEIGHT_TIMESTAMP = 2.0
local GAIN_RATE = 0.25
local BATCH_TRAIN = 6
local BATCH_GAP_CV = 0.05

export type MacroVerdict = {
	reasons: { string }, -- "regularity" | "low-entropy" | "uniform-jitter" | "timestamp-mismatch" | "batching-signature" | "accumulated"
	evidence: number, -- accumulated score at flag time
	flagCount: number, -- lifetime flags for this player (== GetSuspicion)
	sigma: number, -- stddev of the window that triggered (intervals; burst periods for batching)
	mean: number,
	entropy: number, -- frame-gap entropy of the interval window, bits (0 for batching flags)
	samples: number,
}

export type MacroDetectionConfig = {
	windowSize: number?, -- intervals per analysis window (default 40, floored at 12 — below that no statistic is trustworthy)
	maxInterval: number?, -- intervals >= this are idle gaps, not part of one action train (default 1.0)
	flagThreshold: number?, -- accumulated evidence that flags and denies (default 3.0)
	evidenceDecayPerSecond: number?, -- passive decay so isolated signals wash out (default 0.25)
	flagCooldown: number?, -- min seconds between onFlagged fires while evidence stays pinned (default 5)
	sigmaThreshold: number?, -- absolute sigma floor inside the regularity signal, seconds (default 0.005)
	-- Called on every macro flag. Kick/ban policy is deliberately the
	-- caller's: the source auto-kicked at a fixed score, but that threshold is
	-- game policy, not detection. Legacy 3-parameter callbacks still fit; the
	-- verdict argument carries the per-channel detail.
	onFlagged: ((player: Player, sigma: number, suspicionScore: number, verdict: MacroVerdict) -> ())?,
}

export type Config = {
	maxBurst: number, -- bucket capacity: most actions grantable at once
	refillRate: number, -- tokens regained per second (sustained actions/sec cap)
	macroDetection: MacroDetectionConfig?,
}

type PlayerState = {
	tokens: number,
	lastRefill: number,
	lastAction: number,
	intervals: { number },
	suspicionScore: number,
	evidence: number,
	lastEvidenceAt: number,
	lastFlagAt: number,
	burstSize: number,
	burstStart: number,
	burstSizes: { number },
	burstGaps: { number },
	claimed: { number },
	lastClaimed: number?,
	claimedWarned: boolean,
	-- Bounded-support run: frame-bin envelope locked after warmup, histogram
	-- accumulated while no arrival escapes it.
	flatCounts: { [number]: number },
	flatN: number,
	envMin: number,
	envMax: number,
}

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_maxBurst: number,
		_refillRate: number,
		_macro: MacroDetectionConfig?,
		_states: { [Player]: PlayerState },
	},
	RateLimiter
))

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Population mean/stddev of the window. n < 2 returns sigma 1.0 ("plenty of
-- jitter"), so a short window can never trip a threshold.
local function windowStats(values: { number }): (number, number)
	local n = #values
	if n < 2 then
		return 0, 1.0
	end
	local sum = 0
	for _, v in ipairs(values) do
		sum += v
	end
	local mean = sum / n
	local varianceSum = 0
	for _, v in ipairs(values) do
		varianceSum += (v - mean) ^ 2
	end
	return mean, math.sqrt(varianceSum / n)
end

-- Shannon entropy (bits) of intervals quantized to server frames. See the
-- entropy bullet in the header for why this survives arrival quantization.
local function frameGapEntropy(values: { number }): number
	local n = #values
	if n < 2 then
		return math.huge
	end
	local counts: { [number]: number } = {}
	for _, v in ipairs(values) do
		local bin = math.floor(v / FRAME_QUANTUM + 0.5)
		counts[bin] = (counts[bin] or 0) + 1
	end
	local h = 0
	for _, c in pairs(counts) do
		local p = c / n
		h -= p * math.log(p, 2)
	end
	return h
end

local function pushWindow(list: { number }, value: number, cap: number): ()
	table.insert(list, value)
	if #list > cap then
		table.remove(list, 1)
	end
end

function RateLimiter.new(config: Config): RateLimiter
	local self = setmetatable({
		_maxBurst = config.maxBurst,
		_refillRate = config.refillRate,
		_macro = config.macroDetection,
		_states = {} :: { [Player]: PlayerState },
	}, RateLimiter)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._states[player] = nil
	end)

	return self
end

local function getState(self: RateLimiter, player: Player, now: number): PlayerState
	local state = self._states[player]
	if not state then
		state = {
			tokens = self._maxBurst, -- bucket starts full: first join gets full burst headroom
			lastRefill = now,
			lastAction = 0,
			intervals = {},
			suspicionScore = 0,
			evidence = 0,
			lastEvidenceAt = now,
			lastFlagAt = 0,
			burstSize = 1,
			burstStart = 0,
			burstSizes = {},
			burstGaps = {},
			claimed = {},
			lastClaimed = nil,
			claimedWarned = false,
			flatCounts = {},
			flatN = 0,
			envMin = 0,
			envMax = 0,
		}
		self._states[player] = state
	end
	return state
end

-- Feeds one interval into the bounded-support run. During the first
-- windowSize arrivals the envelope learns freely; after that, one arrival
-- outside the locked envelope resets the run — the event a uniform macro can
-- never produce and a human cannot avoid for long (header).
local function feedFlatness(state: PlayerState, delta: number, windowSize: number): ()
	local bin = math.floor(delta / FRAME_QUANTUM + 0.5)
	if state.flatN >= windowSize and (bin < state.envMin or bin > state.envMax) then
		table.clear(state.flatCounts)
		state.flatN = 0
	end
	if state.flatN == 0 then
		state.envMin = bin
		state.envMax = bin
	else
		state.envMin = math.min(state.envMin, bin)
		state.envMax = math.max(state.envMax, bin)
	end
	state.flatCounts[bin] = (state.flatCounts[bin] or 0) + 1
	state.flatN += 1
end

-- The support channel's verdict on the current run (see header bullet):
-- long-surviving locked envelope, wide enough span, no dominant bin (a
-- locked-in rhythmic human is center-peaked), and every interior bin
-- carrying a real share of the mass (a broad human distribution surviving on
-- a wide envelope decays smoothly into near-empty interior tail bins; a
-- uniform has no holes). Edge bins are exempt from the fill test — frame
-- dithering legitimately thins a uniform's outermost bins.
local function boundedSupportStrength(state: PlayerState, windowSize: number): number
	if state.flatN < FLAT_GATE_WINDOWS * windowSize then
		return 0
	end
	local span = state.envMax - state.envMin + 1
	if span < FLAT_SPAN_MIN then
		return 0
	end
	local flatShare = state.flatN / span
	local maxCount = 0
	for _, c in pairs(state.flatCounts) do
		maxCount = math.max(maxCount, c)
	end
	if maxCount >= state.flatN * FLAT_MAX_SHARE then
		return 0
	end
	for bin = state.envMin + 1, state.envMax - 1 do
		if (state.flatCounts[bin] or 0) < FLAT_INTERIOR_FILL * flatShare then
			return 0
		end
	end
	return 1
end

-- Claimed client timestamps are ingested only when the whole payload is
-- well-formed: finite, non-decreasing, sanely sized. Anything else turns the
-- channel off for the call rather than becoming evidence — an integrator
-- forwarding a raw remote payload must not get innocents punished for it.
local function ingestClaimed(state: PlayerState, timestamps: { number }, windowSize: number, maxInterval: number): boolean
	local n = #timestamps
	if n == 0 or n > 64 then
		return false
	end
	local prev: number? = nil
	for _, ts in ipairs(timestamps) do
		if typeof(ts) ~= "number" or ts ~= ts or ts >= math.huge or ts <= -math.huge then
			return false
		end
		if prev ~= nil and ts < prev then
			return false
		end
		prev = ts
	end

	local last = state.lastClaimed
	if last ~= nil and timestamps[1] < last then
		-- Claimed clock ran backwards across calls: a new client epoch
		-- (restart, rejoin). Restart the chain — opting out of the channel is
		-- always possible anyway, so this costs no detection power.
		last = nil
		table.clear(state.claimed)
	end
	for _, ts in ipairs(timestamps) do
		if last ~= nil then
			local d = ts - last
			if d < maxInterval then
				pushWindow(state.claimed, d, windowSize)
			end
		end
		last = ts
	end
	state.lastClaimed = last
	return true
end

local function fireFlag(
	macro: MacroDetectionConfig,
	state: PlayerState,
	player: Player,
	now: number,
	reasons: { string },
	sigma: number,
	mean: number,
	entropy: number,
	samples: number
): ()
	if now - state.lastFlagAt < (macro.flagCooldown or 5) then
		return
	end
	state.lastFlagAt = now
	state.suspicionScore += 1
	warn(string.format(
		"[RateLimiter] %s flagged: %s (sigma %.5f, evidence %.2f, flags %d)",
		player.Name,
		table.concat(reasons, "+"),
		sigma,
		state.evidence,
		state.suspicionScore
	))
	if macro.onFlagged then
		-- Spawned, not called inline: onFlagged is policy (kick/ban/logging)
		-- and may legitimately yield, but it fires mid-Consume — a yield here
		-- would suspend the caller's crediting path around the flag.
		task.spawn(macro.onFlagged, player, sigma, state.suspicionScore, {
			reasons = reasons,
			evidence = state.evidence,
			flagCount = state.suspicionScore,
			sigma = sigma,
			mean = mean,
			entropy = entropy,
			samples = samples,
		})
	end
end

-- Records one arrival and returns whether this call must be denied. Runs on
-- every arrival — granted or not — so denial cadence feeds detection too.
local function observe(
	macro: MacroDetectionConfig,
	state: PlayerState,
	player: Player,
	now: number,
	clientTimestamps: { number }?
): boolean
	local windowSize = math.max(macro.windowSize or 40, 12)
	local maxInterval = macro.maxInterval or 1.0
	local flagThreshold = macro.flagThreshold or 3.0

	local decay = macro.evidenceDecayPerSecond or 0.25
	state.evidence = math.max(0, state.evidence - decay * (now - state.lastEvidenceAt))
	state.lastEvidenceAt = now

	if clientTimestamps then
		if not ingestClaimed(state, clientTimestamps, windowSize, maxInterval) and not state.claimedWarned then
			state.claimedWarned = true
			warn(string.format("[RateLimiter] %s sent malformed action timestamps — channel ignored", player.Name))
		end
	end

	local delta = now - state.lastAction
	state.lastAction = now

	local batching = false
	if delta >= maxInterval then
		-- Idle gap: a new action train. Burst-period analysis needs a
		-- contiguous train, so its rings reset with the train.
		state.burstSize = 1
		state.burstStart = now
		table.clear(state.burstSizes)
		table.clear(state.burstGaps)
	elseif delta <= BURST_EPSILON then
		-- Same-frame delivery: transport artifact, never timing evidence
		-- (header). Counts toward the burst, not the intervals.
		state.burstSize += 1
	else
		if state.burstSize >= 2 then
			pushWindow(state.burstSizes, state.burstSize, BATCH_TRAIN)
			pushWindow(state.burstGaps, now - state.burstStart, BATCH_TRAIN)
			if #state.burstGaps >= BATCH_TRAIN then
				local gapMean, gapSigma = windowStats(state.burstGaps)
				if gapMean > 0 and gapSigma / gapMean < BATCH_GAP_CV then
					batching = true
					fireFlag(macro, state, player, now, { "batching-signature" }, gapSigma, gapMean, 0, BATCH_TRAIN)
					table.clear(state.burstSizes)
					table.clear(state.burstGaps)
				end
			end
		end
		state.burstSize = 1
		state.burstStart = now

		feedFlatness(state, delta, windowSize)
		pushWindow(state.intervals, delta, windowSize)
		if #state.intervals >= windowSize then
			local mean, sigma = windowStats(state.intervals)
			local entropy = frameGapEntropy(state.intervals)
			local floor = math.max(macro.sigmaThreshold or 0.005, CV_FLOOR * mean)

			local sReg = clamp01((floor - sigma) / floor)
			local sEnt = clamp01((ENTROPY_FLOOR - entropy) / ENTROPY_FLOOR)
			local sFlat = boundedSupportStrength(state, windowSize)
			local sTs = 0
			if #state.claimed >= windowSize then
				local cMean, cSigma = windowStats(state.claimed)
				local cFloor = math.max(macro.sigmaThreshold or 0.005, CV_FLOOR * cMean)
				if cSigma < cFloor then
					sTs = 1 -- machine schedule admitted by the client's own claims
				elseif cSigma > 2 * sigma + 0.004 then
					sTs = 1 -- claimed jitter the arrival stream physically lacks
				end
			end

			-- Scaled by this arrival's gap: evidence per second of activity,
			-- not per call (header).
			local gain = (
				WEIGHT_REGULARITY * sReg
				+ WEIGHT_ENTROPY * sEnt
				+ WEIGHT_FLATNESS * sFlat
				+ WEIGHT_TIMESTAMP * sTs
			) * GAIN_RATE * delta
			if gain > 0 then
				state.evidence = math.min(state.evidence + gain, flagThreshold * 2)
			end

			if state.evidence >= flagThreshold then
				local reasons = {}
				if sReg > 0.25 then
					table.insert(reasons, "regularity")
				end
				if sEnt > 0.25 then
					table.insert(reasons, "low-entropy")
				end
				if sFlat > 0.25 then
					table.insert(reasons, "uniform-jitter")
				end
				if sTs > 0.25 then
					table.insert(reasons, "timestamp-mismatch")
				end
				if #reasons == 0 then
					table.insert(reasons, "accumulated")
				end
				fireFlag(macro, state, player, now, reasons, sigma, mean, entropy, #state.intervals)
			end
		end
	end

	return batching or state.evidence >= flagThreshold
end

-- Requests `requested` action tokens (default 1) for the player. Returns how
-- many were granted: min(requested, whole tokens available), or 0 when the
-- bucket is empty or the macro detector denies the call. Partial grants let a
-- legitimate over-sized batch (network hiccup delivering two batches at once)
-- earn what the budget allows instead of being dropped wholesale.
-- `clientTimestamps` optionally carries the client's claimed per-action times
-- for the consistency channel (see header) — omit it and that channel is off.
function RateLimiter.Consume(self: RateLimiter, player: Player, requested: number?, clientTimestamps: { number }?): number
	-- Sanitize even here (callers should have already): a NaN/Infinity request
	-- must never reach the bucket arithmetic, where it would poison `tokens`
	-- and every later comparison against it.
	local count = 1
	if typeof(requested) == "number" and requested == requested and requested < math.huge then
		count = math.clamp(math.floor(requested), 1, self._maxBurst)
	end

	local now = os.clock()
	local state = getState(self, player, now)

	-- Lazy refill from elapsed wall-clock.
	local elapsed = now - state.lastRefill
	state.tokens = math.min(self._maxBurst, state.tokens + elapsed * self._refillRate)
	state.lastRefill = now

	local macro = self._macro
	local denied = false
	if macro then
		denied = observe(macro, state, player, now, clientTimestamps)
	end

	if state.tokens < 1 then
		return 0
	end

	-- Tokens are spent before a macro denial is applied — flagging must never
	-- be cheaper than being rate-limited.
	local granted = math.min(count, math.floor(state.tokens))
	state.tokens -= granted

	if denied then
		return 0
	end

	return granted
end

-- Boolean convenience for single-action gates (one remote call = one action).
function RateLimiter.Check(self: RateLimiter, player: Player): boolean
	return self:Consume(player, 1) > 0
end

-- Accumulated macro-flag count for the player (0 if never seen). Read this
-- when deciding kick/ban policy outside of the onFlagged callback.
function RateLimiter.GetSuspicion(self: RateLimiter, player: Player): number
	local state = self._states[player]
	return if state then state.suspicionScore else 0
end

return RateLimiter
