-- LV01 read-only status probe (server context). Author: Claude Opus 5.5 (claude-opus-5-5), 2026-10-23.
-- Question: party entities read e.StatusContainer == nil (pinned LuaEntityProxy.inl Index: nil <=> the entity lacks
-- the raw eoc::status::ContainerComponent). Does that absence mean "no statuses", or are statuses held elsewhere?
-- Method: for party + combat members, compare the StatusContainer keys with an independent enumeration of every
-- server status entity (esv::status::StatusComponent, pinned Components/Status.h: Entity, StatusId, Type) and with
-- Osiris HasActiveStatus. Actors whose container IS present are the control: their container keys must equal the
-- status entities whose ServerStatus.Entity is that actor, otherwise the cross-check route is not validated.
-- Reads only: no Osiris calls with effects, no component writes, no recorder access, no globals. The only write is
-- one NEW JSON file FightRec2Probe/lv01-status-<epoch>[-n].json (probed with LoadFile first; never overwritten).
-- Optional: set a global LV01_PROBE_NO_SAVE = true before running to skip the file and only print.
local P = { probe = "lv01-status", probe_version = 1, errors = {} }
local function try(label, f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    P.errors[#P.errors + 1] = label .. ": " .. tostring(v)
    return nil
end
local function guid(x)
    return type(x) == "string" and (x:match("%x+%-%x+%-%x+%-%x+%-%x+$") or x) or nil
end
local function hint(h)
    local ok, v = pcall(Ext.Utils.HandleToInteger, h)
    return ok and math.type(v) and v or nil
end
local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

P.t_ms = try("MonotonicTime", Ext.Utils.MonotonicTime)
P.epoch = try("ClockEpoch", Ext.Timer.ClockEpoch)
P.game = try("GameVersion", Ext.Utils.GameVersion)
P.se = try("Version", Ext.Utils.Version)

-- Targets: party (DB_Players) and every member of the party's combats (DB_Is_InCombat).
local targets, order = {}, {}
local function add(u, role)
    u = guid(u)
    if u and not targets[u] then
        targets[u] = { uuid = u, role = role }
        order[#order + 1] = u
    end
end
for _, r in ipairs(try("DB_Players", function() return Osi.DB_Players:Get(nil) end) or {}) do add(r[1], "party") end
local combats = {}
for _, u in ipairs(order) do
    local c = try("CombatGetGuidFor", Osi.CombatGetGuidFor, u)
    if type(c) == "string" then combats[c] = true end
end
P.combats = sortedKeys(combats)
for _, c in ipairs(P.combats) do
    for _, r in ipairs(try("DB_Is_InCombat", function() return Osi.DB_Is_InCombat:Get(nil, c) end) or {}) do
        add(r[1], "combat")
    end
end

-- Per target: entity handle, container presence (two reads), container keys, status-ish component names.
local byHandle = {}
for _, u in ipairs(order) do
    local t = targets[u]
    t.name = try("name", function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    local e = try("Entity.Get", Ext.Entity.Get, u)
    if not e then
        t.entity = "unavailable"
    else
        t.handle = hint(e)
        if t.handle then byHandle[t.handle] = t end
        local okC, sc = pcall(function() return e.StatusContainer end)
        t.container_read = okC and (sc == nil and "nil" or "present") or ("error: " .. tostring(sc))
        t.has_raw_container = try("HasRawComponent", function() return e:HasRawComponent("eoc::status::ContainerComponent") end)
        if okC and sc ~= nil then
            local keys = {}
            local okI, errI = pcall(function()
                for h, id in pairs(sc.Statuses) do keys[#keys + 1] = { instance = hint(h), id = tostring(id) } end
            end)
            if not okI then t.container_error = tostring(errI) end
            table.sort(keys, function(a, b) return (a.instance or 0) < (b.instance or 0) end)
            t.container = keys
        end
        local names = {}
        try("GetAllComponentNames", function()
            for _, n in ipairs(e:GetAllComponentNames()) do
                if tostring(n):lower():find("status", 1, true) then names[#names + 1] = tostring(n) end
            end
        end)
        table.sort(names)
        t.status_component_names = names
    end
    t.owned = {}
end

-- Independent route: every server status entity, grouped by ServerStatus.Entity.
local all = try("GetAllEntitiesWithComponent", Ext.Entity.GetAllEntitiesWithComponent, "ServerStatus") or {}
P.server_status_entities = #all
local unmatched, scanned, LIMIT = 0, 0, 50000
for _, s in ipairs(all) do
    scanned = scanned + 1
    if scanned > LIMIT then P.server_status_scan_cut = true break end
    local okS, row = pcall(function()
        local c = s.ServerStatus
        return { owner = hint(c.Entity), id = tostring(c.StatusId), type = tostring(c.Type), instance = hint(s) }
    end)
    if okS then
        local t = row.owner and byHandle[row.owner]
        if t then
            row.active = try("HasRawComponent", function() return s:HasRawComponent("esv::status::ActiveComponent") end)
            t.owned[#t.owned + 1] = { instance = row.instance, id = row.id, type = row.type, active = row.active }
        else
            unmatched = unmatched + 1
        end
    else
        P.errors[#P.errors + 1] = "ServerStatus read: " .. tostring(row)
    end
end
P.server_status_other_owners = unmatched
local containers = try("GetAllEntitiesWithComponent", Ext.Entity.GetAllEntitiesWithComponent, "StatusContainer")
P.status_container_entities = containers and #containers or nil

-- Osiris view for every id seen on any target plus the prehistory id.
local ids = { TRAVELBLOCK_CANTMOVE = true }
for _, u in ipairs(order) do
    local t = targets[u]
    for _, k in ipairs(t.container or {}) do ids[k.id] = true end
    for _, k in ipairs(t.owned) do ids[k.id] = true end
end
P.osiris_ids = sortedKeys(ids)

-- Verdicts. A control actor has a present container; it validates the ServerStatus.Entity route when its
-- container instances equal its owned status-entity instances.
local function instSet(list)
    local s, n = {}, 0
    for _, k in ipairs(list or {}) do if k.instance then s[k.instance] = true n = n + 1 end end
    return s, n
end
local function sameSet(a, na, b, nb)
    if na ~= nb then return false end
    for k in pairs(a) do if not b[k] then return false end end
    return true
end
local controlsOk, controlsBad = 0, 0
for _, u in ipairs(order) do
    local t = targets[u]
    table.sort(t.owned, function(a, b) return (a.instance or 0) < (b.instance or 0) end)
    t.osiris_active = {}
    for _, id in ipairs(P.osiris_ids) do
        t.osiris_active[id] = try("HasActiveStatus", Osi.HasActiveStatus, u, id)
    end
    local nOsi = 0
    for _, v in pairs(t.osiris_active) do if v == 1 then nOsi = nOsi + 1 end end
    t.osiris_active_count = nOsi
    if t.container then
        local a, na = instSet(t.container)
        local b, nb = instSet(t.owned)
        t.control_match = sameSet(a, na, b, nb)
        if t.control_match then controlsOk = controlsOk + 1 else controlsBad = controlsBad + 1 end
    end
end
P.controls_matching, P.controls_mismatching = controlsOk, controlsBad
local routeValid = controlsOk > 0 and controlsBad == 0 and not P.server_status_scan_cut
P.route_validated = routeValid
for _, u in ipairs(order) do
    local t = targets[u]
    if t.container_read == "nil" then
        if not routeValid then
            t.verdict = "UNRESOLVED_route_not_validated"
        elseif #t.owned == 0 and t.osiris_active_count == 0 then
            t.verdict = "ABSENT_AND_NO_STATUS_ENTITIES"
        else
            t.verdict = "ABSENT_BUT_STATUSES_EXIST"
        end
    elseif t.container then
        t.verdict = t.control_match and "PRESENT_MATCHES_ROUTE" or "PRESENT_MISMATCH"
    else
        t.verdict = "UNREADABLE"
    end
end
P.targets = {}
for _, u in ipairs(order) do P.targets[#P.targets + 1] = targets[u] end

-- Output: one console line per target, then the JSON (saved to a new file unless LV01_PROBE_NO_SAVE).
local json = Ext.Json.Stringify(P, { Beautify = false })
local lines = { string.format("LV01 probe: %d targets, %d server status entities, controls ok=%d bad=%d, route_validated=%s, errors=%d",
    #P.targets, P.server_status_entities or -1, controlsOk, controlsBad, tostring(routeValid), #P.errors) }
for _, t in ipairs(P.targets) do
    lines[#lines + 1] = string.format("  %-6s %-24s container=%s raw=%s owned=%d osiris=%d -> %s", t.role,
        tostring(t.name or t.uuid), tostring(t.container_read), tostring(t.has_raw_container), #t.owned,
        t.osiris_active_count or -1, tostring(t.verdict))
end
if not rawget(_G, "LV01_PROBE_NO_SAVE") then
    local base = "FightRec2Probe/lv01-status-" .. tostring(math.floor(tonumber(P.epoch) or 0))
    local path
    for n = 0, 99 do
        local cand = base .. (n == 0 and "" or ("-" .. n)) .. ".json"
        local okL, existing = pcall(Ext.IO.LoadFile, cand)
        if okL and existing == nil then path = cand break end
    end
    local okW, wrote = false, nil
    if path then okW, wrote = pcall(Ext.IO.SaveFile, path, json) end
    lines[#lines + 1] = "  saved: " .. tostring(path) .. " -> " .. tostring(okW and wrote == true)
end
for _, l in ipairs(lines) do Ext.Utils.Print(l) end
return json
