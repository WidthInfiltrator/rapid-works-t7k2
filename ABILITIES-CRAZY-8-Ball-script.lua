-- Smith Pool Bot | place 107430170196919
-- 8-ball + 9-ball. Uses the game's own physics, shot finder, and judge.
-- Fires through the live Client.Input pipeline; never sends a raw remote.
--
-- getgenv().__smith.dry   = true   -- solve + log, never fire
-- getgenv().__smith.debug = true   -- per-candidate log
-- getgenv().__smith.on    = false  -- stop (re-run to resume)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Shared = RS:WaitForChild("Shared")

local Config = require(Shared.Config)
local Ball = require(Shared.Physics.Ball)
local Finder = require(Shared.Bots.ShotFinder)
local Brain = require(Shared.Bots.Brain)
local Rng = require(Shared.Bots.Rng)
local Fill = require(Shared.Ults.Fill)
local Net = RS:WaitForChild("Net")

local S = getgenv().__smith or {}
getgenv().__smith = S
if S.dry == nil then S.dry = false end
if S.debug == nil then S.debug = false end
if S.ult == nil then S.ult = false end
if S.autoplay == nil then S.autoplay = true end
if S.queue_remotes == nil then S.queue_remotes = { "SoloSearch", "QueueBot" } end
S.on = true
local GEN = (getgenv().__smith_gen or 0) + 1
getgenv().__smith_gen = GEN

local ELEV = Config.Cue.CueElevationDegrees

local function log(...)
	local t = {}
	for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
	print("[SMITH] " .. table.concat(t, " "))
end
local function post(tag, tbl)
	local f = getgenv().__smith_post
	if f then pcall(f, tag, tbl) end
end

------------------------------------------------------------------------
-- objects: scan once, cache, rescan only when the cache goes stale
------------------------------------------------------------------------
local last_scan = 0
local last_queue = 0
local last_fire = 0

local function valid(o)
	if type(o) ~= "table" then return false end
	local t, m, i = o.targets, o.match, o.input
	if type(t) ~= "table" or type(m) ~= "table" or type(i) ~= "table" then return false end
	local sn = rawget(t, "snapshot")
	if type(sn) ~= "table" or type(rawget(sn, "balls")) ~= "table" then return false end
	if type(rawget(m, "state")) ~= "table" or type(rawget(m.state, "balls")) ~= "table" then return false end
	return true
end

local function scan()
	local input, match, targets
	for _, v in pairs(getgc(true)) do
		if type(v) == "table" then
			if not input and type(rawget(v, "shootListeners")) == "table"
				and type(rawget(v, "aimListeners")) == "table"
				and type(rawget(v, "angle")) == "number" then
				input = v
			end
			if not match then
				local st = rawget(v, "state")
				if type(st) == "table" and type(rawget(st, "balls")) == "table"
					and type(rawget(v, "renderer")) == "table" then
					match = v
				end
			end
			if not targets and type(rawget(v, "snapshot")) == "table"
				and rawget(v, "localUserId") ~= nil
				and type(rawget(v, "pockets")) == "table" then
				targets = v
			end
			if input and match and targets then break end
		end
	end
	if input and match and targets then
		local o = { input = input, match = match, targets = targets }
		getgenv().__smith_objs = o
		log("attached")
		post("attach", { ok = true })
		return o
	end
end

local function objs(force)
	local o = getgenv().__smith_objs
	if valid(o) then return o end
	if not force and os.clock() - last_scan < 1.5 then return nil end
	last_scan = os.clock()
	return scan()
end

------------------------------------------------------------------------
-- matchmaking: fire a queue remote so the bot joins the next game on its own
------------------------------------------------------------------------
local function queue()
	if not S.autoplay then return end
	if os.clock() - last_queue < 8 then return end
	last_queue = os.clock()
	for _, name in ipairs(S.queue_remotes or {}) do
		local ev = Net:FindFirstChild(name)
		if ev then
			pcall(ev.FireServer, ev)
			log("QUEUE " .. name)
			post("queue", { name = name })
			return
		end
	end
end

------------------------------------------------------------------------
-- snapshot -> view. Balls come from the snapshot, never from the client
-- array: the client keeps 16 slots while a 9-ball rack only has 10.
------------------------------------------------------------------------
local function snapshot_balls(sn)
	local flat = sn.balls
	local maxk = 0
	for k in pairs(flat) do
		if type(k) == "number" and k > maxk then maxk = k end
	end
	local balls = {}
	for id = 0, math.floor(maxk / 4) - 1 do
		local q = id * 4
		local x, y, z, p = flat[q + 1], flat[q + 2], flat[q + 3], flat[q + 4]
		if type(x) == "number" and type(y) == "number" then
			local b = Ball.new(id, x, y)
			b.z = z or 0
			b.vx, b.vy, b.vz = 0, 0, 0
			b.wx, b.wy, b.wz = 0, 0, 0
			b.pocketed = (p == 1)
			balls[#balls + 1] = b
		end
	end
	return balls
end

local function build_view(o)
	local sn = o.targets.snapshot
	local balls = snapshot_balls(sn)
	local game = o.match.game
	if not game then
		game = (sn.groups and next(sn.groups)) and "Eight" or "Nine"
	end
	return {
		geometry = o.match.state.geometry,
		balls = balls,
		groups = sn.groups,
		team = sn.activeTeam or 1,
		called = sn.calledPocket,
		breakShot = sn.breakShot == true,
		requireRail = true,
		game = game,
	}, sn
end

------------------------------------------------------------------------
-- solver
------------------------------------------------------------------------
local function cue_safety(g, b)
	local hl, hw = g.halfLength, g.halfWidth
	local ax, ay = math.abs(b.x), math.abs(b.y)
	local corner = math.sqrt((ax - hl) ^ 2 + (ay - hw) ^ 2)
	local side = math.sqrt(b.x * b.x + (ay - hw) ^ 2)
	local rail = math.min(hl - ax, hw - ay)
	return math.max(0, math.min(corner, side, rail))
end

local function evaluate(view, cand, called)
	if called and cand.ball == 8 and cand.pocket ~= called then return nil end
	local okc, cal = pcall(Finder.calibrate, view, cand)
	if not okc or not cal then return nil end
	local okr, res = pcall(Brain.simulate, view, cand, cand.cueX, cand.cueY, cand.called)
	if not okr or type(res) ~= "table" then return nil end
	if res.foul or res.scratch then return nil end
	if res.winner == (3 - view.team) then return nil end
	local struck = Finder.findBall(res.balls, cand.ball)
	if not (struck and struck.pocketed) then return nil end

	local sc = 0
	if res.winner == view.team then sc += 100000 end
	if res.keep then sc += 500 end
	sc += (cand.score or 0) * 100

	local cue = Finder.findBall(res.balls, 0)
	if cue and not cue.pocketed then
		sc += math.min(cue_safety(view.geometry, cue), 20) * 10
		local opp = {
			geometry = view.geometry, balls = res.balls, groups = view.groups,
			team = 3 - view.team, called = nil, breakShot = false,
			requireRail = true, game = view.game,
		}
		local olist = Finder.candidates(opp)
		if olist[1] then sc -= olist[1].score * 60 end
	else
		sc -= 100000
	end

	if S.debug then
		log(string.format("cand ball=%d pocket=%d cut=%.1f score=%.0f", cand.ball, cand.pocket, math.deg(cand.cut or 0), sc))
	end
	return {
		kind = "pot", angle = cand.angle, power = cand.power,
		ball = cand.ball, pocket = cand.pocket, score = sc,
		cueX = cand.cueX, cueY = cand.cueY, called = cand.called,
	}
end

local function break_shot(view)
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return nil end
	local apex, bd = nil, math.huge
	for _, b in ipairs(view.balls) do
		if b.id ~= 0 and not b.pocketed then
			local d = (b.x - cue.x) ^ 2 + (b.y - cue.y) ^ 2
			if d < bd then bd, apex = d, b end
		end
	end
	if not apex then return nil end
	return { kind = "break", angle = math.atan2(apex.y - cue.y, apex.x - cue.x), power = 0.95 }
end

------------------------------------------------------------------------
-- pocket mouths (mirrors ShotFinder.pockets)
------------------------------------------------------------------------
local function mouths(g)
	local T = Config.Table
	local hl, hw = g.halfLength, g.halfWidth
	local list = {}
	for _, pk in ipairs(g.pockets) do
		local v3 = pk.y > 0 and 1 or -1
		if pk.x == 0 then
			list[#list + 1] = { mx = 0, my = v3 * hw, id = pk.id }
		else
			local v4 = pk.x > 0 and 1 or -1
			local cm = T.CornerMouthInches / 1.4142135623730951 / 2
			list[#list + 1] = { mx = v4 * (hl - cm), my = v3 * (hw - cm), id = pk.id }
		end
	end
	return list
end

------------------------------------------------------------------------
-- bank / kick: cue off a cushion, then object into a pocket
------------------------------------------------------------------------
local function bank_candidates(view, limit)
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return {} end
	local own = Finder.ownIds(view)
	local legal = {}
	for _, b in ipairs(view.balls) do
		if b.id ~= 0 and not b.pocketed then
			for _, id in ipairs(own) do
				if id == b.id then legal[#legal + 1] = b break end
			end
		end
	end
	local R2 = 2 * Config.Balls.RadiusInches
	local hl, hw = view.geometry.halfLength, view.geometry.halfWidth
	local out = {}
	for _, b in ipairs(legal) do
		for _, m in ipairs(mouths(view.geometry)) do
			local ux, uy = m.mx - b.x, m.my - b.y
			local d = math.sqrt(ux * ux + uy * uy)
			if d > 1.5 then
				ux, uy = ux / d, uy / d
				local gx, gy = b.x - ux * R2, b.y - uy * R2
				local refl = { { 2 * hl - gx, gy }, { -2 * hl - gx, gy }, { gx, 2 * hw - gy }, { gx, -2 * hw - gy } }
				for _, rp in ipairs(refl) do
					local rx, ry = rp[1], rp[2]
					local ax, ay = rx - cue.x, ry - cue.y
					local al = math.sqrt(ax * ax + ay * ay)
					if al > 1e-6 then
						out[#out + 1] = {
							ball = b.id, pocket = m.id,
							called = (b.id == 8 and view.game ~= "Nine") and m.id or nil,
							angle = math.atan2(ay, ax), power = 0.5,
							cueX = cue.x, cueY = cue.y,
							phi = math.atan2(uy, ux), cut = 0.3, dobj = d,
						}
						if limit and #out >= limit then return out end
					end
				end
			end
		end
	end
	return out
end

------------------------------------------------------------------------
-- direct pots without the Finder's approach-angle filter: read every ball
-- against every pocket, clearance-check, let calibrate/simulate verify
------------------------------------------------------------------------
local function path_clear(balls, ax, ay, bx, by, ia, ib, rad)
	local dx, dy = bx - ax, by - ay
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-6 then return true end
	local ux, uy = dx / len, dy / len
	for _, o in ipairs(balls) do
		if o.id ~= ia and o.id ~= ib and not o.pocketed then
			local vx, vy = o.x - ax, o.y - ay
			local t = vx * ux + vy * uy
			if t > 0 and t < len then
				local px, py = vx - ux * t, vy - uy * t
				if math.sqrt(px * px + py * py) < rad then return false end
			end
		end
	end
	return true
end

local function straight_candidates(view, limit)
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return {} end
	local own = Finder.ownIds(view)
	local R2 = 2 * Config.Balls.RadiusInches
	local out = {}
	for _, b in ipairs(view.balls) do
		if b.id ~= 0 and not b.pocketed then
			local legal = false
			for _, id in ipairs(own) do
				if id == b.id then legal = true end
			end
			if legal then
				for _, m in ipairs(mouths(view.geometry)) do
					local ux, uy = m.mx - b.x, m.my - b.y
					local d = math.sqrt(ux * ux + uy * uy)
					if d > 1.2 then
						ux, uy = ux / d, uy / d
						local gx, gy = b.x - ux * R2, b.y - uy * R2
						local ax, ay = gx - cue.x, gy - cue.y
						local al = math.sqrt(ax * ax + ay * ay)
						if al > 0.5 then
							local dx, dy = ax / al, ay / al
							local cut = dx * ux + dy * uy
							if cut > 0.2
								and path_clear(view.balls, cue.x, cue.y, gx, gy, 0, b.id, R2 * 0.98)
								and path_clear(view.balls, b.x, b.y, m.mx, m.my, b.id, -1, R2 * 0.9) then
								out[#out + 1] = {
									ball = b.id, pocket = m.id,
									called = (b.id == 8 and view.game ~= "Nine") and m.id or nil,
									angle = math.atan2(dy, dx), power = 0.5,
									cueX = cue.x, cueY = cue.y,
									phi = math.atan2(uy, ux),
									cut = math.acos(math.max(-1, math.min(1, cut))),
									dobj = d,
								}
								if limit and #out >= limit then return out end
							end
						end
					end
				end
			end
		end
	end
	return out
end

------------------------------------------------------------------------
-- safety: pick a legal contact that leaves the opponent the fewest options
------------------------------------------------------------------------
local function safety(view)
	local cue = Finder.findBall(view.balls, 0)
	if not cue then return nil end
	local rng = Rng.new((os.clock() * 1e6) % 2147483647)
	local ok, dec = pcall(Brain.safety, view, rng)
	if ok and type(dec) == "table" and type(dec.angle) == "number" and type(dec.power) == "number" then
		return { kind = "safe", angle = dec.angle, power = dec.power }
	end
	local sp = Finder.safePlan(view)
	if sp then
		return { kind = "safe", angle = sp.angle, power = sp.power }
	end
	return nil
end

------------------------------------------------------------------------
-- guaranteed legal contact: simulate-verify it actually touches a legal ball
------------------------------------------------------------------------
local function make_contact(view)
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return nil end
	local own = Finder.ownIds(view)
	local targets = {}
	for _, b in ipairs(view.balls) do
		if b.id ~= 0 and not b.pocketed then
			local legal = (#own == 0) and (b.id ~= 8)
			if not legal then
				for _, id in ipairs(own) do
					if id == b.id then legal = true end
				end
			end
			if legal then
				local d = (b.x - cue.x) ^ 2 + (b.y - cue.y) ^ 2
				targets[#targets + 1] = { b = b, d = d }
			end
		end
	end
	table.sort(targets, function(a, b) return a.d < b.d end)
	for _, t in ipairs(targets) do
		local base = math.atan2(t.b.y - cue.y, t.b.x - cue.x)
		local sp = Finder.hitPlan(view, t.b.id, cue.x, cue.y)
		local p = (sp and type(sp.power) == "number" and sp.power) or 0.5
		for _, off in ipairs({ 0, 0.04, -0.04, 0.08, -0.08, 0.12, -0.12 }) do
			local angle = base + off
			local ok, res = pcall(Brain.simulate, view, { angle = angle, power = p }, cue.x, cue.y, nil)
			if ok and type(res) == "table" and not res.foul and not res.scratch then
				return { kind = "safe", angle = angle, power = p }
			end
		end
	end
	return nil
end

------------------------------------------------------------------------
-- fine aim: find the widest angle window that still pots, then centre it
------------------------------------------------------------------------
local function refine_shot(view, shot)
	if shot.kind ~= "pot" or not shot.cueX then return shot end
	local function hits(a)
		local cand = { angle = a, power = shot.power, spin = { x = 0, y = 0 } }
		local ok, res = pcall(Brain.simulate, view, cand, shot.cueX, shot.cueY, shot.called)
		if not (ok and type(res) == "table" and not res.foul and not res.scratch) then return false end
		local b = Finder.findBall(res.balls, shot.ball)
		return b and b.pocketed or false
	end
	local step = math.rad(0.08)
	local bestLen, bestOff = 0, 0
	local i = -6
	while i <= 6 do
		if hits(shot.angle + i * step) then
			local j = i
			while j + 1 <= 6 and hits(shot.angle + (j + 1) * step) do j += 1 end
			local len = j - i + 1
			if len > bestLen then
				bestLen = len
				bestOff = ((i + j) / 2) * step
			end
			i = j + 1
		else
			i += 1
		end
	end
	if bestLen > 0 then
		return {
			kind = "pot", angle = shot.angle + bestOff, power = shot.power,
			ball = shot.ball, pocket = shot.pocket, score = shot.score,
			cueX = shot.cueX, cueY = shot.cueY, called = shot.called,
		}
	end
	return shot
end

local function build_candidates(view)
	local list, seen = {}, {}
	local function add(c)
		local k = tostring(c.ball) .. ":" .. tostring(c.pocket)
		if not seen[k] then
			seen[k] = true
			list[#list + 1] = c
		end
	end
	for _, c in ipairs(Finder.candidates(view)) do add(c) end
	for _, c in ipairs(straight_candidates(view, 24)) do add(c) end
	for _, c in ipairs(bank_candidates(view, 16)) do add(c) end
	return list
end

local function best_pot(view, deadline, called)
	local list = build_candidates(view)
	local best = nil
	for i = 1, math.min(#list, 28) do
		local c = list[i]
		if not (called and c.ball == 8 and c.pocket ~= called) then
			local e = evaluate(view, c, called)
			if e and (not best or e.score > best.score) then best = e end
		end
		if os.clock() > deadline then break end
		if i % 3 == 0 then task.wait() end
	end
	return best
end

local function solve(view, sn, deadline)
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return nil end
	local pd = 0
	for _, b in ipairs(view.balls) do
		if b.id ~= 0 and b.pocketed then pd += 1 end
	end
	if pd == 0 then
		S.pending8 = nil
		return break_shot(view)
	end

	local called = sn.calledPocket or S.pending8
	if view.game == "Nine" then called = nil end
	local best = best_pot(view, deadline, called)
	if best then return refine_shot(view, best) end

	local s = safety(view)
	if s then return s end
	return make_contact(view)
end

------------------------------------------------------------------------
-- abilities (best-effort): arm a harmless ult when one is charged
------------------------------------------------------------------------
local function arm_ult(o)
	if not S.ult then return end
	local sn = o.targets.snapshot
	local ults = sn and sn.ults
	if type(ults) ~= "table" or type(ults.bars) ~= "table" then return end
	local bar = ults.bars[tostring(o.targets.localUserId)]
	if type(bar) ~= "table" then return end
	local ok, ready = pcall(Fill.ready, bar)
	if not (ok and ready) then return end
	local ev = Net:FindFirstChild("UltActivate")
	if not ev then return end
	pcall(ev.FireServer, ev, "EaglesEye")
	log("ULT EaglesEye")
	post("ult", { name = "EaglesEye" })
end

------------------------------------------------------------------------
-- firing
------------------------------------------------------------------------
local function fire(o, shot)
	if os.clock() - last_fire < 2.5 then return false end
	local input = o.input
	if not input.enabled then return false end
	if input.spinEditing and input.setSpinEditing then pcall(input.setSpinEditing, input, false) end
	input:setAngle(shot.angle)
	task.wait(0.2)
	input:setSpin(0, 0)
	pcall(input.setElevation, input, ELEV)
	task.wait(0.04)
	input:setPower(shot.power)
	task.wait(0.07)
	input:releasePower()
	last_fire = os.clock()
	return true
end

------------------------------------------------------------------------
-- action
------------------------------------------------------------------------
local function act(o)
	local sn = o.targets.snapshot
	if type(sn) ~= "table" or type(sn.balls) ~= "table" then return end
	if sn.shooter ~= o.targets.localUserId then return end

	local phase = sn.phase
	if phase == "PocketChoice" then
		local view = build_view(o)
		local best = best_pot(view, os.clock() + 1.5, nil)
		local pocket = best and best.pocket
		if not pocket then
			local list = Finder.candidates(view)
			pocket = list[1] and list[1].pocket
		end
		if pocket then
			S.pending8 = pocket
			local okcall, err = pcall(function()
				o.targets.confirmedPocket = pocket
				if type(o.targets.onPocket) == "function" then
					o.targets.onPocket(pocket)
				end
			end)
			log(string.format("call8 pocket=%s ok=%s", tostring(pocket), tostring(okcall)))
			post("call8", { pocket = pocket, ok = okcall, err = tostring(err) })
		else
			log("call8 no pocket")
		end
		return true
	end

	if phase ~= "Aiming" and phase ~= "Placement" then return end

	local view, snap = build_view(o)
	-- Placement never committed server-side during testing. Shoot from the
	-- server's actual cue position and let the shot carry the placement.
	local cue = Finder.findBall(view.balls, 0)
	if not cue or cue.pocketed then return end

	local shot = solve(view, snap, os.clock() + 2.0)
	if not shot then
		log("no verified shot")
		return
	end
	if S.dry then
		log(string.format("DRY %s angle=%.4f pw=%.3f ball=%s", shot.kind, shot.angle, shot.power, tostring(shot.ball)))
		post("dry", { kind = shot.kind, angle = shot.angle, power = shot.power, ball = shot.ball })
		return
	end
	if shot.kind == "pot" then arm_ult(o) end
	if fire(o, shot) then
		log(string.format("FIRE %s angle=%.4f pw=%.3f ball=%s pocket=%s", shot.kind, shot.angle, shot.power, tostring(shot.ball), tostring(shot.pocket)))
		post("fire", { kind = shot.kind, angle = shot.angle, power = shot.power, ball = shot.ball, pocket = shot.pocket })
		return true
	end
end

------------------------------------------------------------------------
-- loop
------------------------------------------------------------------------
local rejected = Net:FindFirstChild("ShotRejected")
if rejected then
	rejected.OnClientEvent:Connect(function(...) log("REJECTED", ...) end)
end

task.spawn(function()
	log("online | dry=" .. tostring(S.dry) .. " | ult=" .. tostring(S.ult))
	local last_key = nil
	local last_state = nil
	local function state(s)
		if s ~= last_state then
			last_state = s
			log("state=" .. s)
			post("state", { s = s })
		end
	end
	while S.on and getgenv().__smith_gen == GEN do
		local o = objs(false)
		if not (o and valid(o)) then
			state("lobby")
			queue()
			task.wait(0.5)
			continue
		end
		local sn = o.targets.snapshot
		if sn.phase == "Result" or sn.phase == "Over" or sn.phase == "Summary" or sn.phase == "Ended" or sn.phase == "Complete" then
			state("result")
			queue()
		end
		if sn.shooter == o.targets.localUserId then
			if sn.phase == "Aiming" or sn.phase == "Placement" or sn.phase == "PocketChoice" then
				state("my_turn")
			else
				state("my_turn_resolving")
			end
		else
			state("opponent")
		end
		local key = tostring(sn.turnId) .. ":" .. tostring(sn.shotSeq) .. ":" .. tostring(sn.phase)
		if key ~= last_key then
			local ok, fired = pcall(act, o)
			if not ok then log("ERR " .. tostring(fired)) end
			if ok and fired == true then
				last_key = key
				getgenv().__smith_objs = nil
				last_scan = 0
			end
		end
		task.wait(0.15)
	end
	log("stopped")
end)