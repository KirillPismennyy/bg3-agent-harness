-- FightRec: records Baldur's Gate 3 fights to JSONL for analysis. Needs only Norbyte's Script Extender.
-- One file for both contexts: the server half records the fight, the client half reads the combat log panel.
-- See fightrec/README.md. Writes to the Script Extender data folder (%LOCALAPPDATA%\Larian Studios\
-- Baldur's Gate 3\Script Extender on Windows):
--   FightRec/<stamp>-fight<N>.jsonl   one per fight: meta, snapshots, preparation, every event (server)
--   FightRec/<stamp>-combatlog.jsonl  every combat log entry while the game runs (client)

FightRec = FightRec or {}
local FR = FightRec

FR.DIR = "FightRec/"
FR.FLUSH_MS = 2000      -- rewrite a dirty file at most this often (Ext.IO.SaveFile has no append)
FR.PREP_KEEP = 300      -- party records kept from outside combat, written into the next fight as its preparation
FR.PREP_MS = 10 * 60 * 1000 -- ... if they are at most this old
FR.DUMP_MAX = 50000     -- a dumped engine object longer than this (JSON chars) is kept truncated
FR.LOG_POLL_MS = 500    -- client: how often the combat log is checked

local function now() return math.floor(Ext.Utils.MonotonicTime()) end
local function epoch()
    local ok, t = pcall(function() return Ext.Timer.ClockEpoch() end)
    return ok and t or nil
end
FR.stamp = FR.stamp or tostring(epoch() or now())

local function stringify(x)
    return Ext.Json.Stringify(x, { Beautify = false, StringifyInternalTypes = true, AvoidRecursion = true })
end

-- An engine object (userdata) as plain data, depth-limited.
function FR.dump(x, depth)
    local tx = type(x)
    if tx ~= "userdata" and tx ~= "table" then return x end
    local ok, s = pcall(Ext.Json.Stringify, x, { Beautify = false, StringifyInternalTypes = true,
        IterateUserdata = true, AvoidRecursion = true, MaxDepth = depth or 3 })
    if not ok then return tostring(x) end
    if #s > FR.DUMP_MAX then return { truncated = true, json = s:sub(1, FR.DUMP_MAX) } end
    local ok2, p = pcall(Ext.Json.Parse, s)
    return ok2 and p or s
end

-- A JSONL file rewritten whole on flush (there is no append), at most every FLUSH_MS.
local function writer(name)
    return { path = FR.DIR .. FR.stamp .. "-" .. name .. ".jsonl", lines = {}, dirty = false, at = 0 }
end
local function add(w, rec)
    local ok, line = pcall(stringify, rec)
    w.lines[#w.lines + 1] = ok and line or stringify({ kind = "encode_error", error = tostring(line) })
    w.dirty = true
end
local function flush(w, force)
    if not w or not w.dirty then return end
    local t = now()
    if not force and t - w.at < FR.FLUSH_MS then return end
    w.at, w.dirty = t, false
    local ok, err = pcall(Ext.IO.SaveFile, w.path, table.concat(w.lines, "\n") .. "\n")
    if not ok then Ext.Utils.PrintWarning("[FightRec] cannot write " .. w.path .. ": " .. tostring(err)) end
end
FR.flush = flush

------------------------------------------------------------------------
-- Server: the fight
------------------------------------------------------------------------
if Ext.IsServer() then

local function osi(fn, ...)
    local ok, r = pcall(fn, ...)
    return ok and r or nil
end

local function uuid(s)
    if type(s) ~= "string" then return nil end
    return s:match("%x+%-%x+%-%x+%-%x+%-%x+$")
end

local names = {}
local function name(u)
    if not u then return nil end
    if names[u] == nil then
        names[u] = osi(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end) or false
    end
    return names[u] or nil
end

local function who(x)
    local u = uuid(x)
    if not u then return x ~= nil and tostring(x) or nil end
    return { uuid = u, name = name(u) }
end

local function statName(id)
    return osi(function()
        local st = Ext.Stats.Get(id)
        return st and Ext.Loca.GetTranslatedString(st.DisplayName) or nil
    end)
end

local function party()
    local out = {}
    for _, row in ipairs(osi(function() return Osi.DB_Players:Get(nil) end) or {}) do
        local u = uuid(row[1])
        if u then out[#out + 1] = u end
    end
    return out
end

-- party set + the combats it is in, cached for 250 ms
local scopeCache, scopeT = nil, -1e9
local function scope()
    local t = now()
    if not scopeCache or t - scopeT > 250 then
        local isParty, combats = {}, {}
        for _, u in ipairs(party()) do
            isParty[u] = true
            local c = osi(Osi.CombatGetGuidFor, u)
            if c then combats[c] = true end
        end
        scopeCache, scopeT = { party = isParty, combats = combats }, t
    end
    return scopeCache
end

-- "party": a party member is involved; "fight": someone in the party's combat; nil: neither.
local function involvement(...)
    local s = scope()
    local fight = false
    for i = 1, select("#", ...) do   -- not ipairs: an absent attacker is a nil in the middle
        local u = uuid((select(i, ...)))
        if u then
            if s.party[u] then return "party" end
            local c = osi(Osi.CombatGetGuidFor, u)
            if c and s.combats[c] then fight = true end
        end
    end
    return fight and "fight" or nil
end

-- One character's state: what the character sheet, examine panel and portrait show, as the engine holds it.
local SLOTS = { "Helmet", "Breast", "Cloak", "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand",
    "Ring", "Ring2", "Amulet", "Boots", "Gloves", "Underwear", "MusicalInstrument" }
local COMPONENTS = { "Health", "EocLevel", "Classes", "Stats", "ActionResources", "Experience", "Resistances",
    "SpellBookPrepares" }

function FR.character(u)
    local e = osi(Ext.Entity.Get, u)
    local out = { uuid = u, name = name(u), party = scope().party[u] or nil }
    local x, y, z = osi(Osi.GetPosition, u)
    if x then out.pos = { x, y, z } end
    out.hostile_to_party = (function()
        local p = party()[1]
        return p and osi(Osi.IsEnemy, u, p) == 1 or nil
    end)()
    if not e then return out end
    for _, c in ipairs(COMPONENTS) do
        local ok, v = pcall(function() return e[c] end)
        if ok and v ~= nil then out[c] = FR.dump(v, 4) end
    end
    local statuses = {}
    pcall(function()
        for _, id in pairs(e.StatusContainer.Statuses) do
            statuses[#statuses + 1] = { id = tostring(id), name = statName(tostring(id)),
                turns = osi(Osi.GetStatusTurns, u, tostring(id)) }
        end
    end)
    out.statuses = statuses
    local equipment = {}
    for _, slot in ipairs(SLOTS) do
        local item = uuid(osi(Osi.GetEquippedItem, u, slot))
        if item then
            local stats = osi(function() return Ext.Entity.Get(item).Data.StatsId end)
            equipment[#equipment + 1] = { slot = slot, uuid = item, name = name(item), stats = stats }
        end
    end
    out.equipment = equipment
    return out
end

-- The party, plus everyone in the party's combat (and anyone the fight's events named).
function FR.snapshot(why)
    local seen, list = {}, {}
    local function addu(u) if u and not seen[u] then seen[u] = true list[#list + 1] = u end end
    for _, u in ipairs(party()) do addu(u) end
    local s = scope()
    for c in pairs(s.combats) do
        for _, row in ipairs(osi(function() return Osi.DB_Is_InCombat:Get(nil, c) end) or {}) do addu(uuid(row[1])) end
    end
    for u in pairs(FR.fight and FR.fight.seen or {}) do addu(u) end
    local chars = {}
    for _, u in ipairs(list) do chars[#chars + 1] = FR.character(u) end
    return { why = why, characters = chars }
end

FR.prep = FR.prep or {}   -- recent party records outside combat
FR.fightN = FR.fightN or 0
FR.hooks = FR.hooks or {}

local function record(kind, data, inv)
    local rec = { t = now(), kind = kind, data = data }
    local f = FR.fight
    if f then
        add(f.w, rec)
        for _, v in pairs(data) do
            if type(v) == "table" and v.uuid then f.seen[v.uuid] = true end
        end
    elseif inv == "party" then
        FR.prep[#FR.prep + 1] = rec
        if #FR.prep > FR.PREP_KEEP then table.remove(FR.prep, 1) end
    end
end

function FR.startFight(combat, how)
    FR.fightN = FR.fightN + 1
    local f = { combat = combat, n = FR.fightN, w = writer(string.format("fight%02d", FR.fightN)), seen = {} }
    FR.fight = f
    add(f.w, { t = now(), kind = "meta", data = { fight = f.n, stamp = FR.stamp, epoch = epoch(), how = how,
        hooks = FR.hooks, game = osi(Ext.Utils.GameVersion), level = osi(function() return Osi.GetRegion(party()[1]) end) } })
    local cutoff = now() - FR.PREP_MS
    for _, r in ipairs(FR.prep) do
        if r.t >= cutoff then add(f.w, { t = r.t, kind = "prep", data = { kind = r.kind, data = r.data } }) end
    end
    FR.prep = {}
    add(f.w, { t = now(), kind = "snapshot", data = FR.snapshot("combat_start") })
    flush(f.w, true)
    Ext.Utils.Print("[FightRec] fight " .. f.n .. " started: " .. f.w.path)
end

function FR.endFight(why)
    local f = FR.fight
    if not f then return end
    add(f.w, { t = now(), kind = "snapshot", data = FR.snapshot(why or "combat_end") })
    add(f.w, { t = now(), kind = "end", data = { why = why or "combat_end", epoch = epoch() } })
    flush(f.w, true)
    FR.fight = nil
    Ext.Utils.Print("[FightRec] fight " .. f.n .. " saved: " .. f.w.path)
end

local function listen(evname, arity, fn)
    local ok, err = pcall(Ext.Osiris.RegisterListener, evname, arity, "after", function(...)
        local ok2, err2 = pcall(fn, ...)
        if not ok2 then Ext.Utils.PrintWarning("[FightRec] " .. evname .. ": " .. tostring(err2)) end
    end)
    FR.hooks[evname] = ok and "ok" or tostring(err)
end

local function subscribe(evname, fn)
    local ok, err = pcall(function()
        Ext.Events[evname]:Subscribe(function(e)
            local ok2, err2 = pcall(fn, e)
            if not ok2 then Ext.Utils.PrintWarning("[FightRec] " .. evname .. ": " .. tostring(err2)) end
        end)
    end)
    FR.hooks["Ext.Events." .. evname] = ok and "ok" or tostring(err)
end

-- A fight starts when a combat has a party member in it (the party can join a frame after CombatStarted).
local function maybeStart(combat, how)
    if FR.fight then return end
    scopeCache = nil
    if scope().combats[combat] then FR.startFight(combat, how) end
end

-- Generic event: recorded when the party or its combat is involved; who-fields name their characters.
local function on(evname, arity, fields, extra)
    listen(evname, arity, function(...)
        local args = { ... }
        local ids, n = {}, 0
        for i, f in ipairs(fields) do if f:sub(1, 1) == "@" then n = n + 1 ids[n] = args[i] end end
        local inv = involvement(table.unpack(ids, 1, n))
        if not inv then return end
        local data = {}
        for i, f in ipairs(fields) do
            if f:sub(1, 1) == "@" then data[f:sub(2)] = who(args[i]) elseif f ~= "_" then data[f] = args[i] end
        end
        if extra then extra(data, args) end
        record(evname, data, inv)
    end)
end

if not FR.registered then
    FR.registered = true

    listen("CombatStarted", 1, function(c) maybeStart(c, "CombatStarted") end)
    listen("CombatRoundStarted", 2, function(c, round)
        maybeStart(c, "CombatRoundStarted")
        if FR.fight and FR.fight.combat == c then record("CombatRoundStarted", { round = round }) end
    end)
    listen("CombatEnded", 1, function(c) if FR.fight and FR.fight.combat == c then FR.endFight("combat_end") end end)

    on("TurnStarted", 1, { "@char" })
    on("TurnEnded", 1, { "@char" })
    on("UsingSpellOnTarget", 6, { "@caster", "@target", "spell", "type", "element", "_" },
        function(d) d.name = statName(d.spell) end)
    on("CastedSpell", 5, { "@caster", "spell", "type", "element", "_" }, function(d) d.name = statName(d.spell) end)
    on("AttackedBy", 7, { "@target", "@source", "@via", "damage_type", "amount", "cause", "_" })
    on("RollResult", 6, { "event", "@roller", "@subject", "result", "active", "critical" })
    on("StatusApplied", 4, { "@target", "status", "@source", "_" }, function(d, a)
        d.name = statName(d.status)
        d.turns = osi(Osi.GetStatusTurns, a[1], d.status)
    end)
    on("StatusRemoved", 4, { "@target", "status", "@source", "_" }, function(d) d.name = statName(d.status) end)
    on("HitpointsChanged", 2, { "@char", "pct" })
    on("DownedChanged", 2, { "@char", "downed" })
    on("Died", 1, { "@char" })
    on("Equipped", 2, { "@item", "@char" })
    on("Unequipped", 2, { "@item", "@char" })
    on("UseFinished", 3, { "@char", "@item", "success" })

    -- The extender's damage events: the engine's hit and attack descriptions, the nearest record of a roll.
    local function entity(h)
        local ok, u = pcall(function() return h.Uuid.EntityUuid end)
        return ok and u or nil
    end
    for _, evname in ipairs({ "BeforeDealDamage", "DealDamage", "DealtDamage" }) do
        subscribe(evname, function(e)
            local cu, tu = entity(e.Caster), entity(e.Target)
            local inv = involvement(cu, tu)
            if (cu or tu) and not inv then return end
            record(evname, { caster = who(cu), target = who(tu), spell = FR.dump(e.SpellId, 3),
                hit = FR.dump(e.Hit, 5), attack = FR.dump(e.Attack, 5), damage = FR.dump(e.DamageSums, 4) }, inv)
        end)
    end

    subscribe("Tick", function() if FR.fight then flush(FR.fight.w) end end)
end

-- Loaded mid-fight (from the console): start now.
if not FR.fight then
    for c in pairs(scope().combats) do FR.startFight(c, "loaded_in_combat") break end
end
Ext.Utils.Print("[FightRec] server ready; hooks: " .. stringify(FR.hooks))

------------------------------------------------------------------------
-- Client: the combat log panel
------------------------------------------------------------------------
else

local function get(obj, k) local ok, v = pcall(function() return obj[k] end) return ok and v or nil end
local function typeName(obj) return get(obj, "Type") end
local function count(coll)
    local ok, n = pcall(function() return coll:GetProperty("Count") end)
    return ok and tonumber(n) or 0
end
local function at(coll, i) local ok, v = pcall(function() return coll:At(i) end) return ok and v or nil end
local function props(vm) local ok, p = pcall(function() return vm:GetAllProperties() end) return ok and p or {} end
local function isCollection(tn) return type(tn) == "string" and tn:find("Collection") ~= nil end
-- GetAllProperties only on view models (namespaced types), never on live elements: on an element it can
-- crash the game while the UI rebuilds it.
local function isViewModel(tn)
    return type(tn) == "string" and (tn:find("::", 1, true) or tn:find("^ls%.") or tn:find("^gui%."))
        and not tn:find("^Noesis")
end
local SKIP = { CurrentPlayer = true, Data = true, Players = true, PlayerList = true }

function FR.vmdump(obj, depth, budget)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return obj end
    budget.n = budget.n - 1
    local tn = typeName(obj) or "?"
    if budget.n <= 0 then return { _type = tn, _cut = true } end
    if tn:find("Command") then return { _cmd = tn } end
    if isCollection(tn) then
        local n, items = count(obj), {}
        if depth > 0 then for i = 1, math.min(n, 30) do items[i] = FR.vmdump(at(obj, i), depth - 1, budget) end end
        return { _type = tn, _count = n, _items = items }
    end
    if not isViewModel(tn) then
        local ok, s = pcall(function() return obj:ToString() end)
        return { _type = tn, _text = ok and type(s) == "string" and s ~= "" and s or nil }
    end
    local out = { _type = tn }
    if depth <= 0 then out._cut = true return out end
    for k, v in pairs(props(obj)) do if not SKIP[k] then out[k] = FR.vmdump(v, depth - 1, budget) end end
    return out
end

FR.COLLECTIONS = { "CombatLogEntries", "Entries", "LogEntries", "CombatLog", "Items", "Lines", "Messages" }

-- The combat log's DataContext (gui::DCCombatLog) among the pages under ContentRoot, read through the
-- Children collection (VisualChild on a panel can crash while the UI thread rebuilds it).
function FR.findLog()
    local root = get(Ext.UI, "GetRoot") and Ext.UI.GetRoot()
    local cr = root and get(root, "Find") and root:Find("ContentRoot")
    local kids = cr and select(2, pcall(function() return cr:GetProperty("Children") end)) or nil
    for i = 1, count(kids) do
        local w = at(kids, i)
        local dc = w and get(w, "DataContext")
        local tn = dc and typeName(dc)
        if tn == "gui::DCCombatLog" or get(w, "Name") == "CombatLog" then return dc end
    end
    return nil
end

function FR.entries(dc)
    local p = props(dc)
    if FR.chosen and p[FR.chosen] then return FR.chosen, p[FR.chosen] end
    for _, k in ipairs(FR.COLLECTIONS) do
        if p[k] and isCollection(typeName(p[k])) then FR.chosen = k return k, p[k] end
    end
    for k, v in pairs(p) do
        if isCollection(typeName(v)) and count(v) > 0 then
            local tn = typeName(at(v, 1)) or ""
            if tn:find("[Ll]og") or tn:find("[Ee]ntry") then FR.chosen = k return k, v end
        end
    end
    return nil
end

-- What the log's DataContext holds: written once, so a wrong guess above can be corrected.
function FR.probe(dc)
    local out, budget = {}, { n = 3000 }
    for k, v in pairs(props(dc)) do
        if not SKIP[k] then
            local tn = typeName(v)
            if isCollection(tn) then
                local n = count(v)
                out[k] = { type = tn, count = n, first = n > 0 and FR.vmdump(at(v, 1), 3, budget) or nil }
            else
                out[k] = tn or v
            end
        end
    end
    return out
end

FR.log = FR.log or { w = writer("combatlog"), count = 0, lastSig = nil, probed = false, next = 0 }

local function sig(d) local ok, s = pcall(stringify, d) return ok and s or "?" end

function FR.pollLog()
    local L = FR.log
    local dc = FR.findLog()
    if not dc then return end
    if not L.probed then
        L.probed = true
        add(L.w, { t = now(), kind = "probe", data = FR.probe(dc), epoch = epoch() })
    end
    local name, coll = FR.entries(dc)
    if not coll then return end
    local n = count(coll)
    -- The log can drop old entries or be rebuilt (a load): if the last known entry moved, find it again.
    local from = L.count + 1
    if L.lastSig and (n < L.count or sig(FR.vmdump(at(coll, L.count), 4, { n = 2000 })) ~= L.lastSig) then
        from = 1
        for i = n, 1, -1 do
            if sig(FR.vmdump(at(coll, i), 4, { n = 2000 })) == L.lastSig then from = i + 1 break end
        end
        add(L.w, { t = now(), kind = "resync", data = { count = n, from = from } })
    end
    for i = from, n do
        local d = FR.vmdump(at(coll, i), 4, { n = 2000 })
        add(L.w, { t = now(), kind = "entry", data = { i = i, collection = name, entry = d } })
        L.lastSig = sig(d)
    end
    L.count = n
    flush(L.w)
end

if not FR.registered then
    FR.registered = true
    Ext.Events.Tick:Subscribe(function()
        local t = now()
        if t < FR.log.next then return end
        FR.log.next = t + FR.LOG_POLL_MS
        local ok, err = pcall(FR.pollLog)
        if not ok then Ext.Utils.PrintWarning("[FightRec] combat log: " .. tostring(err)) end
    end)
end
Ext.Utils.Print("[FightRec] client ready: combat log -> " .. FR.log.w.path)

end
