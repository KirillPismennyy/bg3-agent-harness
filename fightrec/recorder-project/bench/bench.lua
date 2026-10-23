-- Old (baseline/FightRec.lua) versus new (recorder/FightRec.lua) under one matched synthetic workload, driven
-- through tests/mock_se.lua inside the host's Lua 5.4 (lupa). These are HOST/MOCK measurements: the JSON encoder,
-- engine objects, Osiris and the file system are fakes, so absolute times say nothing about live SE frame time.
-- usage: python tools/lua54.py bench/bench.lua [--quick] [--out FILE]
-- Statistics: per trial p50/p99/max of single dispatches; summaries give the MEDIAN over trials of those
-- per-trial values (labelled *_med_trial) and the MAXIMUM over all trials (labelled *_max_all). Memory figures are
-- whole-harness Lua heap deltas (mock world + workload + recorder); the "null" control (bench/null_recorder.lua,
-- same hooks, no work) is reported beside them. The sampled peak is read every 25 events, not a true peak.
local mock = require("mock_se")
local json = require("json")

local REPO = host.repo
local V2, BASE = REPO .. "/recorder/FightRec.lua", REPO .. "/baseline/FightRec.lua"
local QUICK, OUT = false, nil
for i = 1, #arg do
    if arg[i] == "--quick" then QUICK = true end
    if arg[i] == "--out" then OUT = arg[i + 1] end
end
local hr = host.hrtime_ns

-- Event mix from the retained fight04 counts (DESIGN 1): weights per observation kind.
local MIX = { { "TurnStarted", 42 }, { "TurnEnded", 42 }, { "CastedSpell", 45 }, { "UsingSpellOnTarget", 35 },
    { "BeforeDealDamage", 26 }, { "DealDamage", 26 }, { "DealtDamage", 26 }, { "StatusApplied", 114 },
    { "StatusRemoved", 93 }, { "RollResult", 9 }, { "HitpointsChanged", 40 }, { "AttackedBy", 26 } }
local MIXT = 0
for _, m in ipairs(MIX) do MIXT = MIXT + m[2] end

local function lcg(seed)
    local s = seed
    return function(n)
        s = (s * 6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff
        return (s >> 33) % n
    end
end

-- A matched workload: the same list of (gap, kind, args) for every recorder; gaps approximate fight04's
-- 637 records in 516 s (~810 ms mean) with action bursts (several events in the same millisecond).
local function workload(E, N, seed)
    local rnd = lcg(seed)
    local list = {}
    for i = 1, E do
        local r, acc, kind = rnd(MIXT), 0, nil
        for _, m in ipairs(MIX) do
            acc = acc + m[2]
            if r < acc then kind = m[1] break end
        end
        local burst = rnd(4) == 0
        list[i] = { gap = burst and 0 or 300 + rnd(1100), kind = kind, a = 1 + rnd(4), b = 5 + rnd(N - 4),
            s = rnd(60) }
    end
    return list
end

local function cast(w, N)
    w.P, w.E = {}, {}
    for i = 1, N do
        local party = i <= 4
        local u = (party and "S_Player_" or "S_Enemy_") .. i .. "_" .. mock.guid(3000 + i)
        w:addCharacter(u, { party = party, pos = { i * 1.0, 0.0, -i * 1.0 }, statuses = { "BLESS", "HASTE" },
            resources = { { mock.guid(9001), 1, 1, 1 }, { mock.guid(9002), 1, 1, 1 }, { mock.guid(9003), 0, 2, 3 } } })
        if party then w.P[#w.P + 1] = u else w.E[#w.E + 1] = u end
    end
end

local function hitObj(w, s)
    local rolls = {}
    for i = 1, 2 do
        rolls[i] = w:obj("ConditionRoll", { RollType = "AttackRoll", Difficulty = 12 + i, Ability = "Dexterity",
            Skill = "Sentinel", SwappedSourceAndTarget = false, RollUuid = mock.guid(s * 10 + i),
            Roll = w:obj("StatsRoll", { Total = 15, NaturalRoll = 11, DiscardedDiceTotal = 0, Critical = "None" }) })
    end
    return w:obj("HitDesc", { TotalDamageDone = s % 12, DeathType = "None", DamageType = "Piercing", CauseType = "Attack",
        ArmorAbsorption = 0, LifeSteal = 0, EffectFlags = 1, StoryActionId = s, HitWith = "Weapon",
        AttackRollAbility = "Dexterity", SaveAbility = "None", SpellAttackType = 0, SpellCastGuid = mock.guid(s),
        SpellId = "Projectile_Arrow_" .. s, StatusId = "", SpellSchool = "None", AttackFlags = 3, SpellLevel = 0,
        SpellPowerLevel = 0, TotalHealDone = 0, OriginalDamageValue = s % 12, ConditionRolls = rolls,
        DamageList = { w:obj("DamagePair", { Amount = s % 12, DamageType = "Piercing" }) } })
end

local function dispatch(w, ev, combat)
    local P, X = w.P[ev.a], (ev.b - 4 <= #w.E) and w.E[ev.b - 4] or w.E[1]
    local k = ev.kind
    if k == "TurnStarted" or k == "TurnEnded" then w:fire(k, P)
    elseif k == "CastedSpell" then w:fire(k, P, "Projectile_Arrow_" .. ev.s, "Projectile", "None", 0)
    elseif k == "UsingSpellOnTarget" then w:fire(k, P, X, "Projectile_Arrow_" .. ev.s, "Projectile", "None", 0)
    elseif k == "StatusApplied" or k == "StatusRemoved" then w:fire(k, X, "STATUS_" .. ev.s, P, 0)
    elseif k == "RollResult" then w:fire(k, "Attack", P, X, 14, 1, 0)
    elseif k == "HitpointsChanged" then w:fire(k, X, 50 + ev.s % 50)
    elseif k == "AttackedBy" then w:fire(k, X, P, P, "Piercing", ev.s % 12, "Attack", 0)
    else
        local hit = hitObj(w, ev.s)
        local atk = w:obj("AttackDesc", { TotalDamageDone = ev.s % 12, TotalHealDone = 0,
            DamageList = { w:obj("DamagePair", { Amount = ev.s % 12, DamageType = "Piercing" }) } })
        if k == "BeforeDealDamage" then w:throw(k, { Hit = hit, Attack = atk })
        else
            local f = { Caster = w:handle(P), Target = w:handle(X), Hit = hit, Attack = atk, StoryActionId = ev.s,
                SpellId = w:obj("SpellIdWithPrototype", { Prototype = "Projectile_Arrow_" .. ev.s }),
                Originator = w:obj("ActionOriginator", { ActionGuid = mock.guid(ev.s) }) }
            if k == "DealtDamage" then f.Result = w:obj("HitResult", { Hit = hit, Attack = atk, NumConditionRolls = 2,
                Results = { [1] = 1 } }) end
            w:throw(k, f)
        end
    end
end

local function pct(sorted, p)
    if #sorted == 0 then return nil end
    local i = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
    return sorted[i]
end
local function stats(samples)
    table.sort(samples)
    local sum = 0
    for _, v in ipairs(samples) do sum = sum + v end
    return { n = #samples, p50_us = pct(samples, 0.5) / 1000, p95_us = pct(samples, 0.95) / 1000,
        p99_us = pct(samples, 0.99) / 1000, max_us = samples[#samples] / 1000, mean_us = sum / #samples / 1000,
        total_ms = sum / 1e6 }
end

local NULL = REPO .. "/bench/null_recorder.lua"
local CONFIGS = {
    null = { file = NULL },
    baseline = { file = BASE },
    v2_default = { file = V2, cfg = {} },
    v2_lean = { file = V2, cfg = { CHECKPOINT_ON_TURN = false, CHECKPOINT_ON_ACTION = false, RECONCILE_MS = 0,
        DIRTY_QUIET_MS = 1e12, DIRTY_MAX_MS = 1e12 } },
    v2_full = { file = V2, cfg = { MOVEMENT_ENABLED = true, CHECKSUM = "fnv1a32", PROFILE = false } },
}

local TICK_MS = 100

-- One trial: load, combat start, E events with ticks in between, combat end, drain.
local function trial(name, E, N, seed, opts)
    opts = opts or {}
    local c = CONFIGS[name]
    local w = mock.new({ discardFs = not opts.keepFs and not opts.realDisk, t0 = 100000, noIoLog = true })
    if opts.realDisk then
        -- host NTFS writes through Python (lupa call overhead included); still NOT Script Extender I/O
        local dir = REPO .. "/work/bench/disk/" .. name .. "-" .. E .. "-" .. seed .. "/"
        w.ioHook = function(op, path, content)
            host.write_file(dir .. path:gsub("/", "_"), content)
            return "ok"
        end
        w.discardFs = true
    end
    if c.cfg then rawset(w.env, "FightRecV2Config", c.cfg) end
    cast(w, N)
    local load_t0 = hr()
    assert(w:load(c.file, name))
    local load_ns = hr() - load_t0
    local list = workload(E, N, seed)
    -- sample arrays are preallocated so their growth is not counted as recorder memory
    local gapsTotal = 0
    for _, ev in ipairs(list) do gapsTotal = gapsTotal + ev.gap end
    local evs, tickS = {}, {}
    for i = 1, E do evs[i] = 0 end
    for i = 1, gapsTotal // TICK_MS + 64 do tickS[i] = 0 end
    local nev, ntick = 0, 0
    collectgarbage("collect")
    local mem0 = collectgarbage("count")
    if opts.alloc then collectgarbage("stop") end
    local combatId = "COMBAT_" .. mock.guid(4242)
    for _, u in ipairs(w.P) do w.combatOf[u] = combatId end
    for _, u in ipairs(w.E) do w.combatOf[u] = combatId end
    local run_t0, cpu0 = hr(), os.clock()
    local t0 = hr()
    w:fire("CombatStarted", combatId)
    local start_ns = hr() - t0
    local peak, untilTick = mem0, 0
    for i, ev in ipairs(list) do
        local gap = ev.gap
        while gap > 0 do
            local step = math.min(gap, TICK_MS - untilTick)
            w:advance(step)
            gap, untilTick = gap - step, untilTick + step
            if untilTick >= TICK_MS then
                untilTick = 0
                local a = hr()
                w:throw("Tick", { Time = {} })
                ntick = ntick + 1
                tickS[ntick] = hr() - a
            end
        end
        local a = hr()
        dispatch(w, ev, combatId)
        nev = nev + 1
        evs[nev] = hr() - a
        if i % 25 == 0 and not opts.alloc then
            local m = collectgarbage("count")
            if m > peak then peak = m end
        end
    end
    local liveInFight
    if not opts.alloc then
        collectgarbage("collect")
        liveInFight = collectgarbage("count") - mem0 -- retained by the recorder mid-fight (+ live mock objects)
    end
    local rtv = rawget(w.env, "FightRecV2")
    local activePart = rtv and rtv.fight and rtv.fight.stream.part and rtv.fight.stream.part.bytes or nil
    local ioLogEntries = #w.ioLog -- 0 here: benchmark worlds disable the mock's per-write log
    for u in pairs(w.combatOf) do w.combatOf[u] = nil end
    t0 = hr()
    w:fire("CombatEnded", combatId)
    local end_ns = hr() - t0
    for _ = 1, 40 do
        w:advance(TICK_MS)
        local a = hr()
        w:throw("Tick", { Time = {} })
        ntick = ntick + 1
        tickS[ntick] = hr() - a
    end
    for i = #tickS, ntick + 1, -1 do tickS[i] = nil end
    local run_ns, cpu = hr() - run_t0, os.clock() - cpu0
    local allocKB
    if opts.alloc then
        allocKB = collectgarbage("count") - mem0
        collectgarbage("restart")
    end
    local memEnd = collectgarbage("count")
    collectgarbage("collect")
    local live = collectgarbage("count")
    local disk = 0
    for _, s in pairs(w.fsSize) do disk = disk + s end
    for _, s in pairs(w.fs) do disk = disk + #s end
    local rt = rawget(w.env, "FightRecV2")
    local fightRecords
    if rt then
        fightRecords = 0
        for _, s in ipairs(rt.streams) do fightRecords = fightRecords + (s.nextSeq - 1) end
    end
    return { config = name, E = E, N = N, seed = seed, load_ms = load_ns / 1e6, start_ms = start_ns / 1e6,
        end_ms = end_ns / 1e6, run_ms = run_ns / 1e6, cpu_s = cpu, events = stats(evs), ticks = stats(tickS),
        save_calls = w.io.save, append_calls = w.io.append, bytes_requested = w.io.bytes, final_disk_bytes = disk,
        mem_start_kb = mem0, peak_sampled_kb = peak, live_in_fight_delta_kb = liveInFight,
        active_part_bytes_at_measure = activePart, mock_iolog_entries = ioLogEntries, mem_end_kb = memEnd, live_after_gc_kb = live,
        alloc_kb_gc_stopped = allocKB, osiris_calls = w.osiCalls, violations = #w.violations,
        warnings = #w.warnings, v2_open_streams = rt and #rt.streams or nil }
end

local function median(xs)
    table.sort(xs)
    return xs[math.ceil(#xs / 2)]
end

local function calibrate()
    local s = {}
    for i = 1, 20000 do
        local a = hr()
        s[i] = hr() - a
    end
    return stats(s)
end

-- IR-16: bind results to the exact sources and configuration that produced them
local function cfgSnapshot()
    local out = {}
    for name, c in pairs(CONFIGS) do out[name] = { file = c.file:sub(#REPO + 2), cfg = c.cfg } end
    return out
end
local results = { meta = { lua = host.lua_version, lupa = host.lupa_version, tick_ms = TICK_MS, quick = QUICK,
    note = "host/mock measurements; pure-Lua JSON stands in for Ext.Json; no real or SE I/O unless stated",
    sha256 = { recorder = host.sha256_file(V2), baseline = host.sha256_file(BASE), null_recorder = host.sha256_file(NULL),
        bench = host.sha256_file(REPO .. "/bench/bench.lua"), mock_se = host.sha256_file(REPO .. "/tests/mock_se.lua"),
        json = host.sha256_file(REPO .. "/tests/json.lua"), runner = host.sha256_file(REPO .. "/tools/lua54.py") },
    configs = cfgSnapshot(), statistics = "per-trial p50/p99/max; *_med_trial = median over trials; *_max_all = " ..
        "maximum over all trials; memory = whole-harness heap delta; peak sampled every 25 events" },
    calibration = calibrate(), runs = {}, summary = {}, ui = {} }
print(string.format("timer pair overhead: p50 %.3f us, p99 %.3f us (n=%d)", results.calibration.p50_us,
    results.calibration.p99_us, results.calibration.n))

local SIZES = QUICK and { 250, 1000 } or { 500, 1000, 2000, 4000 }
local NS = QUICK and { 8 } or { 8, 24 }
local TRIALS = QUICK and 2 or 5
local order = { "null", "baseline", "v2_default", "v2_lean", "v2_full" }
local function maxOf(rs, f) local m = -1 for _, r in ipairs(rs) do if f(r) > m then m = f(r) end end return m end
local nullMem = {}
for _, N in ipairs(NS) do
    for _, E in ipairs(SIZES) do
        for _, name in ipairs(order) do
            local trials = (E >= 4000) and math.max(2, TRIALS - 2) or TRIALS
            trial(name, math.min(E, 200), N, 7) -- warmup (discarded)
            local rs = {}
            for k = 1, trials do
                local r = trial(name, E, N, 1000 + k)
                rs[#rs + 1] = r
                results.runs[#results.runs + 1] = r
            end
            local function med(f) local xs = {} for _, r in ipairs(rs) do xs[#xs + 1] = f(r) end return median(xs) end
            local sm = { config = name, E = E, N = N, trials = #rs,
                run_ms = med(function(r) return r.run_ms end),
                ev_p50_us_med_trial = med(function(r) return r.events.p50_us end),
                ev_p99_us_med_trial = med(function(r) return r.events.p99_us end),
                ev_max_us_med_trial = med(function(r) return r.events.max_us end),
                ev_max_us_max_all = maxOf(rs, function(r) return r.events.max_us end),
                tick_p99_us_med_trial = med(function(r) return r.ticks.p99_us end),
                tick_max_us_med_trial = med(function(r) return r.ticks.max_us end),
                tick_max_us_max_all = maxOf(rs, function(r) return r.ticks.max_us end),
                bytes_requested = med(function(r) return r.bytes_requested end),
                final_disk_bytes = med(function(r) return r.final_disk_bytes end),
                save_calls = med(function(r) return r.save_calls end),
                peak_sampled_kb = med(function(r) return r.peak_sampled_kb end),
                live_after_gc_kb = med(function(r) return r.live_after_gc_kb end),
                live_in_fight_delta_kb = med(function(r) return r.live_in_fight_delta_kb end),
                event_samples = rs[1].events.n, tick_samples = rs[1].ticks.n, violations = rs[1].violations }
            if name == "null" then nullMem[N .. ":" .. E] = sm.live_in_fight_delta_kb end
            sm.null_control_live_kb = nullMem[N .. ":" .. E]
            results.summary[#results.summary + 1] = sm
            print(string.format("%-11s N=%-3d E=%-5d x%d run %8.1f ms | ev p50 %6.1f p99 %7.1f max(all) %8.1f us | " ..
                "tick p99 %7.1f max(all) %8.1f us | req %10d B disk %8d B saves %5d | heap +%6.0f KB (null +%5.0f)",
                name, N, E, #rs, sm.run_ms, sm.ev_p50_us_med_trial, sm.ev_p99_us_med_trial, sm.ev_max_us_max_all,
                sm.tick_p99_us_med_trial, sm.tick_max_us_max_all, sm.bytes_requested, sm.final_disk_bytes, sm.save_calls,
                sm.live_in_fight_delta_kb, sm.null_control_live_kb or -1))
        end
    end
end

-- Long sessions: is mid-fight retained memory bounded? (one trial each; mock ioLog disabled)
results.long = {}
for _, E in ipairs(QUICK and { 1000 } or { 2000, 8000, 16000 }) do
    for _, name in ipairs({ "null", "baseline", "v2_default", "v2_lean" }) do
        local r = trial(name, E, 8, 900)
        results.long[#results.long + 1] = { config = name, E = E, live_in_fight_delta_kb = r.live_in_fight_delta_kb,
            active_part_bytes = r.active_part_bytes_at_measure, iolog = r.mock_iolog_entries,
            bytes_requested = r.bytes_requested, final_disk_bytes = r.final_disk_bytes, run_ms = r.run_ms,
            tick_max_us = r.ticks.max_us, tick_p99_us = r.ticks.p99_us }
        print(string.format("long %-11s E=%-6d in-fight live +%7.0f KB (active part %s B, mock ioLog %d) | req %11d B " ..
            "disk %9d B | tick p99 %8.1f max %9.1f us | run %8.1f ms", name, E, r.live_in_fight_delta_kb,
            tostring(r.active_part_bytes_at_measure), r.mock_iolog_entries, r.bytes_requested, r.final_disk_bytes,
            r.ticks.p99_us, r.ticks.max_us, r.run_ms))
    end
end

-- Host disk variant: the same trial with every SaveFile really written to work/bench/disk (host NTFS).
results.host_disk = {}
for _, E in ipairs(QUICK and { 250 } or { 1000, 4000 }) do
    for _, name in ipairs({ "baseline", "v2_default" }) do
        local rs = {}
        for k = 1, (QUICK and 1 or 3) do rs[k] = trial(name, E, 8, 500 + k, { realDisk = true }) end
        local tmax, tp99, run = {}, {}, {}
        for k, r in ipairs(rs) do tmax[k], tp99[k], run[k] = r.ticks.max_us, r.ticks.p99_us, r.run_ms end
        local allmax = 0
        for _, v in ipairs(tmax) do if v > allmax then allmax = v end end
        local sm = { config = name, E = E, trials = #rs, tick_p99_us = median(tp99), tick_max_us_med_trial = median(tmax),
            tick_max_us_max_all = allmax,
            run_ms = median(run), bytes_requested = rs[1].bytes_requested, save_calls = rs[1].save_calls }
        results.host_disk[#results.host_disk + 1] = sm
        print(string.format("host-disk %-11s E=%-5d x%d run %8.1f ms | tick p99(med) %8.1f max(all) %9.1f us | req %10d B saves %d",
            name, E, #rs, sm.run_ms, sm.tick_p99_us, sm.tick_max_us_max_all, sm.bytes_requested, sm.save_calls))
    end
end

-- Where the bytes go: final on-disk bytes per record kind for one matched trial (E=1000, N=8).
results.bytes_by_kind = {}
for _, name in ipairs(order) do
    local by, total = {}, 0
    local w
    do
        local c = CONFIGS[name]
        w = mock.new({ t0 = 100000 })
        if c.cfg then rawset(w.env, "FightRecV2Config", c.cfg) end
        cast(w, 8)
        assert(w:load(c.file, name))
        local id = "COMBAT_" .. mock.guid(4242)
        for _, u in ipairs(w.P) do w.combatOf[u] = id end
        for _, u in ipairs(w.E) do w.combatOf[u] = id end
        w:fire("CombatStarted", id)
        for _, ev in ipairs(workload(1000, 8, 1001)) do
            for _ = 1, ev.gap // TICK_MS do w:advance(TICK_MS) w:throw("Tick", { Time = {} }) end
            dispatch(w, ev, id)
        end
        for u in pairs(w.combatOf) do w.combatOf[u] = nil end
        w:fire("CombatEnded", id)
        for _ = 1, 40 do w:advance(TICK_MS) w:throw("Tick", { Time = {} }) end
    end
    for path, content in pairs(w.fs) do
        if path:find("fight01", 1, true) and path:find("%.jsonl$") then
            for line in content:gmatch("[^\n]+") do
                local kind = line:match('"kind":"([^"]+)"') or "?"
                if kind == "checkpoint" then kind = "checkpoint:" .. (line:match('"phase":"([^"]+)"') or "?") end
                by[kind] = (by[kind] or 0) + #line + 1
                total = total + #line + 1
            end
        end
    end
    results.bytes_by_kind[name] = { total = total, by = by }
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return by[a] > by[b] end)
    local parts = {}
    for i = 1, math.min(8, #keys) do parts[#parts + 1] = string.format("%s=%d", keys[i], by[keys[i]]) end
    print(string.format("bytes by kind %-11s total %8d: %s", name, total, table.concat(parts, " ")))
end

-- Allocation volume with the collector stopped (small E only: the baseline's rewrites allocate Theta(E^2)).
results.alloc = {}
for _, name in ipairs(order) do
    for _, E in ipairs(QUICK and { 250 } or { 250, 500, 1000 }) do
        local r = trial(name, E, 8, 77, { alloc = true })
        results.alloc[#results.alloc + 1] = { config = name, E = E, alloc_kb = r.alloc_kb_gc_stopped }
        print(string.format("alloc (GC stopped) %-11s E=%-5d %10.0f KB", name, E, r.alloc_kb_gc_stopped))
    end
end

-- UI: deferred-callback scheduling under a slow Defer (callbacks run only every D ms), old versus new, plus
-- visual-tree search cost for V filler nodes. Mock Noesis objects; scheduling behaviour, not render-thread time.
local function uiRun(file, delayMs, entries, seconds)
    local w = mock.new({ server = false, discardFs = true })
    w:setCombatLog({ entries = entries, filler = 20 })
    assert(w:load(file, "ui"))
    local maxQueued, polls, lastRun = 0, 0, w.t
    local origDefer = w.Ext.UI.Defer
    for _ = 1, seconds * 10 do
        w:advance(100)
        w:throw("Tick", { Time = {} })
        if #w.defers > maxQueued then maxQueued = #w.defers end
        if w.t - lastRun >= delayMs then
            polls = polls + w:runDefers()
            lastRun = w.t
        end
    end
    local rt = rawget(w.env, "FightRecV2") or rawget(w.env, "FightRec")
    return { max_queued_defers = maxQueued, callbacks_run = polls, stale = rt.log and rt.log.stale or nil }
end
local function entriesN(n) local e = {} for i = 1, n do e[i] = { ts = i, text = "Entry " .. i } end return e end
for _, D in ipairs({ 100, 1000, 3000 }) do
    for _, f in ipairs({ { "baseline", BASE }, { "v2", V2 } }) do
        local r = uiRun(f[2], D, entriesN(40), 60)
        r.config, r.defer_delay_ms = f[1], D
        results.ui[#results.ui + 1] = r
        print(string.format("ui defer-delay %5d ms %-8s max queued deferred polls %4d, callbacks run %4d",
            D, f[1], r.max_queued_defers, r.callbacks_run))
    end
end
results.ui_search = {}
for _, V in ipairs(QUICK and { 1000 } or { 1000, 10000, 39000 }) do
    for _, f in ipairs({ { "baseline", BASE }, { "v2", V2 } }) do
        local w = mock.new({ server = false, discardFs = true })
        w:setCombatLog({ entries = entriesN(5), filler = V })
        assert(w:load(f[2], "ui"))
        local rt = rawget(w.env, "FightRecV2") or rawget(w.env, "FightRec")
        local search = rt.ui and rt.ui.searchLog or rt.searchLog
        local samples = {}
        for k = 1, (QUICK and 3 or 7) do
            local root = w.uiRoot()
            local a = hr()
            search(root)
            samples[k] = hr() - a
            w:expireScope()
        end
        local s = stats(samples)
        -- IR-17: with n=7 a p99 is just the maximum; only p50, max and n are reported
        results.ui_search[#results.ui_search + 1] = { config = f[1], V = V, p50_us = s.p50_us, max_us = s.max_us, n = s.n }
        print(string.format("ui search V=%-6d %-8s p50 %9.1f us max %9.1f us (n=%d)", V, f[1], s.p50_us, s.max_us, s.n))
    end
end

-- IR-19: writer-only comparison. Identical pre-encoded lines and timeline for both; no recorder features.
-- old = re-implementation of baseline lines 84-99 semantics (keep every line, rewrite whole history every
-- FLUSH_MS when dirty) minus encoding; new = the v2 Stream (admit + setLine, pump each 100 ms tick).
results.writer_only = {}
-- sizes are fixed up front; each line string is built at admission (as encoding would), so retained history
-- is real memory rather than references to shared strings (quick-run-004 measured the shared-string version)
local function lineSizes(E, seed)
    local rnd, out = lcg(seed), {}
    for i = 1, E do out[i] = 150 + rnd(400) + (rnd(10) == 0 and rnd(4000) or 0) end
    return out
end
local function makeLine(i, size) return string.format('{"seq":%d,"kind":"x","pad":"%s"}', i, string.rep("p", size)) end
local function writerRun(kind, E)
    local w = mock.new({ discardFs = true, noIoLog = true })
    cast(w, 4)
    assert(w:load(V2, "writer"))
    local rt = rawget(w.env, "FightRecV2")
    local L = lineSizes(E, 4711)
    local gaps = workload(E, 8, 4711)
    local ncalls = 3
    for i = 1, E do ncalls = ncalls + gaps[i].gap // TICK_MS end
    local calls, nc, liveMid = {}, 0, nil
    for i = 1, ncalls do calls[i] = 0 end -- preallocated: full-run-006 counted this array's growth as heap
    collectgarbage("collect")
    local mem0, bytes0, saves0 = collectgarbage("count"), w.io.bytes, w.io.save
    local S, old
    if kind == "new" then S = rt.newStream("writerbench", {})
    else old = { lines = {}, dirty = false, at = -1e15 } end
    local function service(force)
        local a = hr()
        if S then S:pump(w.t, force)
        elseif old.dirty and (force or w.t - old.at >= 2000) then
            old.at, old.dirty = w.t, false
            w.Ext.IO.SaveFile("FightRec/old-writer.jsonl", table.concat(old.lines, "\n") .. "\n")
        end
        nc = nc + 1
        calls[nc] = hr() - a
    end
    for i = 1, E do
        for _ = 1, gaps[i].gap // TICK_MS do w:advance(TICK_MS) service(false) end
        if S then
            local seq = S:admit("required", w.t, i, "x")
            S:setLine(seq, makeLine(i, L[i]))
        else
            old.lines[#old.lines + 1] = makeLine(i, L[i])
            old.dirty = true
        end
        if i == E // 2 then collectgarbage("collect") liveMid = collectgarbage("count") - mem0 end
    end
    if S then S:finish(w.t, "bench") end
    for _ = 1, 3 do w:advance(2100) service(true) end
    local st = stats(calls)
    return { writer = kind, E = E, bytes_requested = w.io.bytes - bytes0, save_calls = w.io.save - saves0,
        service_calls = st.n, service_total_ms = st.total_ms, service_p99_us = st.p99_us, service_max_us = st.max_us,
        heap_mid_kb = liveMid, complete = S and S.state or "n/a" }
end
for _, E in ipairs(QUICK and { 1000 } or { 1000, 4000, 16000 }) do
    for _, kind in ipairs({ "old", "new" }) do
        local r = writerRun(kind, E)
        results.writer_only[#results.writer_only + 1] = r
        print(string.format("writer-only %-3s E=%-6d req %11d B saves %5d | service total %8.1f ms p99 %8.1f max %9.1f us " ..
            "(n=%d) | heap mid +%7.0f KB | %s", kind, E, r.bytes_requested, r.save_calls, r.service_total_ms,
            r.service_p99_us, r.service_max_us, r.service_calls, r.heap_mid_kb, r.complete))
    end
end

local out = OUT or (REPO .. "/work/bench/bench-results.json")
host.write_file(out, json.encode(results))
print("results: " .. out)
return 0
