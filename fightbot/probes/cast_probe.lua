-- Cast probe (read-only): what the engine holds for a cast while it exists, to compare a player's cast with a
-- fightbot (Osi.UseSpell) cast. Question: does the Osiris route carry IgnoreSpellRolls (or other Ignore* options)?
-- Server context, from the Script Extender console:
--   assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("cast_probe.lua"))))()
-- Then make one cast by hand and one with the fightbot. Each cast writes
--   Script Extender\FightBotProbe\<n>-<caster>-<spell>.json
-- with every component of the cast entity, read when the cast starts and again a few frames later, plus any
-- field whose name says Option/Flag/Ignore pulled out on top. It writes nothing to the game.
-- Stop it with CastProbe.stop().

CastProbe = CastProbe or { n = 0, subs = {}, pending = {} }
local P = CastProbe
P.DIR = "FightBotProbe/"
P.LATER_TICKS = { 2, 10, 30 }   -- re-read the cast entity this many ticks after it appeared

local function dump(x, depth)
    local ok, s = pcall(Ext.Json.Stringify, x, { Beautify = false, StringifyInternalTypes = true,
        IterateUserdata = true, AvoidRecursion = true, MaxDepth = depth or 5 })
    if not ok then
        local okS, t = pcall(Ext.Types.Serialize, x)
        if okS then ok, s = pcall(Ext.Json.Stringify, t, { Beautify = false, StringifyInternalTypes = true,
            AvoidRecursion = true, MaxDepth = depth or 5 }) end
    end
    if not ok then return tostring(x) end
    local okP, v = pcall(Ext.Json.Parse, s)
    return okP and v or s
end

-- Fields named like options or flags, anywhere in the dumped tree: the answer at a glance.
local function flagged(tree, path, out)
    if type(tree) ~= "table" then return out end
    for k, v in pairs(tree) do
        local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
        local lk = tostring(k):lower()
        if lk:find("option") or lk:find("flag") or lk:find("ignore") then out[p] = v end
        if type(v) == "table" then flagged(v, p, out) end
    end
    return out
end

local function components(e)
    local out = {}
    local ok, all = pcall(function() return e:GetAllComponents() end)
    if ok and type(all) == "table" then
        for name, c in pairs(all) do out[tostring(name)] = dump(c, 5) end
    else
        out._error = "GetAllComponents: " .. tostring(all)
    end
    return out
end

local function uuidOf(e)
    local ok, u = pcall(function() return e.Uuid.EntityUuid end)
    return ok and u or nil
end

local function nameOf(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return ok and n or tostring(u)
end

local function save(rec)
    local file = string.format("%s%03d-%s-%s.json", P.DIR, rec.n, (rec.caster_name or "?"):gsub("[^%w]", ""),
        tostring(rec.spell or "?"):gsub("[^%w_]", ""))
    local ok, err = pcall(Ext.IO.SaveFile, file, Ext.Json.Stringify(rec, { Beautify = true, StringifyInternalTypes = true,
        AvoidRecursion = true }))
    Ext.Utils.Print("[CastProbe] " .. (ok and ("wrote " .. file) or ("cannot write " .. file .. ": " .. tostring(err))))
end

local function onCasting(caster)
    local cast
    pcall(function() cast = caster.SpellCastIsCasting.Cast end)
    if not cast then return end
    P.n = P.n + 1
    local cu = uuidOf(caster)
    local rec = { n = P.n, caster = cu, caster_name = cu and nameOf(cu), reads = {} }
    local first = components(cast)
    rec.reads[1] = { tick = 0, components = first, flagged = flagged(first, "", {}) }
    pcall(function() rec.spell = cast.SpellCastState.SpellId.Prototype end)
    P.pending[#P.pending + 1] = { rec = rec, cast = cast, ticks = 0, next = 1 }
end

function P.tick()
    for i = #P.pending, 1, -1 do
        local job = P.pending[i]
        job.ticks = job.ticks + 1
        local due = P.LATER_TICKS[job.next]
        if due and job.ticks >= due then
            local comps = components(job.cast)
            job.rec.reads[#job.rec.reads + 1] = { tick = job.ticks, components = comps, flagged = flagged(comps, "", {}) }
            job.next = job.next + 1
        end
        if not P.LATER_TICKS[job.next] then
            save(job.rec)
            table.remove(P.pending, i)
        end
    end
end

function P.stop()
    for _, s in ipairs(P.subs) do pcall(s.off) end
    P.subs = {}
    Ext.Utils.Print("[CastProbe] stopped")
end

if Ext.IsServer() and #P.subs == 0 then
    local ok, id = pcall(Ext.Entity.OnCreate, "SpellCastIsCasting", function(e) pcall(onCasting, e) end)
    P.subs[#P.subs + 1] = { off = function() Ext.Entity.Unsubscribe(id) end }
    local tid = Ext.Events.Tick:Subscribe(function() pcall(P.tick) end)
    P.subs[#P.subs + 1] = { off = function() Ext.Events.Tick:Unsubscribe(tid) end }
    Ext.Utils.Print("[CastProbe] " .. (ok and "watching casts: make one by hand, then one with the fightbot"
        or ("cannot watch casts: " .. tostring(id))))
elseif not Ext.IsServer() then
    Ext.Utils.PrintWarning("[CastProbe] run this in the server context")
end
