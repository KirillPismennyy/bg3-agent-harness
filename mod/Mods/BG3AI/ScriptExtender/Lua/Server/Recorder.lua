-- Fight recorder (server context): raw combat facts for tools/record_fight.py, which logs a fight a human plays.
-- Dev only and off until rec.enable. NOT fair-filtered: enemy rolls, unseen attackers, engine spell and status ids.
-- So it keeps its own buffer, read with rec.since, and never goes through RPC.push, whose events reach the agent.
-- See tools/README-record-fight.md.

BG3AI = BG3AI or {}
local RPC = BG3AI.RPC
local V = BG3AI.Visibility
local R = BG3AI.Recorder or {}
BG3AI.Recorder = R

R.CAP = 5000          -- records kept; the recorder drains every ~250 ms
R.DUMP_MAX = 20000    -- a dumped engine object longer than this (JSON chars) is kept as truncated text
R.on = R.on or false
R.seq = R.seq or 0
R.buf = R.buf or {}
R.hooks = R.hooks or {}   -- listener / event name -> "ok" or the error it gave

local function now_ms() return math.floor(Ext.Utils.MonotonicTime()) end

local function push(kind, data)
    R.seq = R.seq + 1
    R.buf[#R.buf + 1] = { seq = R.seq, t = now_ms(), kind = kind, data = data }
    if #R.buf > R.CAP then table.remove(R.buf, 1) end
end

-- An engine object (userdata) as plain JSON-able data, depth-limited; the same Stringify path Events.lua uses.
function R.dump(x, depth)
    local tx = type(x)
    if tx ~= "userdata" and tx ~= "table" then return x end
    local ok, s = pcall(Ext.Json.Stringify, x, { Beautify = false, StringifyInternalTypes = true,
        IterateUserdata = true, AvoidRecursion = true, MaxDepth = depth or 4 })
    if not ok and Ext.Types and Ext.Types.Serialize then
        local ok2, t = pcall(Ext.Types.Serialize, x)
        if ok2 then
            ok, s = pcall(Ext.Json.Stringify, t, { Beautify = false, StringifyInternalTypes = true,
                AvoidRecursion = true, MaxDepth = depth or 4 })
        end
    end
    if not ok then return tostring(x) end
    if #s > R.DUMP_MAX then return { truncated = true, json = s:sub(1, R.DUMP_MAX) } end
    local ok3, p = pcall(Ext.Json.Parse, s)
    return ok3 and p or s
end

local function who(x)
    local u = V.uuid(x)
    if not u then return x ~= nil and tostring(x) or nil end
    local ok, n = pcall(V.name, u)
    return { uuid = u, name = ok and n or nil }
end

local function statName(id)
    local ok, n = pcall(function()
        local st = Ext.Stats.Get(id)
        return st and Ext.Loca.GetTranslatedString(st.DisplayName) or nil
    end)
    return ok and n ~= "" and n or nil
end

-- Party members and whoever shares a combat with them; cached for 250 ms like Events.lua's ctx().
local cache, cacheT = nil, 0
local function scope()
    local t = now_ms()
    if not cache or t - cacheT > 250 then
        local ctx = V.context()
        local combats = {}
        for _, u in ipairs(ctx.party) do
            local g = V.osi(Osi.CombatGetGuidFor, u)
            if g then combats[g] = true end
        end
        cache, cacheT = { party = ctx.is_party, combats = combats }, t
    end
    return cache
end

local function relevant(...)
    local s = scope()
    for i = 1, select("#", ...) do   -- not ipairs: an absent attacker is a nil in the middle
        local u = V.uuid((select(i, ...)))
        if u and (s.party[u] or s.combats[V.osi(Osi.CombatGetGuidFor, u) or false]) then return true end
    end
    return false
end

local function listen(name, arity, fn)
    local ok, err = pcall(Ext.Osiris.RegisterListener, name, arity, "after", function(...)
        if not R.on then return end
        local ok2, err2 = pcall(fn, ...)
        if not ok2 then Ext.Utils.PrintWarning("[BG3AI] recorder " .. name .. ": " .. tostring(err2)) end
    end)
    R.hooks[name] = ok and "ok" or tostring(err)
end

local function subscribe(name, fn)
    local ok, err = pcall(function()
        Ext.Events[name]:Subscribe(function(e)
            if not R.on then return end
            local ok2, err2 = pcall(fn, e)
            if not ok2 then Ext.Utils.PrintWarning("[BG3AI] recorder " .. name .. ": " .. tostring(err2)) end
        end)
    end)
    R.hooks["Ext.Events." .. name] = ok and "ok" or tostring(err)
end

if not R.registered then
    R.registered = true

    listen("CombatStarted", 1, function(c) push("combat_started", { combat = tostring(c) }) end)
    listen("CombatEnded", 1, function(c) push("combat_ended", { combat = tostring(c) }) end)
    listen("CombatRoundStarted", 2, function(c, round)
        if scope().combats[c] then push("round", { round = round }) end
    end)
    listen("TurnStarted", 1, function(c) if relevant(c) then push("turn_started", { char = who(c) }) end end)
    listen("TurnEnded", 1, function(c) if relevant(c) then push("turn_ended", { char = who(c) }) end end)

    -- UsingSpellOnTarget(caster, target, spell, spellType, spellElement, storyActionID)
    listen("UsingSpellOnTarget", 6, function(caster, target, spell, stype, elem, _)
        if relevant(caster, target) then
            push("spell_on_target", { caster = who(caster), target = who(target), spell = spell,
                name = statName(spell), type = stype, element = elem })
        end
    end)
    -- CastedSpell(caster, spell, spellType, spellElement, storyActionID)
    listen("CastedSpell", 5, function(caster, spell, stype, elem, _)
        if relevant(caster) then
            push("cast", { caster = who(caster), spell = spell, name = statName(spell), type = stype, element = elem })
        end
    end)
    -- AttackedBy(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, storyActionID)
    listen("AttackedBy", 7, function(def, owner, att, dtype, amount, cause, _)
        if relevant(def, owner, att) then
            push("damage", { target = who(def), source = who(owner), via = att ~= owner and who(att) or nil,
                type = dtype, amount = amount, cause = cause })
        end
    end)
    -- RollResult(eventName, roller, rollSubject, resultType, isActiveRoll, criticality)
    listen("RollResult", 6, function(ev, roller, subject, result, active, crit)
        if relevant(roller, subject) then
            push("roll_result", { event = ev, roller = who(roller), subject = who(subject), result = result,
                active = active, critical = crit })
        end
    end)
    listen("StatusApplied", 4, function(obj, status, causee, _)
        if relevant(obj) then
            push("status_applied", { target = who(obj), status = status, name = statName(status),
                source = who(causee), turns = V.osi(Osi.GetStatusTurns, obj, status) })
        end
    end)
    listen("StatusRemoved", 4, function(obj, status, causee, _)
        if relevant(obj) then push("status_removed", { target = who(obj), status = status, name = statName(status) }) end
    end)
    listen("HitpointsChanged", 2, function(obj, pct)
        if relevant(obj) then push("hp", { char = who(obj), pct = pct }) end
    end)
    listen("DownedChanged", 2, function(c, downed) if relevant(c) then push("downed", { char = who(c), downed = downed }) end end)
    listen("Died", 1, function(c) if relevant(c) then push("died", { char = who(c) }) end end)
    listen("Equipped", 2, function(item, c)
        if relevant(c) then push("equipped", { char = who(c), item = who(item) }) end
    end)
    listen("Unequipped", 2, function(item, c)
        if relevant(c) then push("unequipped", { char = who(c), item = who(item) }) end
    end)

    -- Script Extender damage events, where the extender has them (UNVERIFIED on bg3le: rec.enable lists what
    -- subscribed). Their hit and attack descriptions are the nearest engine record of a roll.
    local function entityName(h)
        local ok, u = pcall(function() return h.Uuid.EntityUuid end)
        return ok and u and who(u) or nil
    end
    for _, name in ipairs({ "DealtDamage", "BeforeDealDamage" }) do
        subscribe(name, function(e)
            local caster, target = entityName(e.Caster), entityName(e.Target)
            local cu, tu = type(caster) == "table" and caster.uuid, type(target) == "table" and target.uuid
            if (cu or tu) and not relevant(cu, tu) then return end
            push(name == "DealtDamage" and "dealt_damage" or "before_damage", {
                caster = caster, target = target, spell = R.dump(e.SpellId, 3),
                hit = R.dump(e.Hit, 5), attack = R.dump(e.Attack, 5), damage = R.dump(e.DamageSums, 4) })
        end)
    end
end

-- rec.enable {on=true} -> {on, seq, hooks}: start (or stop) recording; seq is where rec.since starts.
RPC.register("rec.enable", function(args)
    R.on = args.on ~= false
    cache = nil
    return { on = R.on, seq = R.seq, hooks = R.hooks }
end)

-- rec.since {seq, limit=300} -> {on, latest, records:[{seq,t,kind,data}]}
RPC.register("rec.since", function(args)
    local since = tonumber(args.seq) or 0
    local limit = tonumber(args.limit) or 300
    local out = {}
    for _, r in ipairs(R.buf) do
        if r.seq > since then
            out[#out + 1] = r
            if #out >= limit then break end
        end
    end
    return { on = R.on, latest = R.seq, records = out }
end)
