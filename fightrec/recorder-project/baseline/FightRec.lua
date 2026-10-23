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

-- Engine objects Stringify only names ("HitDesc (000000151412A8F8)", live 2026-10-22): read every member the
-- extender's type info lists, recursively. Ext.Types.Serialize first, where the type supports it.
function FR.reflect(x, depth)
    depth = depth or 4
    local tx = type(x)
    if tx == "table" then
        local out = {}
        for k, v in pairs(x) do out[k] = depth > 0 and FR.reflect(v, depth - 1) or tostring(v) end
        return out
    end
    if tx ~= "userdata" then return x end
    local ok, t = pcall(function() return Ext.Types.Serialize(x) end)
    if ok and type(t) == "table" then return FR.reflect(t, depth) end
    local okn, tn = pcall(function() return Ext.Types.GetObjectType(x) end)
    tn = okn and tn or nil
    if tn == "Entity" and FR.entityRef then return FR.entityRef(x) end
    local oki, ti = pcall(function() return Ext.Types.GetTypeInfo(tn) end)
    local kind = oki and ti and ti.Kind
    if kind == "Enumeration" or kind == "Bitmask" then   -- live 2026-10-22: these came out as {"_type": "AbilityId"}
        local okl, label = pcall(function() return x.Label end)
        local okv, value = pcall(function() return x.Value end)
        if okl and label ~= nil then return { label = tostring(label), value = okv and value or nil } end
        local okls, labels = pcall(function() return x.Labels end)
        if okls and labels ~= nil then return { labels = FR.reflect(labels, 1), value = okv and value or nil } end
        return tostring(x)
    end
    local members = oki and ti and ti.Members
    if members then
        local out = { _type = okn and tn or nil }
        pcall(function()
            for k in pairs(members) do
                local okv, v = pcall(function() return x[k] end)
                if okv then out[k] = depth > 0 and FR.reflect(v, depth - 1) or tostring(v) end
            end
        end)
        return out
    end
    local list, okp = {}, pcall(function() for k, v in pairs(x) do list[k] = depth > 0 and FR.reflect(v, depth - 1) or tostring(v) end end)
    if okp and next(list) ~= nil then return list end
    return tostring(x)
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
    local u = s:match("%x+%-%x+%-%x+%-%x+%-%x+$")
    if u == "00000000-0000-0000-0000-000000000000" then return nil end   -- the null GUID: no one
    return u
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
    if not u then
        if x == nil or tostring(x):find("00000000-0000-0000-0000-000000000000", 1, true) then return nil end
        return tostring(x)
    end
    return { uuid = u, name = name(u) }
end

FR.entityRef = function(h)
    local ok, u = pcall(function() return h.Uuid.EntityUuid end)
    return ok and u and who(u) or tostring(h)
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
-- Osiris slot names (live 2026-10-22: "MeleeMainHand" found no weapon on a character that hit with one).
local SLOTS = { "Helmet", "Breast", "Cloak", "Melee Main Weapon", "Melee Offhand Weapon", "Ranged Main Weapon",
    "Ranged Offhand Weapon", "Ring", "Ring2", "Amulet", "Boots", "Gloves", "Underwear", "MusicalInstrument" }
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
    out.ac = osi(function() return e.Resistances.AC end)   -- AC lives in Resistances (Stats has none)
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
    local function field(e, k)
        local ok, v = pcall(function() return e[k] end)
        return ok and v or nil
    end
    local shapes = {}
    local function entity(h)
        local ok, u = pcall(function() return h.Uuid.EntityUuid end)
        return ok and u or nil
    end
    for _, evname in ipairs({ "BeforeDealDamage", "DealDamage", "DealtDamage" }) do
        subscribe(evname, function(e)
            -- DamageSums is the old name of Attack (the extender warns on it). Fields differ per event (BeforeDealDamage has
            -- no Caster): a missing one is a Lua error, so read each safely.
            local cu, tu = entity(field(e, "Caster")), entity(field(e, "Target"))
            local inv = involvement(cu, tu)
            if (cu or tu) and not inv then return end
            local data = { caster = who(cu), target = who(tu), spell = FR.reflect(field(e, "SpellId"), 3),
                hit = FR.reflect(field(e, "Hit"), 8), attack = FR.reflect(field(e, "Attack"), 4) }
            if not shapes[evname] then   -- the event's whole shape once per load, to find fields not read above
                shapes[evname] = true
                data.shape = FR.reflect(e, 1)
            end
            record(evname, data, inv)
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
    if coll == nil then return 0 end
    local ok, n = pcall(function() return coll:GetProperty("Count") end)
    if ok and tonumber(n) then return tonumber(n) end
    ok, n = pcall(function() return coll.Count end)
    if ok and tonumber(n) then return tonumber(n) end
    ok, n = pcall(function() return #coll end)
    return ok and tonumber(n) or 0
end
-- i is 1-based; At's own base (0 or 1) is learned on the first non-empty collection.
local function at(coll, i)
    if FR.atBase == nil and count(coll) > 0 then
        local ok0, v0 = pcall(function() return coll:At(0) end)
        FR.atBase = (ok0 and v0 ~= nil) and 0 or 1
    end
    local ok, v = pcall(function() return coll:At(i - 1 + (FR.atBase or 1)) end)
    if ok and v ~= nil then return v end
    -- live 2026-10-22: Data.CombatLog.EntryGroups is an extender array (plain userdata, no At): 1-based index
    ok, v = pcall(function() return coll[i] end)
    return ok and v or nil
end
local function props(vm) local ok, p = pcall(function() return vm:GetAllProperties() end) return ok and p or {} end
local function isCollection(tn) return type(tn) == "string" and tn:find("Collection") ~= nil end
-- GetAllProperties only on view models (namespaced types), never on live elements: on an element it can
-- crash the game while the UI rebuilds it.
local function isViewModel(tn)
    return type(tn) == "string" and (tn:find("::", 1, true) or tn:find("^ls%.") or tn:find("^gui%."))
        and not tn:find("^Noesis")
end
-- IsSeen flips once the log is shown, which would make a written entry look changed.
local SKIP = { CurrentPlayer = true, Data = true, Players = true, PlayerList = true, IsSeen = true }

-- Members the combat log XAML binds (Game.pak Mods/MainUI/GUI/Pages/CombatLog.xaml): read by name when
-- GetAllProperties gives nothing, so an entry is never just a type name.
local KNOWN = { "Entries", "TooltipEntries", "ParamTooltips", "CtxTransText", "ChildDepth", "Text", "Message",
    "Id" }
function FR.knownFields(obj, out, depth, budget)
    for _, k in ipairs(KNOWN) do
        if out[k] == nil then
            local v = get(obj, k)
            if v ~= nil then out[k] = FR.vmdump(v, depth - 1, budget) end
        end
    end
end

function FR.vmdump(obj, depth, budget)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return obj end
    budget.n = budget.n - 1
    local tn = typeName(obj) or "?"
    if budget.n <= 0 then return { _type = tn, _cut = true } end
    if tn:find("Command") then return { _cmd = tn } end
    -- untyped ("?") userdata may be an extender array; never probe Noesis objects for Count (live 2026-10-22:
    -- "Object ImageBrush has no property named 'Count'" on every poll)
    if isCollection(tn) or (tn == "?" and count(obj) > 0 and at(obj, 1) ~= nil) then
        local n, items = count(obj), {}
        if depth > 0 then for i = 1, math.min(n, 30) do items[i] = FR.vmdump(at(obj, i), depth - 1, budget) end end
        return { _type = tn, _count = n, _items = items }
    end
    if not isViewModel(tn) then
        local ok, s = pcall(function() return obj:ToString() end)
        local out = { _type = tn, _text = ok and type(s) == "string" and s ~= "" and s or nil }
        if depth > 0 then FR.knownFields(obj, out, depth, budget) end
        return out
    end
    local out = { _type = tn }
    if depth <= 0 then out._cut = true return out end
    local any = false
    for k, v in pairs(props(obj)) do
        if not SKIP[k] then out[k] = FR.vmdump(v, depth - 1, budget) any = true end
    end
    if not any then FR.knownFields(obj, out, depth, budget) end
    return out
end

local function isLogDC(tn) return type(tn) == "string" and tn:lower():find("combatlog") ~= nil end

FR.SEARCH_BUDGET = 40000 -- elements visited per search

-- An element's visual children; 0- or 1-based, learned on the first element that has any.
local function children(el)
    local out = {}
    local n = tonumber(get(el, "VisualChildrenCount")) or 0
    if n == 0 then return out end
    if FR.childBase == nil then
        local ok0, c0 = pcall(function() return el:VisualChild(0) end)
        FR.childBase = (ok0 and c0 ~= nil) and 0 or 1
    end
    for i = FR.childBase, FR.childBase + n - 1 do
        local ok, c = pcall(function() return el:VisualChild(i) end)
        if ok and c ~= nil then out[#out + 1] = c end
    end
    return out
end

-- Breadth-first over the visual tree (only inside Ext.UI.Defer, the UI's own time) for elements whose DataContext
-- or name says combat log, without descending into a match (its children share its DataContext). Live
-- 2026-10-22: the log is not a page under ContentRoot, and there may be more than one (collapsed / expanded).
function FR.searchLog(root)
    local queue, routes, head, tail, seen, found = { root }, { {} }, 1, 1, 0, {}
    while queue[head] and seen < FR.SEARCH_BUDGET and #found < 10 do
        local el, route = queue[head], routes[head]
        queue[head], routes[head] = nil, nil
        head, seen = head + 1, seen + 1
        local dc = get(el, "DataContext")
        local tn = dc and typeName(dc)
        if dc and (isLogDC(tn) or isLogDC(get(el, "Name"))) then
            found[#found + 1] = { el = el, dc = dc, dcType = tn, name = get(el, "Name"), type = typeName(el),
                route = route }
        else
            for i, c in ipairs(children(el)) do
                tail = tail + 1
                queue[tail] = c
                local r = { table.unpack(route) }
                r[#r + 1] = i
                routes[tail] = r
            end
        end
    end
    return found, seen
end

-- The element at a route from the root, or nil when the tree changed.
function FR.walk(root, route)
    local el = root
    for _, i in ipairs(route) do
        local n = tonumber(get(el, "VisualChildrenCount")) or 0
        if i > n then return nil end
        local ok, c = pcall(function() return el:VisualChild((FR.childBase or 0) + i - 1) end)
        if not ok or c == nil then return nil end
        el = c
    end
    return el
end

local LOGGY = { "log", "entr", "message", "history", "line" }
local function loggy(k)
    k = tostring(k):lower()
    for _, w in ipairs(LOGGY) do if k:find(w, 1, true) then return true end end
    return false
end

-- Where the entries can be. Live 2026-10-22 gui::DCCombatLog itself holds only settings and commands
-- (CombatLogCollapsed, MarkCombatLogGroupEntrySeen, ...), so look further:
--   * the ItemsSource of every list control inside the log panel;
--   * view-model properties named like a log, entries, messages or lines, from the DataContext down through its
--     shared base (Data, CurrentPlayer), up to 4 levels.
function FR.candidates(dc, el)
    local out = {}
    if el then
        local q, h, tl, seen = { el }, 1, 1, 0
        while q[h] and seen < 3000 do
            local e = q[h]
            q[h], h, seen = nil, h + 1, seen + 1
            local src = get(e, "ItemsSource")
            if src and isCollection(typeName(src)) then
                out[#out + 1] = { path = "ItemsSource of " .. tostring(get(e, "Name") or "") .. " (" ..
                    tostring(typeName(e)) .. ")", coll = src, items = true }
            end
            for _, c in ipairs(children(e)) do tl = tl + 1 q[tl] = c end
        end
    end
    local q, h, tl, visited, budget = { { obj = dc, path = "", d = 0 } }, 1, 1, {}, 4000
    while q[h] and budget > 0 do
        local node = q[h]
        q[h], h = nil, h + 1
        local p = props(node.obj)
        if node.d == 0 then   -- the shared base, in case GetAllProperties leaves inherited members out
            for _, k in ipairs({ "Data", "CurrentPlayer" }) do if p[k] == nil then p[k] = get(node.obj, k) end end
        end
        for k, v in pairs(p) do
            budget = budget - 1
            local tn = typeName(v)
            local path = node.path == "" and k or (node.path .. "." .. k)
            if isCollection(tn) then
                if loggy(k) then out[#out + 1] = { path = path, coll = v } end
            elseif isViewModel(tn) and node.d < 4 then
                local key = tostring(v)
                if not visited[key] then visited[key] = true tl = tl + 1 q[tl] = { obj = v, path = path, d = node.d + 1 } end
            end
        end
    end
    return out
end

local function score(c)
    local n, p = count(c.coll), c.path:lower()
    return (c.direct and 8 or 0) + (p:find("combatlog") and 4 or 0) + (n > 0 and 2 or 0) + (c.items and 1 or 0)
end

-- What a log panel looks like when no entries were found: its DataContext's members and the first elements
-- below it, so the next version can be pointed at the right place.
function FR.shape(m)
    local members = {}
    local p = props(m.dc)
    for _, k in ipairs({ "Data", "CurrentPlayer" }) do if p[k] == nil then p[k] = get(m.dc, k) end end
    for k, v in pairs(p) do
        local tn = typeName(v)
        if not (tn and tn:find("Command")) then
            members[k] = isCollection(tn) and (tn .. "[" .. count(v) .. "]") or tn or v
        end
    end
    local tree, q, h, tl = {}, { { e = m.el, d = 0 } }, 1, 1
    while q[h] and #tree < 150 do
        local n = q[h]
        q[h], h = nil, h + 1
        local src = get(n.e, "ItemsSource")
        local dc = get(n.e, "DataContext")
        tree[#tree + 1] = { d = n.d, type = typeName(n.e), name = get(n.e, "Name"),
            dc = dc ~= m.dc and typeName(dc) or nil,
            items = src and (tostring(typeName(src)) .. "[" .. count(src) .. "]") or nil }
        for _, c in ipairs(children(n.e)) do tl = tl + 1 q[tl] = { e = c, d = n.d + 1 } end
    end
    return { element = m.name, type = m.type, dc = m.dcType, members = members, tree = tree }
end

local function entryGroups(dc)
    local d = get(dc, "Data")
    local cl = d and get(d, "CombatLog")
    return cl and get(cl, "EntryGroups"), d, cl
end

-- path, collection of the log's entries, or nil. Noesis objects live only for the deferred callback that read
-- them (live 2026-10-22: "got Noesis::BaseCollection whose lifetime has expired" on the next poll), so only the
-- panel's route from the root is kept and everything is read again each poll. The panel is searched for when
-- the route breaks, at most every 2 s.
function FR.locate()
    local L = FR.log
    local root = get(Ext.UI, "GetRoot") and Ext.UI.GetRoot()
    if not root then return nil end
    if L.route then
        local el = FR.walk(root, L.route)
        local dc = el and get(el, "DataContext")
        if dc and isLogDC(typeName(dc)) then
            local eg = entryGroups(dc)
            if eg ~= nil then return "Data.CombatLog.EntryGroups", eg end
        end
        L.route = nil
        add(L.w, { t = now(), kind = "route_lost", data = {} })
    end
    local t = now()
    if t < (L.nextTry or 0) then return nil end
    L.nextTry = t + 2000
    local matches, seen = FR.searchLog(root)
    local best, bestN, listed = nil, -1, {}
    -- The binding the panel itself uses (CombatLog.xaml: ItemsSource="{Binding Data.CombatLog.EntryGroups}").
    -- Each step's type is logged so a renamed member shows where the path broke.
    for _, m in ipairs(matches) do
        local eg, d, cl = entryGroups(m.dc)
        local steps = { "Data=" .. tostring(d and typeName(d) or d ~= nil and type(d) or "nil"),
            "CombatLog=" .. tostring(cl and typeName(cl) or cl ~= nil and type(cl) or "nil"),
            "EntryGroups=" .. tostring(eg and typeName(eg) or eg ~= nil and type(eg) or "nil") }
        if eg ~= nil and count(eg) > bestN then best, bestN = { m = m, eg = eg }, count(eg) end
        listed[#listed + 1] = { panel = m.name, route = m.route, steps = steps, count = eg and count(eg) or nil }
    end
    L.tries = (L.tries or 0) + 1
    if L.tries <= 3 or best then
        local panels = {}
        for i, m in ipairs(matches) do panels[i] = { element = m.name, type = m.type, dc = m.dcType } end
        add(L.w, { t = t, kind = "locate", data = { visited = seen, panels = panels, candidates = listed,
            chosen = best and "Data.CombatLog.EntryGroups" or nil } })
        if not best and L.tries <= 2 then
            for i, m in ipairs(matches) do
                if i <= 3 then
                    local ok, sh = pcall(FR.shape, m)
                    add(L.w, { t = t, kind = "shape", data = ok and sh or { error = tostring(sh) } })
                end
            end
        end
        flush(L.w, true)
    end
    if not best then return nil end
    L.route = best.m.route
    return "Data.CombatLog.EntryGroups", best.eg
end

FR.log = FR.log or { w = writer("combatlog"), count = 0, lastSig = nil, next = 0 }

-- Deep enough for a hit's roll breakdown: group > CtxTransText > Params > param > TooltipEntries > entry > ...
FR.ENTRY_DEPTH, FR.ENTRY_BUDGET = 8, 6000
local function entry(coll, i) return FR.vmdump(at(coll, i), FR.ENTRY_DEPTH, { n = FR.ENTRY_BUDGET }) end
FR.MAX_PER_POLL = 2   -- entries written per poll: a full dump can take tens of ms (live 2026-10-22: 186 ms polls)
-- A cheap identity for an entry (first entry's type and timestamp, the text), to notice the log moved without
-- dumping it.
local function fp(coll, i)
    local g = at(coll, i)
    if g == nil then return "nil" end
    local es = get(g, "Entries")
    local e = es and at(es, 1)
    local ct = get(g, "CtxTransText")
    return tostring(e and typeName(e)) .. "|" .. tostring(e and get(e, "Timestamp")) .. "|" ..
        tostring(ct and get(ct, "Text"))
end

function FR.pollLog()
    local L = FR.log
    local name, coll = FR.locate()
    if not coll then return end
    local n = count(coll)
    -- The log can drop old entries or be rebuilt (a load): if the last known entry moved, find it again.
    local from = L.count + 1
    if L.lastSig and (n < L.count or fp(coll, L.count) ~= L.lastSig) then
        -- not found: a rebuilt log starts over, a grown one only lost the match (an entry changed after it was
        -- written), so carry on after the old count instead of writing everything again
        from = n < L.count and 1 or L.count + 1
        for i = n, 1, -1 do
            if fp(coll, i) == L.lastSig then from = i + 1 break end
        end
        add(L.w, { t = now(), kind = "resync", data = { count = n, from = from } })
        if from > n and n > 0 then L.lastSig = fp(coll, n) end   -- once per change
    end
    local last = math.min(n, from + FR.MAX_PER_POLL - 1)
    for i = from, last do
        add(L.w, { t = now(), kind = "entry", data = { i = i, collection = name, entry = entry(coll, i) } })
        L.lastSig = fp(coll, i)
    end
    L.count = math.max(last, from - 1)
    flush(L.w)
end

if not FR.registered then
    FR.registered = true
    Ext.Events.Tick:Subscribe(function()
        local t = now()
        if t < FR.log.next then return end
        FR.log.next = t + FR.LOG_POLL_MS
        local function poll()
            local ok, err = pcall(FR.pollLog)
            if not ok then
                FR.log.route, FR.log.nextTry = nil, 0   -- rebuilt (a load): find it again
                Ext.Utils.PrintWarning("[FightRec] combat log: " .. tostring(err))
                FR.log.errors = (FR.log.errors or 0) + 1
                if FR.log.errors <= 20 then
                    add(FR.log.w, { t = now(), kind = "error", data = { error = tostring(err), n = FR.log.errors } })
                    flush(FR.log.w, true)
                end
            end
        end
        -- Noesis is safe to read only in a deferred UI callback (the extender warns from Tick); older
        -- extenders have no Defer.
        if not (Ext.UI.Defer and pcall(Ext.UI.Defer, poll)) then poll() end
    end)
end
Ext.Utils.Print("[FightRec] client ready: combat log -> " .. FR.log.w.path)

end
