-- Offline tests of tools/probes/lv01_status_probe.lua (v1, retained) and lv01_status_probe_v2.lua against a small fake of the pinned declarations it reads
-- (LuaEntityProxy.inl Index/HasRawComponent/GetAllComponentNames, Entity.inl GetAllEntitiesWithComponent,
-- Components/Status.h ServerStatus + ServerStatusOwnership, IO.inl, Osiris DB/queries). Validates the probe's logic, not live SE.
-- usage: python tools/lua54.py tests/test_probe.lua [name-filter]
local json = require("json")
local H = require("harness")
local T = H

local PROBE = host.repo .. "/tools/probes/lv01_status_probe.lua"
local PROBE2 = os.getenv("FR2_PROBE2") or (host.repo .. "/tools/probes/lv01_status_probe_v2.lua") -- override: mutant runs
local FILTER = arg[1]

local function guid(n) return string.format("%08x-0000-4000-8000-%012x", n, n) end

-- spec{ actors = { {u, party, container = {{h,id},...} | nil, statuses = {{h,id},...}} }, ... }
-- Status entities carry ServerStatusOwnership.Owner = bearer. ServerStatus.Entity follows spec.entityField:
--   nil (default, matches live lv01-status-1792760275.json: never a target handle) | "bearer" (v1's assumption).
-- spec.others = n unrelated statuses owned by a non-target; spec.noOwnership / spec.badOwner / spec.badInstance
-- = { [statusHandle] = true }; spec.enumFail = true makes the ServerStatus enumeration throw.
local function fake(spec)
    local w = { fs = {}, saves = 0, osi = {}, globals = {}, printed = {}, handles = 0 }
    local function handle(n) return setmetatable({ __h = n }, { __name = "EntityHandle" }) end
    local entities, statusEntities, combatMembers, players = {}, {}, {}, {}
    for i, a in ipairs(spec.actors) do
        local e = { __h = 1000 + i, comps = {} }
        if a.container then
            local m = {}
            for _, s in ipairs(a.container) do m[handle(s[1])] = s[2] end
            e.comps.StatusContainer = { Statuses = m }
        end
        entities[a.u] = e
        combatMembers[#combatMembers + 1] = { a.u, "COMBAT_1" }
        if a.party then players[#players + 1] = { a.u } end
        for _, s in ipairs(a.statuses or {}) do
            statusEntities[#statusEntities + 1] = { __h = s[1], bearer = e.__h, id = s[2], active = true }
        end
    end
    for i = 1, spec.others or 0 do
        statusEntities[#statusEntities + 1] = { __h = 70000 + i, bearer = 5000 + i % 7, id = "OTHER", active = true }
    end
    for _, st in ipairs(statusEntities) do
        local ent = spec.entityField == "bearer" and st.bearer or (900000 + st.__h)
        st.comps = { ServerStatus = { Entity = handle(ent), StatusId = st.id, Type = "BOOST" } }
        if not (spec.noOwnership and spec.noOwnership[st.__h]) then
            local own = (spec.badOwner and spec.badOwner[st.__h]) and handle("unreadable") or handle(st.bearer)
            st.comps.ServerStatusOwnership = { Owner = own }
        end
        if spec.badInstance and spec.badInstance[st.__h] then st.__h = "unreadable" end
    end
    local function proxy(rec)
        return setmetatable({}, {
            __index = function(_, k)
                if k == "HasRawComponent" then
                    return function(_, n)
                        if n == "eoc::status::ContainerComponent" then return rec.comps.StatusContainer ~= nil end
                        if n == "esv::status::ActiveComponent" then return rec.active == true end
                        return false
                    end
                elseif k == "GetAllComponentNames" then
                    return function(_, requireMapped)
                        T.eq(requireMapped, nil, "all names requested")
                        local out = { "eoc::HealthComponent" }
                        if rec.comps.StatusContainer then out[#out + 1] = "eoc::status::ContainerComponent" end
                        return out
                    end
                elseif k == "StatusContainer" or k == "ServerStatus" or k == "ServerStatusOwnership" or k == "Health" then
                    local c = rec.comps[k]
                    if c == nil then return nil end -- pinned Index: mapped name, raw component absent -> nil
                    return setmetatable({}, { __index = c, __newindex = function() error("read-only") end,
                        __pairs = function() return next, c, nil end })
                end
                error("Not a valid EntityProxy method or component type: " .. tostring(k))
            end,
            __newindex = function() error("entity proxy is read-only") end,
            __hid = rec.__h,
        })
    end
    local proxies = {}
    local function P(rec) proxies[rec] = proxies[rec] or proxy(rec) return proxies[rec] end
    local function hid(x)
        if type(x) == "table" and rawget(x, "__h") then return x.__h end
        local mt = getmetatable(x)
        if mt and mt.__hid then return mt.__hid end
        error("not a handle")
    end
    local Ext = {
        Utils = { HandleToInteger = function(x) return hid(x) end, MonotonicTime = function() return 5000 end,
            GameVersion = function() return "v4.76.31.656" end, Version = function() return 33 end,
            Print = function(s) w.printed[#w.printed + 1] = s end },
        Timer = { ClockEpoch = function() return 1792760000 end },
        Entity = {
            Get = function(u) return entities[u] and P(entities[u]) or nil end,
            GetAllEntitiesWithComponent = function(n)
                local out = {}
                if n == "ServerStatus" then
                    if spec.enumFail then error("enumeration failed (fake)") end
                    for _, s in ipairs(statusEntities) do out[#out + 1] = P(s) end
                elseif n == "StatusContainer" then
                    for _, e in pairs(entities) do if e.comps.StatusContainer then out[#out + 1] = P(e) end end
                end
                return out
            end,
        },
        Json = { Stringify = function(x) return json.encode(x) end },
        IO = {
            LoadFile = function(p) return w.fs[p] end,
            SaveFile = function(p, s) w.saves = w.saves + 1 w.fs[p] = s return true end,
        },
    }
    local allowedOsi = { DB_Players = true, DB_Is_InCombat = true, CombatGetGuidFor = true, GetDisplayName = true,
        ResolveTranslatedString = true, HasActiveStatus = true }
    local Osi = setmetatable({
        DB_Players = { Get = function() return players end },
        DB_Is_InCombat = { Get = function(_, _, c) T.eq(c, "COMBAT_1") return combatMembers end },
        CombatGetGuidFor = function() return "COMBAT_1" end,
        GetDisplayName = function(u) return "h_" .. u end,
        ResolveTranslatedString = function(h) return "Name " .. h:sub(-4) end,
        HasActiveStatus = function(u, id)
            local e = entities[u]
            for _, s in ipairs(statusEntities) do
                if s.bearer == e.__h and s.id == id then return 1 end
            end
            return 0
        end,
    }, { __index = function(_, k) error("probe called non-allowlisted Osiris symbol " .. tostring(k)) end })
    for k in pairs(allowedOsi) do
        local f = rawget(Osi, k)
        if type(f) == "function" then
            rawset(Osi, k, function(...) w.osi[k] = (w.osi[k] or 0) + 1 return f(...) end)
        end
    end
    local env = setmetatable({ Ext = Ext, Osi = Osi }, {
        __index = _G,
        __newindex = function(t, k, v) w.globals[#w.globals + 1] = k rawset(t, k, v) end,
    })
    rawset(env, "_G", env)
    w.env = env
    function w.run(path)
        local fh = assert(io.open(path or PROBE, "rb"))
        local src = fh:read("a")
        fh:close()
        local f = assert(load(src, "@" .. (path or PROBE):match("[^/]+$"), "t", env))
        local out = f()
        return json.decode(out)
    end
    return w
end

local function byName(r)
    local m = {}
    for _, t in ipairs(r.targets) do m[t.uuid] = t end
    return m
end

local function lv01(extra)
    local actors = {}
    for i = 1, 4 do actors[#actors + 1] = { u = guid(i), party = true } end
    for i = 5, 8 do
        local a, b = 100 * i + 1, 100 * i + 2
        actors[#actors + 1] = { u = guid(i), container = { { a, "ENABLE_AOO" }, { b, "HEALTHBOOST_HARDCORE" } },
            statuses = { { a, "ENABLE_AOO" }, { b, "HEALTHBOOST_HARDCORE" } } }
    end
    if extra then extra(actors) end
    return actors
end

H.case("v1 LV01 shape (v1's Entity=bearer world): absent party containers with no status entities, controls validate the route", function()
    local w = fake({ actors = lv01(), entityField = "bearer" })
    w.fs["FightRec2Probe/lv01-status-1792760000.json"] = "earlier"
    local r = w.run()
    T.eq(#r.targets, 8)
    T.eq(r.route_validated, true)
    T.eq(r.controls_matching, 4) T.eq(r.controls_mismatching, 0)
    T.eq(r.server_status_entities, 8)
    T.eq(#r.errors, 0, table.concat(r.errors, "; "))
    local m = byName(r)
    for i = 1, 4 do
        local t = m[guid(i)]
        T.eq(t.role, "party")
        T.eq(t.container_read, "nil")
        T.eq(t.has_raw_container, false)
        T.eq(#t.owned, 0)
        T.eq(t.osiris_active_count, 0)
        T.eq(t.verdict, "ABSENT_AND_NO_STATUS_ENTITIES")
    end
    T.eq(m[guid(5)].verdict, "PRESENT_MATCHES_ROUTE")
    T.eq(m[guid(5)].osiris_active.ENABLE_AOO, 1)
    T.eq(w.fs["FightRec2Probe/lv01-status-1792760000.json"], "earlier", "existing file not overwritten")
    T.ok(w.fs["FightRec2Probe/lv01-status-1792760000-1.json"], "new file written")
    T.eq(w.saves, 1)
    T.eq(#w.globals, 0, "no globals written")
    T.ok(w.printed[1]:find("route_validated=true", 1, true))
end)

H.case("v1 absent container but a status entity owned by the actor is reported, not read as empty", function()
    local w = fake({ actors = lv01(function(a) a[2].statuses = { { 77, "TRAVELBLOCK_CANTMOVE" } } end), entityField = "bearer" })
    local r = w.run()
    local t = byName(r)[guid(2)]
    T.eq(t.verdict, "ABSENT_BUT_STATUSES_EXIST")
    T.eq(t.owned[1].id, "TRAVELBLOCK_CANTMOVE")
    T.eq(t.osiris_active.TRAVELBLOCK_CANTMOVE, 1)
    T.eq(byName(r)[guid(1)].verdict, "ABSENT_AND_NO_STATUS_ENTITIES")
end)

H.case("v1 control mismatch leaves absent actors unresolved", function()
    local w = fake({ actors = lv01(function(a) a[6].statuses = { { 601, "ENABLE_AOO" } } end), entityField = "bearer" })
    local r = w.run()
    T.eq(r.route_validated, false)
    T.eq(r.controls_mismatching, 1)
    T.eq(byName(r)[guid(6)].verdict, "PRESENT_MISMATCH")
    for i = 1, 4 do T.eq(byName(r)[guid(i)].verdict, "UNRESOLVED_route_not_validated") end
end)

H.case("v1 no control actors: route unvalidated, nothing saved when LV01_PROBE_NO_SAVE", function()
    local actors = {}
    for i = 1, 2 do actors[#actors + 1] = { u = guid(i), party = true } end
    local w = fake({ actors = actors })
    rawset(w.env, "LV01_PROBE_NO_SAVE", true)
    local r = w.run()
    T.eq(r.route_validated, false)
    T.eq(byName(r)[guid(1)].verdict, "UNRESOLVED_route_not_validated")
    T.eq(w.saves, 0)
end)

-- Live-like world (default entityField): ServerStatus.Entity never names a target, Owner names the bearer.
H.case("v1 on the live-like world reproduces lv01-status-1792760275: 0 controls, route not validated", function()
    local r = fake({ actors = lv01(), others = 20 }).run(PROBE)
    T.eq(r.controls_matching, 0) T.eq(r.controls_mismatching, 4)
    T.eq(r.route_validated, false)
    T.eq(r.server_status_other_owners, 28, "every status entity unmatched, as live")
    for i = 1, 4 do T.eq(byName(r)[guid(i)].verdict, "UNRESOLVED_route_not_validated") end
end)

H.case("v2 Owner route: controls validate, absent party actors with no owned statuses", function()
    local w = fake({ actors = lv01(), others = 20 })
    w.fs["FightRec2Probe/lv01-status-v2-1792760000.json"] = "earlier"
    local r = w.run(PROBE2)
    T.eq(r.probe_version, 2)
    T.eq(r.error_count, 0, table.concat(r.errors, "; "))
    T.eq(r.scan.total, 28) T.eq(r.scan.scanned, 28)
    T.eq(r.scan.owner_is_target, 8) T.eq(r.scan.owner_other, 20)
    T.eq(r.controls, 4) T.eq(r.controls_matching, 4)
    T.eq(r.route_validated, true)
    for k, v in pairs(r.gates) do T.eq(v, true, "gate " .. k) end
    local m = byName(r)
    for i = 1, 4 do
        T.eq(m[guid(i)].container_read, "nil")
        T.eq(m[guid(i)].verdict, "ABSENT_AND_NO_STATUS_ENTITIES")
    end
    local q = m[guid(5)]
    T.eq(q.verdict, "PRESENT_MATCHES_ROUTE")
    T.eq(q.control_keys_in_scan, 2) T.eq(q.control_keys_owner_ok, 2)
    T.eq(q.key_rows[1].owner, 1005) T.eq(q.key_rows[1].entity, 900000 + 501, "Entity kept as diagnostic only")
    T.eq(w.fs["FightRec2Probe/lv01-status-v2-1792760000.json"], "earlier", "existing file not overwritten")
    T.ok(w.fs["FightRec2Probe/lv01-status-v2-1792760000-1.json"])
    T.eq(w.saves, 1) T.eq(#w.globals, 0)
    T.ok(w.printed[1]:find("route_validated=true", 1, true))
end)

H.case("v2 party status owned via Owner is reported as existing, not empty", function()
    local r = fake({ actors = lv01(function(a) a[3].statuses = { { 77, "TRAVELBLOCK_CANTMOVE" } } end) }).run(PROBE2)
    T.eq(r.route_validated, true)
    local t = byName(r)[guid(3)]
    T.eq(t.verdict, "ABSENT_BUT_STATUSES_EXIST")
    T.eq(t.owned[1].id, "TRAVELBLOCK_CANTMOVE")
end)

H.case("v2 in a world where Entity also names the bearer still validates via Owner", function()
    local r = fake({ actors = lv01(), entityField = "bearer" }).run(PROBE2)
    T.eq(r.route_validated, true)
    T.eq(r.scan.entity_eq_owner, 8)
end)

local function unresolved(r, gate)
    T.eq(r.route_validated, false)
    if gate then T.eq(r.gates[gate], false, "gate " .. gate) end
    for i = 1, 4 do T.eq(byName(r)[guid(i)].verdict, "UNRESOLVED_route_not_validated") end
end

H.case("v2 gate: an unrelated status entity without Ownership blocks the verdict", function()
    local r = fake({ actors = lv01(), others = 5, noOwnership = { [70003] = true } }).run(PROBE2)
    T.eq(r.scan.ownership_absent, 1)
    T.eq(r.controls_matching, 4, "controls alone are not sufficient")
    unresolved(r, "no_missing_handles")
end)

H.case("v2 gate: unreadable Owner handle blocks the verdict", function()
    local r = fake({ actors = lv01(), others = 5, badOwner = { [70002] = true } }).run(PROBE2)
    T.eq(r.scan.owner_unreadable, 1)
    unresolved(r, "no_missing_handles")
end)

H.case("v2 gate: status entity without an instance handle blocks the verdict", function()
    local r = fake({ actors = lv01(), others = 5, badInstance = { [70004] = true } }).run(PROBE2)
    T.eq(r.scan.missing_instance, 1)
    unresolved(r, "no_missing_handles")
end)

H.case("v2 gate: enumeration failure is not an empty scan", function()
    local r = fake({ actors = lv01(), enumFail = true }).run(PROBE2)
    T.eq(r.scan.enumerated, false)
    T.eq(r.gates.no_errors, false)
    unresolved(r, "scan_complete")
end)

H.case("v2 gate: control key missing from the scan or extra owned status fails the control", function()
    local r = fake({ actors = lv01(function(a) a[6].statuses = { { 601, "ENABLE_AOO" } } end) }).run(PROBE2)
    local t = byName(r)[guid(6)]
    T.eq(t.verdict, "PRESENT_MISMATCH") T.eq(t.control_keys_in_scan, 1)
    unresolved(r, "all_controls_match")
    local r2 = fake({ actors = lv01(function(a)
        a[8].statuses[#a[8].statuses + 1] = { 802, "HEALTHBOOST_HARDCORE" }
        a[8].statuses[#a[8].statuses + 1] = { 803, "EXTRA" }
    end) }).run(PROBE2)
    T.eq(byName(r2)[guid(8)].verdict, "PRESENT_MISMATCH", "extra owned status outside the container")
    unresolved(r2, "all_controls_match")
end)

H.case("v2 gate: no control actors leaves absent actors unresolved", function()
    local actors = {}
    for i = 1, 4 do actors[#actors + 1] = { u = guid(i), party = true } end
    local w = fake({ actors = actors, others = 3 })
    rawset(w.env, "LV01_PROBE_NO_SAVE", true)
    unresolved(w.run(PROBE2), "controls_present")
    T.eq(w.saves, 0)
end)

H.case("probe sources contain no console multi-line terminators and only allowlisted engine writes", function()
    for _, path in ipairs({ PROBE, PROBE2 }) do
        local fh = assert(io.open(path, "rb"))
        local src = fh:read("a")
        fh:close()
        for line in (src .. "\n"):gmatch("(.-)\r?\n") do
            T.no(line == "]]--" or line == "--[[", "line would break SE console multi-line paste")
        end
        T.no(src:find("[\128-\255]"), "ASCII only")
        for _, bad in ipairs({ "ApplyStatus", "RemoveStatus", "SetHitpoints", "CreateComponent", "RemoveComponent",
            "AppendFile", "Replicate", "FightRecV2" }) do
            T.no(src:find(bad, 1, true), "probe must not reference " .. bad)
        end
    end
end)

os.exit(H.run(FILTER) == 0 and 0 or 1)
