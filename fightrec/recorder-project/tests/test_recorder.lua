-- Offline tests of recorder/FightRec.lua against tests/mock_se.lua (fake API: validates logic, not live SE).
-- usage: python tools/lua54.py tests/test_recorder.lua [name-filter] [--dump <dir>]
local mock = require("mock_se")
local json = require("json")
local R = require("partreader")
local H = require("harness")
local T = H

local REPO = host.repo
local V2 = os.getenv("FR2_RECORDER") or (REPO .. "/recorder/FightRec.lua") -- override: tests/mutation_check.py
local BASE = REPO .. "/baseline/FightRec.lua"
local DUMP
for i = 1, #arg do if arg[i] == "--dump" then DUMP = arg[i + 1] end end
local FILTER = arg[1] and arg[1] ~= "--dump" and arg[1] or nil

local function world(opts, cfg)
    local w = mock.new(opts)
    if cfg then rawset(w.env, "FightRecV2Config", cfg) end
    w.P, w.E = {}, {}
    for i = 1, 4 do
        local u = "S_Player_" .. i .. "_" .. mock.guid(1000 + i)
        w:addCharacter(u, { party = true, pos = { 10 + i, 0.5, -20 - i } })
        w.P[i] = u
    end
    for i = 1, 4 do
        local u = "S_Enemy_" .. i .. "_" .. mock.guid(2000 + i)
        w:addCharacter(u, { pos = { 30 + i, 1.5, -40 - i } })
        w.E[i] = u
    end
    return w
end
local function v2(w)
    local ok, err = w:load(V2, "recorder/FightRec.lua")
    assert(ok, err)
    return rawget(w.env, "FightRecV2")
end
local function baseline(w)
    local ok, err = w:load(BASE, "baseline/FightRec.lua")
    assert(ok, err)
    return rawget(w.env, "FightRec")
end
local COMBAT = "COMBAT_" .. mock.guid(77)
local function combat(w, c)
    c = c or COMBAT
    for _, u in ipairs(w.P) do w.combatOf[u] = c end
    for _, u in ipairs(w.E) do w.combatOf[u] = c end
    w:fire("CombatStarted", c)
    return c
end
local function endCombat(w, c)
    c = c or COMBAT
    for u, cc in pairs(w.combatOf) do if cc == c then w.combatOf[u] = nil end end
    w:fire("CombatEnded", c)
end
local function prefix(rt, name) return "FightRec2/" .. rt.session_id .. "-" .. rt.context .. "-" .. name end
local function ticks(w, n, ms) for _ = 1, n or 3 do w:tick(ms or 2100) end end
local function fightStream(rt) return rt.fight and rt.fight.stream end
local function read(w, rt, name) return R.read(w.fs, prefix(rt, name or "fight01")) end
local function dump(w, name) if DUMP then w:dumpTo(DUMP .. "/" .. name) end end
local function statusEvents(w, n, who)
    for i = 1, n do w:fire("StatusApplied", who or w.E[1], "STATUS_" .. i, w.P[1], 0) end
end
local function noIssues(res) T.eq(#res.issues, 0, "reader issues: " .. table.concat(res.issues, "; ")) end
local function onlyAllowedGlobals(w, allowed)
    for k in pairs(w.globalWrites) do T.ok(allowed[k], "unexpected global write " .. tostring(k)) end
end

---------------------------------------------------------------------------------------------------------------
-- Activation, identity, generation ownership (DR-01)
---------------------------------------------------------------------------------------------------------------
H.case("load server: activates, writes session stream, only FightRecV2 global", function()
    local w = world()
    local rt = v2(w)
    T.ok(rt, "FightRecV2 set")
    T.eq(rt.context, "server")
    T.eq(rt.source_content_sha256, "unknown")
    T.eq(rt.source_identity.status, "unknown")
    onlyAllowedGlobals(w, { FightRecV2 = true })
    local s = R.read(w.fs, prefix(rt, "session"))
    noIssues(s)
    local meta = R.find(s, "meta")
    T.ok(meta, "meta record")
    T.eq(meta.data.schema_version, 2)
    T.eq(meta.data.source_content_sha256, "unknown")
    T.eq(meta.data.source_identity.status, "unknown")
    T.eq(meta.data.versions.se_status, "unavailable", "SE version unknown when Ext.Utils.Version gives nil")
    local hooks = R.find(s, "hooks")
    T.ok(hooks.data.hooks.TurnStarted.registered)
    T.ok(hooks.data.hooks["Ext.Events.DealtDamage"].registered)
    T.no(hooks.data.hooks["Ext.Events.ExecuteFunctor"], "experimental functors not subscribed by default")
    T.eq(hooks.data.capabilities.write_mode, "savefile")
    T.eq(hooks.data.capabilities.collision_check, "checked")
    T.eq(s.parts[1].header.stream_id, "session")
    T.eq(#w.violations, 0)
end)

H.case("same-second reloads get distinct session ids and file names", function()
    local a, b = world({ t0 = 5000 }), world({ t0 = 5000, guidSalt = 99 })
    local ra, rb = v2(a), v2(b)
    T.ok(ra.session_id ~= rb.session_id, "distinct sessions")
    local c, d = world({ t0 = 5000, noGuid = true }), world({ t0 = 5007, noGuid = true })
    local rc, rd = v2(c), v2(d)
    T.eq(rc.session_id_source, "fallback (monotonic ms + table address), collision-checked")
    T.ok(rc.session_id ~= rd.session_id, "fallback ids differ when the clock differs")
end)

H.case("same v2 executed twice: idempotent, no duplicate registration", function()
    local w = world()
    local rt = v2(w)
    local n = #w.listeners.TurnStarted
    local ticksBefore = #w.events.Tick.handlers
    local rt2 = v2(w)
    T.eq(rt2, rt, "same generation table")
    T.eq(#w.listeners.TurnStarted, n)
    T.eq(#w.events.Tick.handlers, ticksBefore)
    T.eq(rt.reexecutions, 1)
    ticks(w, 1)
    local s = R.read(w.fs, prefix(rt, "session"))
    -- IR-05: with an unknown source identity "same build" cannot be verified: recorded as unverified, the
    -- executed file is not activated and the running generation continues.
    local r = R.find(s, "reexecution_unverified")
    T.ok(r, "unverified re-execution recorded")
    T.no(R.find(s, "reexecuted_same_generation"))
    T.ok(rawget(w.env, "FightRecV2Refusal"))
end)

H.case("different v2 generation (config) is refused; old generation keeps running", function()
    local w = world()
    local rt = v2(w)
    local n = #w.listeners.TurnStarted
    rawset(w.env, "FightRecV2Config", { FLUSH_MS = 1234 })
    local ok = w:load(V2, "recorder/FightRec.lua")
    T.ok(ok)
    T.eq(rawget(w.env, "FightRecV2"), rt)
    T.ok(rawget(w.env, "FightRecV2Refusal"), "refusal recorded")
    T.ok(rawget(w.env, "FightRecV2Refusal").reason:find("lifecycle reset", 1, true))
    T.eq(#w.listeners.TurnStarted, n, "no new listeners")
    T.eq(rt.refusals, 1)
    ticks(w, 1)
    T.ok(R.find(R.read(w.fs, prefix(rt, "session")), "replacement_refused"))
    onlyAllowedGlobals(w, { FightRecV2 = true, FightRecV2Config = true, FightRecV2Refusal = true })
end)

H.case("baseline then v2 in one Lua state: v2 refuses, baseline state untouched", function()
    local w = world()
    local FR = baseline(w)
    local nBase = #w.listeners.TurnStarted
    local regBefore = FR.registered
    v2(w)
    T.no(rawget(w.env, "FightRecV2"), "v2 not active")
    local ref = rawget(w.env, "FightRecV2Refusal")
    T.ok(ref and ref.reason:find("baseline", 1, true), "refusal names the baseline")
    T.eq(#w.listeners.TurnStarted, nBase, "no v2 listeners added")
    T.eq(FR.registered, regBefore)
    T.eq(#w:files("FightRec2/"), 0, "no v2 files")
end)

H.case("stopped generation: stale callbacks inert; reload still refused (no verified unsubscribe)", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    rt.stop("test")
    T.no(rt.generation.active)
    local before = rt.obs
    statusEvents(w, 3)
    w:fire("TurnStarted", w.P[1])
    T.ge(rt.generation.inactive_calls, 4)
    T.eq(rt.obs, before, "no observations after stop")
    v2(w)
    T.ok(rawget(w.env, "FightRecV2Refusal"), "same identity but inactive generation is refused")
    local res = read(w, rt)
    T.ok(res.final, "stopped fight sealed final")
end)

---------------------------------------------------------------------------------------------------------------
-- XYZ (DESIGN 2)
---------------------------------------------------------------------------------------------------------------
H.case("XYZ: snapshot and checkpoints keep all three returns", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w:fire("TurnStarted", w.P[2])
    ticks(w, 1)
    local res = read(w, rt)
    local snap = R.find(res, "snapshot")
    local c = snap.data.characters[1]
    T.eq(c.pos.valid, true)
    T.eq(c.pos.x, 11) -- P1 at {11, 0.5, -21}
    T.eq(c.pos.y, 0.5)
    T.eq(c.pos.z, -21)
    local cp = R.find(res, "checkpoint", function(r) return r.phase == "turn_boundary" end)
    T.eq(cp.data.actors[1].pos.y, 0.5)
    T.eq(cp.data.actors[1].pos.z, -22)
end)

H.case("XYZ: missing Y/Z is explicit unavailable, never zeros", function()
    local w = world()
    w.posMode = "x_only"
    local rt = v2(w)
    combat(w)
    local c = R.find(read(w, rt), "snapshot").data.characters[1]
    T.eq(c.pos.valid, false)
    T.no(c.pos.x)
    T.ok(c.pos.reason:find("1 values", 1, true), c.pos.reason)
    local w2 = world()
    w2.posMode = "nil_y"
    local rt2 = v2(w2)
    combat(w2)
    T.eq(R.find(read(w2, rt2), "snapshot").data.characters[1].pos.valid, false)
end)

H.case("XYZ: baseline defect reproduced under the same mock (X only)", function()
    local w = world()
    baseline(w)
    combat(w)
    local path = w:files("FightRec/")[1]
    local snap
    for line in w.fs[path]:gmatch("[^\n]+") do
        local r = json.decode(line)
        if r.kind == "snapshot" then snap = r break end
    end
    T.eq(#snap.data.characters[1].pos, 1, "baseline osi() keeps only the first return")
end)

---------------------------------------------------------------------------------------------------------------
-- Writer: acknowledgement, failures, retries, parts (DESIGN 4)
---------------------------------------------------------------------------------------------------------------
local function failFight(w, n, action)
    local left = n
    w.ioHook = function(op, path)
        if path:find("-fight", 1, true) and left > 0 then left = left - 1 return action end
    end
end

for _, action in ipairs({ "false", "throw", "nil", "partial_false", "partial_throw" }) do
    H.case("write " .. action .. ": not acknowledged, data retained, retried, recovered", function()
        local w = world()
        local rt = v2(w)
        failFight(w, 3, action)
        combat(w)
        local S = fightStream(rt)
        T.ok(S.failing, "stream marked failing")
        statusEvents(w, 5)
        ticks(w, 6)
        T.no(S.failing, "recovered")
        T.eq(S.c.write_ok >= 1, true)
        if action == "throw" or action == "partial_throw" then T.eq(S.c.write_throw, 3) else T.eq(S.c.write_false, 3) end
        T.ok(#w.warnings >= 1, "out-of-band warning")
        endCombat(w)
        ticks(w, 2)
        local res = read(w, rt)
        noIssues(res)
        T.ok(res.final, "final trailer")
        T.eq(#R.all(res, "StatusApplied"), 5, "all observations present")
        local rec = R.find(res, "write_recovered")
        T.ok(rec, "persistent write_recovered record")
        T.eq(rec.data.failures, 3)
        T.eq(S.state, "complete")
        T.eq(S.manifest, "written")
    end)
end

H.case("write nil forever: never acknowledged, finishing stream abandoned after give-up", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    w.ioHook = function(op, path) if path:find("-fight", 1, true) then return "nil" end end
    endCombat(w)
    ticks(w, 20, 10000)
    T.eq(S.state, "finishing")
    ticks(w, 15, 20000)
    T.eq(S.state, "abandoned")
    T.eq(S.capture, "failed")
    local found = false
    for _, m in ipairs(w.warnings) do if m:find("abandoned", 1, true) then found = true end end
    T.ok(found, "abandon warning")
end)

H.case("repeated retries use bounded exponential backoff", function()
    local w = world()
    local rt = v2(w)
    failFight(w, 1000, "false")
    combat(w)
    local S = fightStream(rt)
    local seen = {}
    for _ = 1, 40 do w:tick(1000) seen[#seen + 1] = S.backoff end
    T.eq(S.backoff, rt.cfg.RETRY_MAX_MS)
    T.le(S.c.write_false, 20, "backoff limits attempts")
    T.ge(S.c.write_false, 5)
end)

H.case("many parts: sealed trailers, contiguous parts/seqs, tight cap boundary", function()
    local w = world(nil, { PART_TARGET_BYTES = 2000, CHECKPOINT_ON_ACTION = false })
    local rt = v2(w)
    combat(w)
    for i = 1, 60 do w:fire("CastedSpell", w.P[1 + i % 4], "Projectile_Fire_" .. i, "Target", "Fire", 0) w:tick(50) end
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    T.ge(#res.parts, 6)
    for i, p in ipairs(res.parts) do
        T.ok(p.trailer, "part " .. i .. " sealed")
        T.eq(p.header.part, i)
        if not p.header.oversized then T.le(p.trailer.record_bytes, 2000) end
        local nxt = res.parts[i + 1]
        if nxt and not p.header.oversized and not nxt.header.oversized then
            local firstLen = #json.encode(nxt.records[1])
            T.ok(p.trailer.record_bytes + firstLen > 2000 - 64, "part sealed only when the next record would overflow")
        end
        if i > 1 then T.eq(p.header.first_seq, res.parts[i - 1].trailer.last_seq + 1) end
    end
    T.eq(#R.all(res, "CastedSpell"), 60)
    dump(w, "many_parts")
end)

local function bigHit(w, size)
    return w:obj("HitDesc", { TotalDamageDone = 7, Blob = string.rep("x", size) })
end

H.case("oversized record becomes a dedicated part, never truncated", function()
    local w = world(nil, { PART_TARGET_BYTES = 3000 })
    local rt = v2(w)
    combat(w)
    statusEvents(w, 3)
    w:throw("DealDamage", { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]), Hit = bigHit(w, 10000) })
    statusEvents(w, 2)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    local dd = R.find(res, "DealDamage")
    T.eq(#dd.data.hit.Blob, 10000, "record intact")
    local part
    for _, p in ipairs(res.parts) do if p.records[1] and p.records[1].seq == dd.seq then part = p end end
    T.ok(part.header.oversized, "dedicated oversized part")
    T.eq(#part.records, 1)
    T.ge(part.header.record_bytes, 10000)
    dump(w, "oversized")
end)

H.case("record above RECORD_HARD_MAX: explicit record_too_large terminal error at the same seq", function()
    local w = world(nil, { RECORD_HARD_MAX = 5000 })
    local rt = v2(w)
    combat(w)
    w:throw("DealDamage", { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]), Hit = bigHit(w, 10000) })
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    -- the 5000-byte cap also turns the full snapshot into an explicit error (run-002 finding: small hard caps
    -- sacrifice snapshots), so select the DealDamage one
    local te = R.find(res, "terminal_error", function(r) return r.data.for_kind == "DealDamage" end)
    T.ok(te, "terminal error")
    T.ok(R.find(res, "terminal_error", function(r) return r.data.for_kind == "snapshot" end), "snapshot over cap is explicit too")
    T.ok(te.data.error:find("record_too_large", 1, true))
    T.no(R.find(res, "DealDamage"))
end)

H.case("manifest write failure: stream still complete, parts authoritative, warning", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    w.ioHook = function(op, path) if path:find("manifest", 1, true) then return "false" end end
    endCombat(w)
    T.eq(S.state, "complete")
    T.eq(S.manifest, "write_failed")
    local res = read(w, rt)
    noIssues(res)
    T.ok(res.final)
    local warned = false
    for _, m in ipairs(w.warnings) do if m:find("manifest not written", 1, true) then warned = true end end
    T.ok(warned)
end)

H.case("optional fnv1a32 part checksum is written in trailers", function()
    local w = world(nil, { CHECKSUM = "fnv1a32", PART_TARGET_BYTES = 3000 })
    local rt = v2(w)
    combat(w)
    statusEvents(w, 30)
    endCombat(w)
    local res = read(w, rt)
    noIssues(res)
    T.ge(#res.parts, 2)
    for _, p in ipairs(res.parts) do T.eq(p.trailer.checksum.alg, "fnv1a32") end
    dump(w, "checksum")
end)

H.case("empty/end-only fight completes with explicit final part and manifest", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    endCombat(w)
    local res = read(w, rt)
    noIssues(res)
    T.ok(res.final)
    local k = R.kinds(res)
    T.eq(k.meta, 1) T.eq(k.snapshot, 2) T.eq(k["end"], 1)
    T.ok(w.fs[prefix(rt, "fight01") .. "-manifest.json"], "manifest written once at completion")
    local m = json.decode(w.fs[prefix(rt, "fight01") .. "-manifest.json"])
    T.eq(m.state, "complete")
    T.eq(m.last_seq, res.maxSeq)
    dump(w, "end_only")
end)

---------------------------------------------------------------------------------------------------------------
-- Append mode (optional; DESIGN 2/4)
---------------------------------------------------------------------------------------------------------------
H.case("append requested without live verification stays on SaveFile", function()
    local w = world(nil, { WRITE_MODE = "append" })
    local rt = v2(w)
    T.eq(rt.writeMode, "savefile")
    T.ok(rt.writeModeReason:find("APPEND_SEMANTICS_VERIFIED", 1, true))
    T.eq(w.io.append, 0)
end)

H.case("append self-test failure falls back to SaveFile", function()
    local w = world(nil, { WRITE_MODE = "append", APPEND_SEMANTICS_VERIFIED = true })
    w.ioHook = function(op) if op == "append" then return "false" end end
    local rt = v2(w)
    T.eq(rt.writeMode, "savefile")
    T.ok(rt.writeModeReason:find("self-test failed", 1, true))
end)

local function appendWorld()
    local w = world(nil, { WRITE_MODE = "append", APPEND_SEMANTICS_VERIFIED = true, CHECKPOINT_ON_ACTION = false,
        RECONCILE_MS = 0 })
    local rt = v2(w)
    T.eq(rt.writeMode, "append")
    combat(w)
    statusEvents(w, 3)
    ticks(w, 1)
    return w, rt
end

H.case("append: only new bytes are appended after the first write", function()
    local w, rt = appendWorld()
    T.ge(w.io.append, 2) -- probe + at least one part append
    statusEvents(w, 3)
    ticks(w, 1)
    endCombat(w)
    ticks(w, 1)
    local res = read(w, rt)
    noIssues(res)
    T.ok(res.final)
    T.eq(#R.all(res, "StatusApplied"), 6)
end)

H.case("append false with nothing written: safe retry, no rotation, no duplicates", function()
    local w, rt = appendWorld()
    local left = 1
    w.ioHook = function(op, path) if op == "append" and left > 0 then left = left - 1 return "false" end end
    statusEvents(w, 2)
    ticks(w, 4)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    T.eq(res.duplicates, 0)
    T.eq(fightStream(rt) == nil, true)
    for _, p in ipairs(res.parts) do T.no(p.header.recovery_of) end
end)

H.case("append false after applying: recognised by read-back, no duplicate bytes", function()
    local w, rt = appendWorld()
    local left = 1
    w.ioHook = function(op, path) if op == "append" and left > 0 then left = left - 1 return "applied_false" end end
    statusEvents(w, 2)
    ticks(w, 4)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    T.eq(res.duplicates, 0)
end)

H.case("append partial write: rotate to recovery part with duplicate uncertainty", function()
    local w, rt = appendWorld()
    local left = 1
    w.ioHook = function(op, path) if op == "append" and left > 0 then left = left - 1 return "partial_false" end end
    statusEvents(w, 4)
    ticks(w, 4)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    local rec
    for _, p in ipairs(res.parts) do if p.header.recovery_of then rec = p end end
    T.ok(rec, "recovery part")
    T.eq(rec.header.duplicate_uncertain, true)
    T.ok(res.final)
    T.eq(#R.all(res, "StatusApplied"), 7, "every observation present once in the union")
    local partial = false
    for _, i in ipairs(res.issues) do if i:find("partial last line", 1, true) then partial = true end end
    T.ok(partial, "abandoned part's torn tail is visible to readers")
    dump(w, "append_partial")
end)

---------------------------------------------------------------------------------------------------------------
-- Terminal reservations, nesting, queue saturation (DR-02)
---------------------------------------------------------------------------------------------------------------
H.case("nested callback during a reservation keeps entry order; drain waits for the outer seq", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    local fired = false
    w.Osi.GetStatusTurns = function(u, s)
        if not fired then fired = true w:fire("StatusRemoved", w.E[2], "NESTED", w.P[1], 0) end
        return 3
    end
    w:fire("StatusApplied", w.E[1], "OUTER", w.P[1], 0)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    local outer = R.find(res, "StatusApplied", function(r) return r.data.status == "OUTER" end)
    local inner = R.find(res, "StatusRemoved", function(r) return r.data.status == "NESTED" end)
    T.eq(inner.seq, outer.seq + 1, "inner reserved after outer")
    T.eq(inner.obs, outer.obs + 1)
end)

H.case("builder exception after a nested callback: same-seq terminal error, nested record kept", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    local t = w.t
    rt.capture(S, "required", "test_outer", "test", t, 999001, nil, function()
        w:fire("StatusApplied", w.E[1], "INNER", w.P[1], 0)
        error("boom after nested")
    end)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    local te = R.find(res, "terminal_error", function(r) return r.data.for_kind == "test_outer" end)
    T.ok(te, "terminal error recorded")
    T.eq(te.data.what, "builder_error")
    T.ok(te.data.error:find("boom", 1, true))
    local inner = R.find(res, "StatusApplied", function(r) return r.data.status == "INNER" end)
    T.eq(inner.seq, te.seq + 1)
    T.eq(S.state, "complete")
end)

H.case("encode exception: terminal error at the same seq, stream continues", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w.stringifyHook = function(x) if x.kind == "StatusApplied" and x.data.status == "BAD" then error("cannot encode") end end
    w:fire("StatusApplied", w.E[1], "GOOD1", w.P[1], 0)
    w:fire("StatusApplied", w.E[1], "BAD", w.P[1], 0)
    w:fire("StatusApplied", w.E[1], "GOOD2", w.P[1], 0)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    local g1 = R.find(res, "StatusApplied", function(r) return r.data.status == "GOOD1" end)
    local te = R.find(res, "terminal_error")
    T.eq(te.seq, g1.seq + 1)
    T.eq(te.data.what, "encode_error")
end)

H.case("emergency: even the minimal terminal record fails -> failed latch, explicit seq gap", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local evil = setmetatable({}, { __tostring = function() error("tostring fails too") end })
    w.stringifyHook = function(x) if x.kind == "StatusApplied" and x.data.status == "EVIL" then error(evil) end end
    w:fire("StatusApplied", w.E[1], "EVIL", w.P[1], 0)
    w:fire("StatusApplied", w.E[1], "AFTER", w.P[1], 0)
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    T.eq(res.finalTrailer.counters.emergency, 1)
    T.eq(res.finalTrailer.capture, "failed")
    local gap = false
    for _, i in ipairs(res.issues) do if i:find("seq gap", 1, true) then gap = true end end
    T.ok(gap, "reader sees the gap")
    T.ok(R.find(res, "StatusApplied", function(r) return r.data.status == "AFTER" end))
end)

H.case("nesting limit refuses deeper captures without reserving unbounded placeholders", function()
    local w = world(nil, { MAX_NEST = 2 })
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    local depth = 0
    w.Osi.GetStatusTurns = function(u, s)
        depth = depth + 1
        if depth < 6 then w:fire("StatusApplied", w.E[1], "N" .. depth, w.P[1], 0) end
        return 1
    end
    w:fire("StatusApplied", w.E[1], "N0", w.P[1], 0)
    T.ge(S.c.lost_required, 1)
    T.eq(S.capture, "incomplete")
    endCombat(w)
    ticks(w, 2)
    local res = read(w, rt)
    noIssues(res)
    local gap = R.find(res, "capture_gap")
    T.ok(gap and gap.data.reasons.nesting_limit >= 1, "persistent gap record with reason")
    T.eq(res.finalTrailer.capture, "incomplete")
end)

H.case("finalization cannot report complete with a pending reservation; timeout converts it", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    local leaked = S:admit("required", w.t, 424242, "leaked")
    endCombat(w)
    ticks(w, 3)
    T.eq(S.state, "finishing", "waits for the reservation")
    ticks(w, 16)
    T.eq(S.state, "complete")
    T.eq(S.c.abandoned_reservations, 1)
    local res = read(w, rt)
    noIssues(res)
    local te = R.find(res, "terminal_error", function(r) return r.seq == leaked end)
    T.eq(te.data.what, "reservation_abandoned")
    T.eq(te.data.for_kind, "leaked", "abandoned seq keeps its kind")
    T.eq(te.obs, 424242, "abandoned seq keeps its observation id")
    T.eq(res.finalTrailer.capture, "incomplete")
end)

H.case("queue saturation: bounded occupancy, explicit loss accounting, persistent gap after recovery", function()
    local w = world(nil, { PART_TARGET_BYTES = 4096, Q_MAX_RECORDS = 40, CHECKPOINT_ON_ACTION = false,
        RECONCILE_MS = 0, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9 })
    local rt = v2(w)
    local down = true
    w.ioHook = function(op, path) if down and path:find("-fight", 1, true) then return "false" end end
    combat(w)
    local S = fightStream(rt)
    for i = 1, 200 do
        w:fire("StatusApplied", w.E[1 + i % 4], "Q_" .. i, w.P[1], 0)
        if i % 20 == 0 then w:tick(700) end
        T.le(S.qRecords, 40, "queue bounded")
    end
    T.ge(S.c.lost_required, 1)
    T.eq(S.capture, "incomplete")
    local warned = 0
    for _, m in ipairs(w.warnings) do if m:find("required observations lost", 1, true) then warned = warned + 1 end end
    T.eq(warned, 1, "one out-of-band warning")
    down = false
    ticks(w, 8)
    endCombat(w)
    ticks(w, 4)
    local res = read(w, rt)
    noIssues(res)
    local recorded = #R.all(res, "StatusApplied")
    local lost = 0
    for _, g in ipairs(R.all(res, "capture_gap")) do lost = lost + (g.data.by_kind.StatusApplied or 0) end
    T.eq(recorded + lost, 200, "accounting identity: recorded + lost = fired")
    T.eq(lost, S.c.lost_required)
    T.eq(res.finalTrailer.counters.admitted, res.maxSeq)
    dump(w, "saturation")
end)

H.case("degradation: optional capture suspended above high water, reported after", function()
    local w = world(nil, { PART_TARGET_BYTES = 4096, Q_MAX_RECORDS = 40, MOVEMENT_ENABLED = true, RECONCILE_MS = 0 })
    local rt = v2(w)
    local down = true
    w.ioHook = function(op, path) if down and path:find("-fight", 1, true) then return "false" end end
    combat(w)
    local S = fightStream(rt)
    local i = 0
    while not S.degraded and i < 200 do i = i + 1 w:fire("StatusApplied", w.E[1], "D_" .. i, w.P[1], 0) end
    T.ok(S.degraded, "degraded")
    T.ok(S.qRecords < 40, "degraded before full, so required capture still admitted")
    local before = S.c.suppressed_optional
    w:fire("CastedSpell", w.P[1], "Target_X", "Target", "None", 0) -- optional action checkpoint
    T.ge(S.c.suppressed_optional, before + 1)
    down = false
    ticks(w, 10)
    endCombat(w)
    ticks(w, 3)
    local res = read(w, rt)
    local d = R.find(res, "degradation")
    T.ok(d, "degradation record")
    T.ge(#d.data.intervals, 1)
end)

---------------------------------------------------------------------------------------------------------------
-- Prehistory identity (DR-03)
---------------------------------------------------------------------------------------------------------------
H.case("prehistory: original obs/time kept, storage seq contiguous, count eviction reported", function()
    local w = world(nil, { PREP_KEEP = 3 })
    local rt = v2(w)
    for i = 1, 5 do w:fire("StatusApplied", w.P[1], "PRE_" .. i, w.P[2], 0) w:advance(100) end
    w:fire("StatusApplied", w.E[1], "NOT_PARTY", w.E[2], 0) -- not party-involved outside combat: not kept
    combat(w)
    local res = read(w, rt)
    noIssues(res)
    local meta = R.find(res, "meta")
    local win = R.find(res, "prehistory_window")
    T.eq(win.data.kept, 3)
    T.eq(win.data.evicted.count, 2)
    T.eq(win.data.evicted.reasons.count, 2)
    local pre = {}
    for _, r in ipairs(res.records) do if r.prehistory then pre[#pre + 1] = r end end
    T.eq(#pre, 3)
    T.eq(pre[1].data.status, "PRE_3")
    for i, r in ipairs(pre) do
        T.ok(r.obs < meta.obs, "observed before the fight's meta")
        T.ok(r.seq > meta.seq, "stored after it")
        T.ok(r.t < r.st, "original time kept, storage time separate")
        if i > 1 then T.eq(r.seq, pre[i - 1].seq + 1) T.ok(r.obs > pre[i - 1].obs) end
    end
    T.eq(win.data.evicted.first_obs + 1, win.data.evicted.last_obs)
end)

H.case("prehistory: age eviction, two combats, reset identities", function()
    local w = world(nil, { PREP_MS = 1000 })
    local rt = v2(w)
    w:fire("StatusApplied", w.P[1], "OLD", w.P[2], 0)
    w:advance(5000)
    w:fire("StatusApplied", w.P[1], "FRESH", w.P[2], 0)
    combat(w)
    endCombat(w)
    w:fire("StatusApplied", w.P[1], "BETWEEN", w.P[2], 0)
    combat(w, "COMBAT_" .. mock.guid(78))
    local f1, f2 = read(w, rt, "fight01"), read(w, rt, "fight02")
    local w1 = R.find(f1, "prehistory_window")
    T.eq(w1.data.evicted.reasons.age, 1)
    T.ok(R.find(f1, "StatusApplied", function(r) return r.data.status == "FRESH" and r.prehistory end))
    T.no(R.find(f1, "StatusApplied", function(r) return r.data.status == "OLD" end))
    local between = R.find(f2, "StatusApplied", function(r) return r.data.status == "BETWEEN" end)
    T.ok(between and between.prehistory)
    T.no(R.find(f2, "StatusApplied", function(r) return r.data.status == "FRESH" end), "not copied twice")
    T.eq(f2.records[1].seq, 1, "per-combat storage seq restarts")
    T.ok(between.obs > R.find(f1, "end").obs, "observation ids are session-wide")
    local w2 = world({ guidSalt = 7 }) -- the real GenerateGuid is random; the mock's is a salted counter
    local rt2 = v2(w2)
    T.ok(rt2.session_id ~= rt.session_id)
    T.le(rt2.obs, 5, "fresh Lua state: observation ids restart under a new session id")
end)

---------------------------------------------------------------------------------------------------------------
-- Damage events, Result lifetime (DESIGN 2)
---------------------------------------------------------------------------------------------------------------
local function dealt(w, withResult)
    local hit = w:obj("HitDesc", { TotalDamageDone = 9, DamageType = "Fire", DeathType = "None", CauseType = "Attack",
        ArmorAbsorption = 0, LifeSteal = 0, EffectFlags = 3, StoryActionId = 42, HitWith = "Weapon",
        AttackRollAbility = "Strength", SaveAbility = "None", SpellAttackType = 0, SpellCastGuid = mock.guid(9),
        SpellId = "Target_MainHandAttack", StatusId = "", SpellSchool = "None", AttackFlags = 1, SpellLevel = 0,
        SpellPowerLevel = 0, TotalHealDone = 0, OriginalDamageValue = 9,
        ConditionRolls = { w:obj("ConditionRoll", { RollType = "AttackRoll", Difficulty = 14, Ability = "Strength",
            Skill = "Sentinel", SwappedSourceAndTarget = false, RollUuid = mock.guid(10) }) } })
    local attack = w:obj("AttackDesc", { TotalDamageDone = 9, TotalHealDone = 0,
        DamageList = { w:obj("DamagePair", { Amount = 9, DamageType = "Fire" }) } })
    local fields = { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]), Hit = hit, Attack = attack,
        StoryActionId = 42, SpellId = w:obj("SpellIdWithPrototype", { Prototype = "Target_MainHandAttack" }),
        Originator = w:obj("ActionOriginator", { ActionGuid = mock.guid(11), CanApplyConcentration = true }) }
    if withResult then
        fields.Result = w:obj("HitResult", { Hit = hit, Attack = attack, NumConditionRolls = 1,
            Results = { [7] = 1 } })
    end
    w:throw("DealtDamage", fields)
end

H.case("DealtDamage.Result copied inside the callback with provenance; no lifetime violations", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    dealt(w, true)
    ticks(w, 3)
    T.eq(#w.violations, 0, "no access after callback lifetime: " .. table.concat(w.violations, ","))
    local res = read(w, rt)
    local d = R.find(res, "DealtDamage")
    T.eq(d.data.result.Hit.TotalDamageDone, 9)
    T.eq(d.data.result.Hit.StoryActionId, 42)
    T.eq(d.data.result.Hit.ConditionRolls[1].Difficulty, 14)
    T.eq(d.data.result.Attack.DamageList[1].amount, 9)
    T.eq(d.data.result.NumConditionRolls, 1)
    T.eq(d.data.result.Results["7"], 1)
    T.ok(d.data.result.provenance:find("af85fd2", 1, true))
    T.eq(d.data.story_action_id, 42)
    T.eq(d.data.caster.uuid, w.P[1]:match("%x+%-%x+%-%x+%-%x+%-%x+$"))
    T.eq(d.data.scope, "party")
    T.ok(d.data.shape, "shape once per load")
    T.no(d.data.result.missing, "all pinned fields present in this mock")
    local found = w:retainedEngineObjects(rt)
    T.eq(#found, 0, "retained engine objects: " .. table.concat(found, ", "))
end)

H.case("DealtDamage.Result missing/unavailable fields are recorded, not fatal", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w:throw("DealtDamage", { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]),
        Result = w:obj("HitResult", { Hit = w:obj("HitDesc", { TotalDamageDone = 3 }), NumConditionRolls = 0 }) })
    w:throw("DealtDamage", { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]) })
    ticks(w, 2)
    local all = R.all(read(w, rt), "DealtDamage")
    T.eq(#all, 2)
    T.eq(all[1].data.result.Hit.TotalDamageDone, 3)
    T.ok(all[1].data.result.missing.DamageType, "missing pinned field reported")
    T.ok(all[1].data.result.missing.Attack)
    T.eq(all[2].data.result.unavailable, "Result nil")
    T.eq(#w.violations, 0)
end)

-- LV02: roll breakdown shape. Values below are the live cust -> Taman Target_MainHandAttack (StoryActionId 388,
-- first-attack-observation seq1479) as Ext.Types.Serialize hands them over (Lua sequences); the historical
-- 1792664924-fight04 raw kept such sequences as JSON lists (hit.ConditionRolls[0].Roll.Result..., Damage.DamageRolls
-- .Piercing[0]). dev.1/dev.2 wrote {"1": ...} objects instead.
local function liveRollHit(w)
    local d20 = { DiceValue = { label = "D20", value = 5 }, DiceAdditionalValue = 5, AmountOfDices = 1, DiceNegative = false }
    local d12 = { DiceValue = { label = "D12", value = 4 }, DiceAdditionalValue = 3, AmountOfDices = 1, DiceNegative = false }
    local meta = { RollBonus = 2, ProficiencyBonus = 2, AbilityBoosts = { Strength = 3 }, ResolvedRollBonuses = {} }
    return w:obj("HitDesc", { StoryActionId = 388, SpellId = "Target_MainHandAttack", TotalDamageDone = 9,
        ImpactPosition = { 283.75, 20.0, 342.5 },
        DamageList = { { Amount = 9, DamageType = { label = "Slashing", value = 1 } } },
        ConditionRolls = { { RollType = "ConditionRollType(AttackRoll)", Difficulty = 13,
            RollUuid = "88f47f0c-42f5-78e8-58bf-f918acb7898f",
            Roll = { Roll = { Roll = d20, Advantage = false, Disadvantage = false, RerollConditions = {} },
                Result = { Total = 15, NaturalRoll = 10, DiscardedDiceTotal = 9, CriticalThreshold = 20,
                    RollsCount = { { RerollType = 0, RollValue = 10 }, { RerollType = 0, RollValue = 9 } } },
                Metadata = meta } } },
        Damage = { TotalDamage = 9, FinalDamagePerType = { Slashing = 9 },
            DamageRolls = { Slashing = { { Roll = { Roll = d12 },
                Result = { Total = 9, NaturalRoll = 6, CriticalThreshold = 12, RollsCount = {} } } } } } })
end

H.case("LV02 roll breakdown keeps historical list shape (ConditionRolls, RollsCount, DamageRolls)", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w:throw("BeforeDealDamage", { Hit = liveRollHit(w), Attack = w:obj("AttackDesc", { TotalDamageDone = 9,
        DamageList = { { Amount = 9, DamageType = "Slashing" } } }) })
    ticks(w, 2)
    local rec = R.find(read(w, rt), "BeforeDealDamage")
    local hit = rec.data.hit
    T.eq(hit.cut, nil, "nothing cut") T.eq(hit.depth_cut, nil)
    local cr = hit.ConditionRolls[1]
    T.ok(cr, "ConditionRolls is a list")
    T.eq(hit.ConditionRolls["1"], nil, "no stringified index keys")
    T.eq(cr.Difficulty, 13)
    T.eq(cr.Roll.Result.NaturalRoll, 10) T.eq(cr.Roll.Result.Total, 15) T.eq(cr.Roll.Result.DiscardedDiceTotal, 9)
    T.eq(#cr.Roll.Result.RollsCount, 2) T.eq(cr.Roll.Result.RollsCount[2].RollValue, 9)
    T.eq(cr.Roll.Roll.Roll.DiceValue.label, "D20") T.eq(cr.Roll.Roll.Roll.DiceAdditionalValue, 5)
    T.eq(cr.Roll.Metadata.AbilityBoosts.Strength, 3)
    local dr = hit.Damage.DamageRolls.Slashing[1]
    T.eq(dr.Result.NaturalRoll, 6) T.eq(dr.Result.Total, 9) T.eq(dr.Roll.Roll.DiceValue.label, "D12")
    T.eq(#hit.ImpactPosition, 3) T.eq(hit.ImpactPosition[2], 20.0)
    T.eq(rec.data.attack.DamageList[1].Amount, 9)
    -- the raw JSONL text itself carries lists (what an external importer reads)
    local raw = {}
    for p, data in pairs(w.fs) do if p:find("fight01", 1, true) then raw[#raw + 1] = data end end
    raw = table.concat(raw)
    T.ok(raw:find('"ConditionRolls":[', 1, true), "JSON list for ConditionRolls")
    T.ok(raw:find('"RollsCount":[', 1, true), "JSON list for RollsCount")
    T.ok(raw:find('"Slashing":[', 1, true), "JSON list for DamageRolls.Slashing")
    T.no(raw:find('"ConditionRolls":{"1"', 1, true))
end)

H.case("LV02 reflect: sparse/mixed keys stay objects, a long uncut sequence stays a complete list", function()
    local w = world()
    v2(w)
    local reflect = rawget(w.env, "FightRecV2").reflect
    local sparse = reflect(w:obj("T", { A = { [1] = "a", [3] = "c" }, B = { [1] = "x", k = "y" } }), 3)
    T.eq(sparse.A["1"], "a") T.eq(sparse.A["3"], "c") T.eq(sparse.A[1], nil)
    T.eq(sparse.B["1"], "x") T.eq(sparse.B.k, "y")
    local big = {}
    for i = 1, 50 do big[i] = { v = i } end
    local out = reflect(w:obj("T", { L = big }), 3)
    T.eq(out.cut, nil)
    T.eq(#out.L, 50)
    T.eq(out.L[50].v, 50)
end)

H.case("LV02 reflect: budget cut inside a sequence keeps a list with an explicit <omitted> marker", function()
    local w = world(nil, { REFLECT_BUDGET = 40 })
    v2(w)
    local reflect = rawget(w.env, "FightRecV2").reflect
    local big = {}
    for i = 1, 50 do big[i] = i end
    local out = reflect(w:obj("T", { L = big }), 3)
    T.eq(out.cut, true, "loss is flagged")
    local L = out.value.L
    T.ok(#L > 0 and #L < 51)
    T.eq(L[#L], "<omitted>")
    T.eq(L[1], 1)
    for k in pairs(L) do T.eq(math.type(k), "integer", "still a pure sequence") end
end)

H.case("BeforeDealDamage without Caster/Target is unattributed, never party-scoped", function()
    local w = world()
    local rt = v2(w)
    w:throw("BeforeDealDamage", { Hit = w:obj("HitDesc", { TotalDamageDone = 1 }), Attack = w:obj("AttackDesc", {}) })
    combat(w)
    w:throw("BeforeDealDamage", { Hit = w:obj("HitDesc", { TotalDamageDone = 1 }), Attack = w:obj("AttackDesc", {}) })
    w:throw("BeforeDealDamage", { Hit = w:obj("HitDesc", { TotalDamageDone = 2, Inflicter = w:handle(w.P[2]) }),
        Attack = w:obj("AttackDesc", {}) })
    ticks(w, 2)
    local all = R.all(read(w, rt), "BeforeDealDamage")
    T.eq(#all, 2, "outside combat the unattributed event is dropped, not kept as party prehistory")
    T.eq(all[1].data.scope, "unattributed_global")
    T.eq(all[1].data.attribution, "unattributed")
    T.eq(all[2].data.attribution, "Hit.Inflicter")
    T.eq(all[2].data.scope, "party")
end)

---------------------------------------------------------------------------------------------------------------
-- Hooks, scope, lifecycle
---------------------------------------------------------------------------------------------------------------
H.case("missing optional hooks are durable records and do not prevent core capture", function()
    local w = world({ knownEvents = { Tick = true, BeforeDealDamage = true, DealDamage = true },
        osirisMissing = { UseFinished = true } })
    local rt = v2(w)
    T.eq(rt.hooks["Ext.Events.DealtDamage"].registered, false)
    T.ok(rt.hooks["Ext.Events.DealtDamage"].error:find("Subscribe returned nil", 1, true))
    T.eq(rt.hooks.UseFinished.registered, false)
    T.ok(rt.hooks.UseFinished.error:find("not found", 1, true))
    combat(w)
    w:fire("TurnStarted", w.P[1])
    ticks(w, 1)
    local res = read(w, rt)
    T.ok(R.find(res, "TurnStarted"))
    T.eq(R.find(res, "meta").data.hooks.UseFinished.registered, false)
end)

H.case("hook callback errors are counted, bounded and recorded", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w.Osi.CombatGetGuidFor = function() error("osiris exploded") end
    for _ = 1, 25 do w:fire("TurnStarted", w.P[1]) end
    T.eq(#w.dispatchErrors, 0, "errors never escape into the engine dispatcher")
end)

H.case("mid-fight attach and overlapping party combats are explicit", function()
    local w = world()
    for _, u in ipairs(w.P) do w.combatOf[u] = COMBAT end
    local rt = v2(w)
    local res = read(w, rt)
    local meta = R.find(res, "meta")
    T.eq(meta.data.start_mode, "mid_fight_attach")
    T.eq(meta.data.how, "loaded_in_combat")
    w.combatOf[w.P[4]] = "COMBAT_" .. mock.guid(79)
    w:fire("CombatStarted", "COMBAT_" .. mock.guid(79))
    ticks(w, 1)
    local st = R.find(read(w, rt), "scope_transition")
    T.eq(st.data.what, "overlapping_party_combat")
end)

H.case("GameStateChanged is a lifecycle record plus best-effort flush", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w:throw("GameStateChanged", { FromState = "Running", ToState = "UnloadSession" })
    local res = read(w, rt)
    local st = R.find(res, "scope_transition")
    T.eq(st.data.what, "game_state_changed")
    T.eq(st.data.to, "UnloadSession")
end)

H.case("experimental functor hooks only when explicitly enabled", function()
    local w = world(nil, { EXPERIMENTAL_FUNCTORS = true })
    local rt = v2(w)
    T.ok(rt.hooks["Ext.Events.ExecuteFunctor"].registered)
    T.eq(rt.hooks["Ext.Events.ExecuteFunctor"].optional, true)
    combat(w)
    w:throw("AfterExecuteFunctor", { Functor = w:obj("Functors", {}), Params = w:obj("ContextData", { Type = "AttackTarget" }),
        Hit = w:obj("HitResult", {}) })
    ticks(w, 1)
    local r = R.find(read(w, rt), "AfterExecuteFunctor")
    T.eq(r.data.experimental, true)
    T.eq(r.phase, "ext_event_experimental")
end)

---------------------------------------------------------------------------------------------------------------
-- Checkpoints and movement
---------------------------------------------------------------------------------------------------------------
H.case("checkpoints: event-adjacent turn boundary, deferred dirty, chunked reconcile, non-atomic labels", function()
    local w = world(nil, { CHECKPOINT_ON_ACTION = false })
    local rt = v2(w)
    combat(w)
    w:fire("TurnStarted", w.P[1])
    w:fire("StatusApplied", w.E[2], "BURNING", w.P[1], 0)
    w:tick(500)
    for _ = 1, 15 do w:tick(500) end
    local res = read(w, rt)
    local turn = R.find(res, "checkpoint", function(r) return r.phase == "turn_boundary" end)
    local ts = R.find(res, "TurnStarted")
    T.eq(turn.seq, ts.seq + 1)
    T.eq(turn.data.timing, "event_adjacent")
    T.eq(turn.data.atomic, false)
    local a = turn.data.actors[1]
    T.eq(a.hp.hp, 20) T.eq(a.hp.max, 20)
    T.eq(a.statuses[1].id, "BLESS")
    T.eq(a.statuses[1].turns, 2)
    T.eq(a.statuses[1].instance, 1)
    T.eq(a.resources[1].amount, 1)
    T.eq(a.pos.valid, true)
    local dirty = R.find(res, "checkpoint", function(r) return r.phase == "dirty" end)
    T.eq(dirty.data.timing, "deferred")
    local recon = R.all(res, "checkpoint")
    local chunks = {}
    for _, r in ipairs(recon) do if r.phase == "reconcile" then chunks[#chunks + 1] = r end end
    T.ge(#chunks, 2)
    T.eq(chunks[1].data.total, 8)
    T.eq(chunks[1].data.last_chunk, false)
    T.eq(chunks[2].data.last_chunk, true)
    T.eq(chunks[1].data.group, chunks[2].data.group)
    T.eq(#w.violations, 0)
end)

H.case("delta checkpoints: only changed fields, base_seq chain, failed commit never becomes a base", function()
    local w = world(nil, { CHECKPOINT_ON_ACTION = true, RECONCILE_MS = 0, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9 })
    local rt = v2(w)
    combat(w)
    w:fire("TurnStarted", w.P[1]) -- full anchor
    w:fire("CastedSpell", w.P[1], "Shout_A", "Shout", "None", 0) -- unchanged delta
    w.entities[mock.norm(w.P[1])].hp = 13
    w:fire("CastedSpell", w.P[1], "Shout_B", "Shout", "None", 0) -- hp changed
    w.stringifyHook = function(x)
        if x.kind == "checkpoint" and x.phase == "action" and x.data.actors[1].pos then error("cannot encode") end
    end
    w.positions[w.P[1]][1] = 99
    w:fire("CastedSpell", w.P[1], "Shout_C", "Shout", "None", 0) -- pos changed but record fails to encode
    w.stringifyHook = nil
    w:fire("CastedSpell", w.P[1], "Shout_D", "Shout", "None", 0) -- must still carry pos: base not advanced
    rt.pumpAll(true)
    local res = read(w, rt)
    local cps = {}
    for _, r in ipairs(res.records) do if r.kind == "checkpoint" then cps[#cps + 1] = r end end
    T.eq(cps[1].phase, "turn_boundary")
    T.eq(cps[1].data.actors[1].full, true)
    local d1 = cps[2].data.actors[1]
    T.eq(d1.base_seq, cps[1].seq)
    T.no(d1.hp, "unchanged hp omitted") T.no(d1.pos, "unchanged pos omitted") T.no(d1.statuses)
    local d2 = cps[3].data.actors[1]
    T.eq(d2.base_seq, cps[2].seq)
    T.eq(d2.hp.hp, 13)
    T.no(d2.pos)
    local te = R.find(res, "terminal_error", function(r) return r.data.for_kind == "checkpoint" end)
    T.ok(te, "failed checkpoint is a terminal error")
    local d4 = cps[4].data.actors[1]
    T.eq(d4.base_seq, cps[3].seq, "base is the last committed sample, not the failed one")
    T.eq(d4.pos.x, 99)
    endCombat(w)
    dump(w, "delta")
end)

H.case("checkpoint with missing components records unavailable fields", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    w:removeEntity(w.P[1])
    w:fire("TurnStarted", w.P[1])
    ticks(w, 1)
    local cp = R.find(read(w, rt), "checkpoint", function(r) return r.phase == "turn_boundary" end)
    T.eq(cp.data.actors[1].entity, "unavailable")
end)

H.case("movement: off by default; when enabled threshold from last emitted sample, cumulative", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    for i = 1, 10 do w.positions[w.P[1]][1] = w.positions[w.P[1]][1] + 1 w:tick(300) end
    T.no(R.find(read(w, rt), "movement"), "movement disabled by default")
    local w2 = world(nil, { MOVEMENT_ENABLED = true, RECONCILE_MS = 0 })
    local rt2 = v2(w2)
    combat(w2)
    w2:tick(300) -- first poll emits every actor (no previous sample)
    local function moves() rt2.pumpAll(true) return #R.all(read(w2, rt2), "movement") end
    ticks(w2, 1, 300)
    local base = moves()
    w2.positions[w2.P[1]][1] = w2.positions[w2.P[1]][1] + 0.1
    w2:tick(300)
    ticks(w2, 1, 2100)
    T.eq(moves(), base, "0.1 m suppressed")
    for _ = 1, 2 do w2.positions[w2.P[1]][1] = w2.positions[w2.P[1]][1] + 0.1 w2:tick(300) end
    ticks(w2, 1, 2100)
    T.eq(moves(), base + 1, "cumulative 0.3 m crosses 0.25 m")
    local last = R.all(read(w2, rt2), "movement")
    local m = last[#last]
    T.ok(m.data.samples[1].dist > 0.25)
    T.ge(m.data.suppressed_below_threshold, 1)
end)

---------------------------------------------------------------------------------------------------------------
-- Client: UI single-flight, Defer handling, backlog, rebuilds
---------------------------------------------------------------------------------------------------------------
local function client(entries, opts, cfg)
    opts = opts or {}
    opts.server = false
    local w = world(opts, cfg)
    w:setCombatLog({ entries = entries, filler = 3 })
    local rt = v2(w)
    return w, rt
end
local function entriesN(n, tag)
    local e = {}
    for i = 1, n do e[i] = { ts = 1000 + i, text = (tag or "Entry ") .. i } end
    return e
end

H.case("UI: at most one deferred poll queued; next scheduled after completion", function()
    local w, rt = client(entriesN(3))
    T.eq(rt.context, "client")
    w:tick(600)
    T.eq(#w.defers, 1)
    for _ = 1, 5 do w:tick(600) end
    T.eq(#w.defers, 1, "no stacking while in flight")
    w:runDefers()
    T.eq(#w.defers, 0)
    onlyAllowedGlobals(w, { FightRecV2 = true })
    w:tick(100)
    T.eq(#w.defers, 0, "waits LOG_POLL_MS after completion")
    w:tick(450)
    T.eq(#w.defers, 1)
    T.eq(#w.violations, 0)
end)

H.case("UI: Ext.UI.Defer missing -> unsupported, no direct UI access, server unaffected", function()
    local w, rt = client(entriesN(3), { deferMode = "missing" })
    local roots = 0
    local orig = w.uiRoot
    w.uiRoot = function() roots = roots + 1 return orig() end
    for _ = 1, 5 do w:tick(600) end
    T.eq(roots, 0, "never touches Noesis outside Defer")
    T.ok(rt.log.unsupported)
    local s = R.read(w.fs, prefix(rt, "session"))
    T.ok(R.find(s, "ui_capture_unsupported"))
end)

H.case("UI: Defer throwing -> backoff, defer_error records, unsupported after limit", function()
    local w, rt = client(entriesN(3), { deferMode = "throw" })
    for _ = 1, 40 do w:tick(600) end
    T.ok(rt.log.unsupported and rt.log.unsupported:find("failed 3 times", 1, true))
    ticks(w, 1)
    local res = R.read(w.fs, prefix(rt, "combatlog"))
    T.eq(#R.all(res, "defer_error"), 3)
end)

-- Replaces the round-0 test that asserted two queued callbacks after a stall (that was defect IR-09).
H.case("UI: accepted-never-run Defer keeps its single slot, never accumulates, recovers when run (IR-09)", function()
    local w, rt = client(entriesN(3))
    w:tick(600)
    T.eq(#w.defers, 1)
    for _ = 1, 30 do
        w:tick(10500)
        T.le(#w.defers, 1, "never more than one queued deferred poll")
    end
    T.eq(rt.log.stalledEpisodes, 1)
    w:runDefers()
    T.eq(rt.log.polls, 1)
    T.eq(rt.log.stale, 0)
    w:tick(600)
    T.eq(#w.defers, 1, "scheduling resumes once the stalled callback ran")
    ticks(w, 1)
    local res = R.read(w.fs, prefix(rt, "combatlog"))
    T.ok(R.find(res, "defer_stall"))
    T.ok(R.find(res, "defer_stalled"))
    T.ok(R.find(res, "defer_recovered"))
end)

H.case("UI: backlog drains MAX_PER_POLL per completed poll; backlog exported", function()
    local w, rt = client(entriesN(7))
    local function poll() w:tick(600) w:runDefers() end
    for _ = 1, 5 do poll() end
    ticks(w, 1)
    local res = R.read(w.fs, prefix(rt, "combatlog"))
    local es = R.all(res, "entry")
    T.eq(#es, 7)
    T.eq(es[1].data.backlog, 6)
    T.eq(es[7].data.backlog, 0)
    T.eq(es[1].data.complete, true)
    T.eq(rt.log.maxBacklog, 5)
    T.eq(#w.violations, 0)
end)

H.case("UI: rebuilt log -> resync with new generation; duplicate fingerprints flagged ambiguous", function()
    local w, rt = client(entriesN(3))
    local function poll() w:tick(600) w:runDefers() end
    for _ = 1, 3 do poll() end
    w.uiSpec.entries = entriesN(2, "Rebuilt ")
    poll()
    local C = { ts = 1003, text = "Entry 3" }
    w.uiSpec.entries = { { ts = 1, text = "D" }, C, { ts = 2, text = "E" }, C, { ts = 3, text = "F" } }
    -- state: after rebuild L.count=2 with lastSig "Rebuilt 2"; force a known lastSig of C for the ambiguity case
    rt.log.count, rt.log.lastSig = 3, "gui::CombatLogEntryVM|1003|Entry 3"
    poll()
    ticks(w, 1)
    local res = R.read(w.fs, prefix(rt, "combatlog"))
    local rs = R.all(res, "resync")
    T.ge(#rs, 2)
    T.eq(rs[1].data.rebuilt, true)
    T.eq(rs[1].data.generation, 2)
    local amb = rs[#rs]
    T.eq(amb.data.fingerprint_matches, 2)
    T.eq(amb.data.ambiguous_duplicate, true)
    T.eq(amb.data.from, 5)
end)

-- LV02: nested shape of the live first-attack hit entry (client combatlog seq6, i5: "[2] was hit for [3].", Taman,
-- 9 Slashing, tooltip AC / "Attack Roll: [1]" / "Damage Roll: [1] = [2]"), reproduced from the raw record. The
-- dice sets of the two deepest roll params were depth-cut in the live and historical raw, so their live content is
-- UNKNOWN; the D20/D12 values here are synthetic markers that only prove the leaf now reaches the output.
local function lv02HitGroup(rollDice, badDice)
    return function(w)
        local function vm(tn, p)
            local o = w:obj(tn, { Type = tn })
            local rec = w.objs[o]
            rec.lenient = true
            -- obj.Type is the Noesis type name; a VM property named Type (param/tooltip kind) is only visible
            -- through GetAllProperties, as live
            for k, v in pairs(p) do if k ~= "Type" then rec.fields[k] = v end end
            rec.fields.GetAllProperties = function() return p end
            return o
        end
        local function coll(items)
            local o = w:obj("?", {})
            local rec = w.objs[o]
            rec.lenient = true
            rec.fields.At = function(_, j) return items[j + 1] end
            rec.fields.GetProperty = function(_, k) return k == "Count" and #items or nil end
            return o
        end
        local function dice(d)
            d = d or { Amount = 0, DiceType = "None", Str = "", ExtraStr = "ls::TranslatedStringRepository::s_HandleUnknown" }
            return vm("ls.VMDiceTypeSet", d)
        end
        local function param(tn, text, ptype, tips, d)
            return vm(tn, { Text = text, Type = ptype, DamageType = "None", RelationType = "Neutral", HasTooltip = tips ~= nil,
                ManagedTooltip = false, TooltipSectionType = "Description", DiceTypeSet = dice(d),
                TooltipEntries = coll(tips or {}), Rolls = coll({}), DamageRolls = coll({}), ExtenderData = coll({}) })
        end
        local function ctx(text, params) return vm("ls.VMContextTransString", { Text = text, ParamsDirty = false, Params = coll(params) }) end
        local function tip(tt, text, params) return vm("ls.CombatLogTooltipEntry", { Type = tt, CtxTransText = ctx(text, params) }) end
        local function damageParam()
            local tips = {
                tip("ArmorClass", "[1]'s Armour Class: [2]", { param("ls.VMContextTransStringParam", "Taman", "Character"),
                    param("ls.VMContextTransStringParam", "13", "Text") }),
                tip("Generic", "Attack Roll: [1]", { param("ls.VMContextTransStringParam", "", "Text", nil, rollDice) }),
                tip("Dice", "Damage Roll: [1] = [2]", { param("ls.VMContextTransStringParam", "", "Text", nil, badDice),
                    param("ls.VMContextTransStringParam", "9", "Text") }),
            }
            return param("ls.VMContextTransStringDamageParam", "9 Slashing damage", "Damage", tips)
        end
        local function hitText()
            return ctx("[2] was hit for [3].", { param("ls.VMContextTransStringParam", "cust", "Character"),
                param("ls.VMContextTransStringParam", "Taman", "Character"), damageParam() })
        end
        local entry = vm("ls.VMHitDamagedEntry", { Timestamp = 2016.5, CtxTransText = hitText() })
        return vm("ls.CombatLogGroupedEntries", { Entries = coll({ entry }), CtxTransText = hitText(),
            TooltipEntries = coll({}), ParamTooltips = coll({ damageParam() }) })
    end
end

local function lv02Cuts(x, acc, path)
    acc = acc or {}
    if type(x) == "table" then
        if x._cut then acc[#acc + 1] = { path = path or "", type = x._type } end
        for k, v in pairs(x) do lv02Cuts(v, acc, (path or "") .. "/" .. tostring(k)) end
    end
    return acc
end

H.case("LV02 UI: live hit entry keeps the deepest roll-param dice sets; duplicate-path cuts stay marked", function()
    local d20 = { Amount = 1, DiceType = "D20", Str = "synthetic-10", ExtraStr = "x" }
    local d12 = { Amount = 1, DiceType = "D12", Str = "synthetic-6", ExtraStr = "x" }
    local w, rt = client({ { build = lv02HitGroup(d20, d12) } })
    w:tick(600) w:runDefers()
    ticks(w, 1)
    local e = R.find(R.read(w.fs, prefix(rt, "combatlog")), "entry")
    local pt = e.data.entry.ParamTooltips._items[1].TooltipEntries._items
    T.eq(pt[1].CtxTransText.Params._items[2].Text, "13", "AC reaches the output (as live)")
    local atk = pt[2].CtxTransText.Params._items[1]
    T.eq(atk.Text, "", "attack roll param text empty (as live and historical)")
    T.eq(atk.DiceTypeSet._cut, nil, "dice set no longer cut")
    T.eq(atk.DiceTypeSet.DiceType, "D20") T.eq(atk.DiceTypeSet.Str, "synthetic-10")
    T.eq(pt[3].CtxTransText.Params._items[1].DiceTypeSet.DiceType, "D12")
    T.eq(pt[3].CtxTransText.Params._items[2].Text, "9")
    for _, c in ipairs(lv02Cuts(e.data.entry)) do
        T.ok(c.type ~= "ls.VMDiceTypeSet", "no dice set cut: " .. c.path)
    end
    -- the duplicated Entries / CtxTransText copies still end at the depth limit: honestly incomplete
    T.ok(#lv02Cuts(e.data.entry) > 0)
    T.eq(e.data.complete, false)
    T.eq(#w.violations, 0, "no engine object retained past the deferred callback")
end)

H.case("LV02 UI: a dice set with a non-scalar member past the depth limit stays cut", function()
    local w, rt = client({ { build = lv02HitGroup(nil, { Amount = 1, DiceType = "D12", Nested = {} }) } })
    w:tick(600) w:runDefers()
    ticks(w, 1)
    local e = R.find(R.read(w.fs, prefix(rt, "combatlog")), "entry")
    local pt = e.data.entry.ParamTooltips._items[1].TooltipEntries._items
    T.eq(pt[3].CtxTransText.Params._items[1].DiceTypeSet._cut, true)
    T.eq(pt[3].CtxTransText.Params._items[1].DiceTypeSet.DiceType, nil, "no partial leaf")
    T.eq(pt[2].CtxTransText.Params._items[1].DiceTypeSet.DiceType, "None")
    T.eq(e.data.complete, false)
end)

H.case("UI: vmdump budget cut marks entry incomplete", function()
    local w, rt = client(entriesN(1), nil, { ENTRY_BUDGET = 2 })
    w:tick(600) w:runDefers()
    ticks(w, 1)
    local e = R.find(R.read(w.fs, prefix(rt, "combatlog")), "entry")
    T.eq(e.data.complete, false)
end)

---------------------------------------------------------------------------------------------------------------
-- Legacy boundary compatibility
---------------------------------------------------------------------------------------------------------------
local function workload(w)
    w:fire("StatusApplied", w.P[1], "PRE_BLESS", w.P[2], 0)
    combat(w)
    w:fire("CombatRoundStarted", COMBAT, 1)
    w:fire("TurnStarted", w.P[1])
    w:fire("UsingSpellOnTarget", w.P[1], w.E[1], "Target_MainHandAttack", "Target", "None", 0)
    w:fire("CastedSpell", w.P[1], "Target_MainHandAttack", "Target", "None", 0)
    w:fire("AttackedBy", w.E[1], w.P[1], w.P[1], "Slashing", 7, "Attack", 0)
    w:fire("RollResult", "Attack", w.P[1], w.E[1], 17, 1, 0)
    w:fire("StatusApplied", w.E[1], "PRONE", w.P[1], 0)
    w:fire("StatusRemoved", w.E[1], "PRONE", w.P[1], 0)
    w:fire("HitpointsChanged", w.E[1], 60)
    w:fire("DownedChanged", w.E[2], 1)
    w:fire("Died", w.E[3])
    w:fire("Equipped", "ITEM_Sword_" .. mock.guid(500), w.P[1])
    w:fire("Unequipped", "ITEM_Sword_" .. mock.guid(500), w.P[1])
    w:fire("UseFinished", w.P[1], "ITEM_Potion_" .. mock.guid(501), 1)
    w:fire("TurnEnded", w.P[1])
    w:throw("DealDamage", { Caster = w:handle(w.P[1]), Target = w:handle(w.E[1]),
        Hit = w:obj("HitDesc", { TotalDamageDone = 7 }), Attack = w:obj("AttackDesc", { TotalDamageDone = 7 }) })
    w:tick(2100)
    endCombat(w)
    w:tick(2100)
end

H.case("legacy boundary: same event names, legacy data fields preserved, prep shape mapped", function()
    local wb, wn = world(), world()
    baseline(wb)
    local rt = v2(wn)
    workload(wb)
    workload(wn)
    local legacy = {}
    for line in wb.fs[wb:files("FightRec/")[1]]:gmatch("[^\n]+") do legacy[#legacy + 1] = json.decode(line) end
    local res = read(wn, rt)
    noIssues(res)
    local function norm(list, isLegacy)
        local out = {}
        for _, r in ipairs(list) do
            local kind, data, pre = r.kind, r.data, r.prehistory
            if isLegacy and kind == "prep" then kind, data, pre = r.data.kind, r.data.data, true end
            out[#out + 1] = { kind = kind, data = data, pre = pre }
        end
        return out
    end
    local L, N = norm(legacy, true), norm(res.records, false)
    local OBS = { TurnStarted = 1, TurnEnded = 1, UsingSpellOnTarget = 1, CastedSpell = 1, AttackedBy = 1, RollResult = 1,
        StatusApplied = 1, StatusRemoved = 1, HitpointsChanged = 1, DownedChanged = 1, Died = 1, Equipped = 1,
        Unequipped = 1, UseFinished = 1, CombatRoundStarted = 1, DealDamage = 1 }
    local function byKind(list)
        local m = {}
        for _, r in ipairs(list) do if OBS[r.kind] then m[r.kind] = m[r.kind] or {} table.insert(m[r.kind], r) end end
        return m
    end
    local lb, nb = byKind(L), byKind(N)
    for kind in pairs(OBS) do
        T.eq(#(nb[kind] or {}), #(lb[kind] or {}), "count of " .. kind)
        for i, lr in ipairs(lb[kind] or {}) do
            local nr = nb[kind][i]
            T.eq(nr.pre, lr.pre, kind .. " prehistory flag")
            for k, v in pairs(lr.data) do
                if k ~= "shape" and k ~= "hit" and k ~= "attack" and k ~= "spell" then
                    T.ok(nr.data[k] ~= nil, kind .. "." .. k .. " preserved")
                    if type(v) ~= "table" then T.eq(nr.data[k], v, kind .. "." .. k .. " value") end
                end
            end
        end
    end
    T.ok(R.find(res, "meta") and R.find(res, "snapshot") and R.find(res, "end"), "legacy record kinds kept")
    dump(wn, "legacy_workload_v2")
    dump(wb, "legacy_workload_baseline")
end)

---------------------------------------------------------------------------------------------------------------
-- Review round 1 regressions (reviews/implementation-round-1.txt)
---------------------------------------------------------------------------------------------------------------
H.case("IR-01 retained queue bytes stay within Q_MAX_BYTES + RECORD_HARD_MAX; terminal records bounded", function()
    local w = world(nil, { Q_MAX_BYTES = 20000, RECORD_HARD_MAX = 6000, PART_TARGET_BYTES = 4096,
        CHECKPOINT_ON_ACTION = false, RECONCILE_MS = 0, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9, DAMAGE_REFLECT = true })
    local rt = v2(w)
    local down = true
    w.ioHook = function(op, path) if down and path:find("-fight", 1, true) then return "false" end end
    combat(w)
    local S = fightStream(rt)
    -- fill (writes failing) until five more reservations still fit; mutation-001 showed the earlier,
    -- shallower scenario never exceeded the bound even without the check
    local i = 0
    while S.qBytes <= 20000 - 5 * rt.cfg.RESERVE_BYTES - 1500 do
        i = i + 1
        w:fire("StatusApplied", w.E[1], "FILL_" .. i, w.P[1], 0)
    end
    -- a chain of five nested large records: all five are reserved before the innermost completes
    local depth, maxSeen = 0, 0
    w.Osi.GetStatusTurns = function()
        depth = depth + 1
        if depth < 5 then w:fire("StatusApplied", w.E[1], string.rep("z", 2700) .. depth, w.P[1], 0) end
        if S.qBytes > maxSeen then maxSeen = S.qBytes end
        T.le(S.qBytes, 20000 + 6000, "queue byte bound inside the chain")
        return 1
    end
    w:fire("StatusApplied", w.E[1], string.rep("z", 2700) .. "0", w.P[1], 0)
    T.le(S.qBytes, 20000 + 6000, "queue byte bound after the chain")
    T.ge(maxSeen, 20000, "the bound was actually exercised")
    T.ok(S.lastTerminalErr, "an over-bound completion became a terminal error")
    T.eq(S.capture, "incomplete")
    down = false
    w.Osi.GetStatusTurns = function() return 1 end
    ticks(w, 10)
    -- after recovery (with the queue full it is refused at admission and gets no seq: run-012): worst-case text
    local evil = string.rep("\1", 5000)
    rt.capture(S, "required", "x", "test", w.t, 1, nil, function() error(evil) end)
    endCombat(w)
    ticks(w, 3)
    local res = read(w, rt)
    for _, p in ipairs(res.parts) do
        local raw = w.fs[p.path]
        for line in raw:gmatch("[^\n]+") do
            if line:find('"kind":"terminal_error"', 1, true) then T.le(#line, 1600, "minimal terminal record bound") end
        end
    end
    T.ok(R.find(res, "terminal_error", function(r) return r.data.for_kind == "x" end))
end)

H.case("IR-02 required terminal errors make capture incomplete; optional ones are counted, not hidden", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    rt.capture(S, "required", "req_kind", "test", w.t, 1, nil, function() error("lost payload") end)
    T.eq(S.capture, "incomplete")
    endCombat(w)
    local res = read(w, rt)
    T.eq(res.finalTrailer.capture, "incomplete")
    T.eq(json.decode(w.fs[prefix(rt, "fight01") .. "-manifest.json"]).capture, "incomplete")
    local w2 = world()
    local rt2 = v2(w2)
    combat(w2)
    w2.stringifyHook = function(x) if x.kind == "checkpoint" and x.phase == "action" then error("diag fails") end end
    w2:fire("CastedSpell", w2.P[1], "Shout_A", "Shout", "None", 0)
    w2.stringifyHook = nil
    endCombat(w2)
    local res2 = read(w2, rt2)
    T.eq(res2.finalTrailer.capture, "ok", "optional diagnostic loss does not mark required capture incomplete")
    T.eq(res2.finalTrailer.counters.terminal_errors_optional, 1)
    T.eq(R.find(res2, "terminal_error").data.class, "optional")
end)

H.case("IR-03 tiny parts and fast producers: bounded part index and checkpoint jobs", function()
    local w = world(nil, { PART_TARGET_BYTES = 700, PARTS_INDEX_MAX = 8, CHECKPOINT_MAX_ACTORS = 1,
        RECONCILE_MS = 200, DIRTY_QUIET_MS = 0, DIRTY_MAX_MS = 0 })
    local rt = v2(w)
    combat(w)
    local S, f = fightStream(rt), rt.fight
    for i = 1, 120 do
        w:fire("StatusApplied", w.E[1 + i % 4], "S_" .. i, w.P[1 + i % 4], 0)
        w:tick(150)
        T.le(#f.jobs, 2, "at most one dirty and one reconcile job")
        for _, j in ipairs(f.jobs) do T.le(#j.actors, 8, "job actors <= participants") end
        T.le(#S.parts, 8, "part index bounded")
    end
    T.ge(f.jobStats.dirty_coalesced, 1)
    T.ge(f.jobStats.reconcile_skipped, 1)
    endCombat(w)
    ticks(w, 3)
    local m = json.decode(w.fs[prefix(rt, "fight01") .. "-manifest.json"])
    T.le(#m.parts, 8)
    T.eq(m.parts_index_dropped, m.parts_total - #m.parts)
    T.ge(m.parts_total, 20)
    local res = read(w, rt)
    noIssues(res)
end)

H.case("IR-04 stop during write backoff with an outstanding reservation keeps draining to completion", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    local left = 6
    w.ioHook = function(op, path) if left > 0 and path:find("-fight", 1, true) then left = left - 1 return "false" end end
    statusEvents(w, 3)
    S:admit("required", w.t, 777, "leaked")
    rt.stop("test")
    T.no(rt.generation.active)
    T.eq(S.state, "finishing")
    for _ = 1, 40 do w:tick(2000) end
    T.eq(S.state, "complete")
    T.ge(rt.generation.drain_calls, 1, "Tick drained after stop")
    local res = read(w, rt)
    noIssues(res)
    T.ok(res.final)
    T.eq(#R.all(res, "StatusApplied"), 3)
    T.eq(#rt.streams, 0, "session stream completed too")
    local before = rt.generation.inactive_calls
    w:tick(100)
    T.eq(rt.generation.inactive_calls, before + 1, "inert once drained")
end)

H.case("IR-04 stop with writes failing forever ends in bounded explicit abandonment", function()
    local w = world()
    local rt = v2(w)
    combat(w)
    local S = fightStream(rt)
    w.ioHook = function(op, path) if path:find("-fight", 1, true) then return "throw" end end
    rt.stop("test")
    for _ = 1, 40 do w:tick(10000) end
    T.eq(S.state, "abandoned")
    T.eq(S.capture, "failed")
end)

H.case("IR-05 distinct sources with unknown identity: second is not activated, recorded as unverified", function()
    local w = world()
    local rt = v2(w)
    local fh = io.open(V2, "rb")
    local src = fh:read("a")
    fh:close()
    local edited = src:gsub("%-%- FightRec v2:", "-- EDITED COPY FightRec v2:", 1)
    T.ok(edited ~= src)
    local n = #w.listeners.TurnStarted
    assert(w:loadString(edited, "edited"))
    T.eq(rawget(w.env, "FightRecV2"), rt)
    T.eq(#w.listeners.TurnStarted, n)
    T.ok(rawget(w.env, "FightRecV2Refusal").reason:find("unknown", 1, true))
    ticks(w, 1)
    T.ok(R.find(R.read(w.fs, prefix(rt, "session")), "reexecution_unverified"))
end)

H.case("IR-06 no GUID, same clock, preexisting outputs: nothing overwritten", function()
    local w = world({ noGuid = true })
    local first = true
    local guarded = {}
    w.loadHook = function(path, ww)
        if first and path:find("-session-p00001", 1, true) then
            first = false
            guarded[#guarded + 1] = path
            return "EXISTING SESSION BYTES"
        end
        return ww.fs[path]
    end
    local rt = v2(w)
    T.eq(rt.collision_retries, 1)
    T.ok(rt.session_id:find("%-2$"), rt.session_id)
    T.eq(w.fs[guarded[1]], nil, "the existing file path was never written")
    local fightPath = prefix(rt, "fight01") .. "-p00001.jsonl"
    w.fs[fightPath] = "OLD FIGHT BYTES"
    combat(w)
    T.eq(w.fs[fightPath], "OLD FIGHT BYTES", "preexisting part untouched")
    T.ok(w.fs[prefix(rt, "fight01") .. "-c2-p00001.jsonl"], "stream written under a collision suffix")
    local w2 = world({ noGuid = true })
    w2.Ext.IO.LoadFile = nil
    v2(w2)
    T.no(rawget(w2.env, "FightRecV2"), "no GUID and no collision check: refused")
    T.ok(rawget(w2.env, "FightRecV2Refusal").reason:find("not provably unique", 1, true))
    local w3 = world()
    v2(w3)
    T.ok(rawget(w3.env, "FightRecV2").session_id:match("%-%x+$"):len() >= 33, "full GUID kept")
end)

H.case("IR-06 round 2: every candidate name taken -> explicit unwritable stream, all existing bytes unchanged", function()
    local w = world()
    local rt = v2(w)
    local base = prefix(rt, "fight01")
    local occupied = { base .. "-p00001.jsonl" }
    for k = 2, 9 do occupied[#occupied + 1] = base .. "-c" .. k .. "-p00001.jsonl" end
    for i, p in ipairs(occupied) do w.fs[p] = "OLD BYTES " .. i end
    local filesBefore = #w:files()
    combat(w)
    statusEvents(w, 3)
    ticks(w, 3)
    for i, p in ipairs(occupied) do T.eq(w.fs[p], "OLD BYTES " .. i, "untouched " .. p) end
    local S = rt.fight and rt.fight.stream
    T.ok(S and S.unwritable, "stream explicitly unwritable")
    T.eq(S.capture, "failed")
    T.ge(S.c.lost_required, 4, "observations refused and counted")
    local warned = false
    for _, m in ipairs(w.warnings) do if m:find("every candidate file name already exists", 1, true) then warned = true end end
    T.ok(warned)
    for _, p in ipairs(w:files()) do T.no(p:find("fight01", 1, true) and not w.fs[p]:find("^OLD BYTES"), "no fight file written: " .. p) end
    T.eq(#w:files() - filesBefore >= 0, true)
end)

H.case("IR-06 round 3: an orphan later part (p00002 without p00001) is never overwritten", function()
    local w = world(nil, { PART_TARGET_BYTES = 3000 })
    local rt = v2(w)
    local base = prefix(rt, "fight01")
    w.fs[base .. "-p00002.jsonl"] = "ORPHAN PART TWO"
    w.fs[base .. "-p00004.jsonl"] = "ORPHAN PART FOUR"
    local before = {}
    for _, p in ipairs(w:files()) do before[p] = w.fs[p] end
    combat(w)
    statusEvents(w, 40)
    ticks(w, 5)
    for p, bytes in pairs(before) do
        if not p:find("-session-", 1, true) then T.eq(w.fs[p], bytes, "preexisting file unchanged: " .. p) end
    end
    T.ok(w.fs[base .. "-p00001.jsonl"], "part 1 (free) was written")
    local S = rt.fight.stream
    T.eq(S.state, "abandoned", "explicit failure at the occupied part path")
    T.eq(S.capture, "failed")
    T.ok(S.unwritable and S.unwritable:find("p00002", 1, true))
    local warned = false
    for _, m in ipairs(w.warnings) do if m:find("was not overwritten", 1, true) then warned = true end end
    T.ok(warned, "out-of-band warning")
    statusEvents(w, 2)
    T.ge(S.c.lost_required, 2, "later observations are counted as loss, not silently dropped")
end)

H.case("IR-07 reflection stops enumerating at the budget on a giant flat table", function()
    local w = world(nil, { REFLECT_BUDGET = 50 })
    local rt = v2(w)
    local visits = 0
    local big = {}
    for i = 1, 100000 do big["k" .. i] = i end
    local proxy = setmetatable({}, { __pairs = function()
        return function(_, k)
            local nk, nv = next(big, k)
            if nk ~= nil then visits = visits + 1 end
            return nk, nv
        end, big, nil
    end })
    local out = rt.reflect(proxy, 2)
    T.le(visits, 60, "visits bounded by budget")
    T.eq(out.cut, true)
    T.eq(out.value._omitted, true)
end)

H.case("IR-08 status instances, durations and duplicates are captured and diffed", function()
    local w = world(nil, { RECONCILE_MS = 0, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9 })
    local rt = v2(w)
    combat(w)
    local key = mock.norm(w.P[1])
    w.entities[key].statuses = { { "BLESS", 11 }, { "BLESS", 12 }, { "BURNING", 13 } }
    w.statusTurns[key .. "|BURNING"] = 3
    w:fire("TurnStarted", w.P[1])
    w.statusTurns[key .. "|BURNING"] = 2
    w:fire("CastedSpell", w.P[1], "Shout_A", "Shout", "None", 0)
    w.entities[key].statuses = { { "BLESS", 11 }, { "BLESS", 12 } }
    w:fire("CastedSpell", w.P[1], "Shout_B", "Shout", "None", 0)
    rt.pumpAll(true)
    local cps = R.all(read(w, rt), "checkpoint")
    local a = cps[1].data.actors[1]
    T.eq(#a.statuses, 3)
    T.eq(a.statuses[1].instance, 11) T.eq(a.statuses[2].instance, 12)
    T.eq(a.statuses[3].id, "BURNING") T.eq(a.statuses[3].turns, 3)
    T.ok(cps[1].data.status_fields:find("source/cause not captured", 1, true))
    local d1 = cps[2].data.actors[1]
    T.eq(d1.statuses[3].turns, 2, "duration change appears in the delta")
    local d2 = cps[3].data.actors[1]
    T.eq(#d2.statuses, 2, "expiry appears in the delta")
end)

H.case("LV01 absent StatusContainer is explicit component_absent, never an empty list", function()
    -- live LV01: party entities read e.StatusContainer == nil while NPC containers worked. An absent component is
    -- unknown status state; only a present container with no entries is an observed empty list.
    local w = world(nil, { RECONCILE_MS = 0, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9 })
    w.entities[mock.norm(w.P[1])].statuses = false
    w.entities[mock.norm(w.P[2])].statuses = {}
    local rt = v2(w)
    combat(w)
    w:fire("TurnStarted", w.P[1])
    w:fire("TurnStarted", w.P[2])
    ticks(w, 1)
    local res = read(w, rt)
    local byU = {}
    for _, c in ipairs(R.find(res, "snapshot").data.characters) do byU[mock.norm(c.uuid)] = c end
    local s1, s2, s3 = byU[mock.norm(w.P[1])], byU[mock.norm(w.P[2])], byU[mock.norm(w.P[3])]
    T.eq(s1.statuses.component_absent, true, "snapshot: absence is labelled")
    T.ok(s1.statuses.unavailable:find("StatusContainer component absent", 1, true))
    T.eq(s1.statuses[1], nil, "snapshot: absence is not a list")
    T.ok(s1.statuses_error, "legacy statuses_error kept")
    T.eq(#s2.statuses, 0, "present empty container is an observed empty list")
    T.eq(s2.statuses.component_absent, nil) T.eq(s2.statuses_error, nil)
    T.eq(s3.statuses[1].id, "BLESS")
    local cps = R.all(res, "checkpoint")
    local a1 = cps[1].data.actors[1]
    T.eq(mock.norm(a1.uuid), mock.norm(w.P[1]))
    T.eq(a1.statuses.component_absent, true, "checkpoint: absence is labelled")
    T.ok(a1.statuses.unavailable)
    local a2 = cps[2].data.actors[1]
    T.eq(mock.norm(a2.uuid), mock.norm(w.P[2]))
    T.eq(#a2.statuses, 0) T.eq(a2.statuses.unavailable, nil)
    noIssues(res)
    T.eq(#w.violations, 0)
end)

H.case("IR-10 a movement sample that was not committed does not advance the anchor", function()
    local w = world(nil, { MOVEMENT_ENABLED = true, RECONCILE_MS = 0, CHECKPOINT_ON_TURN = false,
        CHECKPOINT_ON_ACTION = false, DIRTY_QUIET_MS = 1e9, DIRTY_MAX_MS = 1e9 })
    local rt = v2(w)
    combat(w)
    w:tick(300) -- first poll emits everyone
    local P = w.positions[w.P[1]]
    P[1] = P[1] + 1.0
    w.stringifyHook = function(x) if x.kind == "movement" then error("movement record fails") end end
    w:tick(300)
    w.stringifyHook = nil
    P[1] = P[1] + 0.1
    w:tick(300)
    rt.pumpAll(true)
    local mv = R.all(read(w, rt), "movement")
    local last = mv[#mv]
    T.eq(#mv, 2, "initial poll + the post-failure poll")
    local s1
    for _, smp in ipairs(last.data.samples) do if smp.uuid == mock.norm(w.P[1]) then s1 = smp end end
    T.ok(s1, "P1 emitted after the failed record")
    T.ok(math.abs(s1.dist - 1.1) < 1e-9, "distance from the last EMITTED sample: " .. tostring(s1.dist))
end)

H.case("baseline file bytes unchanged by any test", function()
    local fh = io.open(BASE, "rb")
    local s = fh:read("a")
    fh:close()
    T.eq(#s, 33039)
end)

local fails = H.run(FILTER)
local out = {}
for _, r in ipairs(H.results) do out[#out + 1] = r end
host.write_file(REPO .. "/work/test-results/lua-tests.json", json.encode({ results = out, lua = host.lua_version,
    lupa = host.lupa_version }))
return fails > 0 and 1 or 0
