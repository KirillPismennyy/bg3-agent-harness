-- LV01 read-only status probe, VERSION 2 (server context). Author: Claude Opus 5.5 (claude-opus-5-5), 2026-10-23.
-- v1 (lv01_status_probe.lua, retained) grouped server status entities by ServerStatus.Entity; live run
-- lv01-status-1792760275.json: 3227 status entities, none grouped to any actor, 0/4 controls matched: that route
-- is NOT the status bearer (or not readable). v1 also counted unreadable/missing handles silently as "unmatched".
-- v2: candidate route ServerStatusOwnership.Owner (pinned Components/Status.h esv::status::OwnershipComponent
-- {EntityHandle Owner}); the header does not name Owner's role, so it is only accepted when ALL controls (actors
-- whose StatusContainer is present) satisfy: every container key is a scanned status entity, and the set of status
-- entities whose Owner is that actor equals the container key set. Success additionally requires zero read
-- errors, a complete scan, and no status entity with a missing instance handle, missing Ownership component or
-- unreadable Owner. ServerStatus.Entity is still recorded per control key (diagnostic only, never a verdict).
-- Reads only: no Osiris calls with effects, no component writes, no recorder access, no globals. The only write is
-- one NEW JSON file FightRec2Probe/lv01-status-v2-<epoch>[-n].json (probed with LoadFile first; never overwritten).
-- Optional: set a global LV01_PROBE_NO_SAVE = true before running to skip the file and only print.
local P = { probe = "lv01-status", probe_version = 2, route = "ServerStatusOwnership.Owner", errors = {},
    error_count = 0 }
local function err(msg)
    P.error_count = P.error_count + 1
    if #P.errors < 50 then P.errors[#P.errors + 1] = msg end
end
local function try(label, f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    err(label .. ": " .. tostring(v))
    return nil
end
local function guid(x)
    return type(x) == "string" and (x:match("%x+%-%x+%-%x+%-%x+%-%x+$") or x) or nil
end
local function hint(h)
    if h == nil then return nil end
    local ok, v = pcall(Ext.Utils.HandleToInteger, h)
    return ok and math.type(v) == "integer" and v or nil
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
        err("target " .. u .. ": entity unavailable")
    else
        t.handle = hint(e)
        if t.handle then byHandle[t.handle] = t else err("target " .. u .. ": no entity handle") end
        local okC, sc = pcall(function() return e.StatusContainer end)
        t.container_read = okC and (sc == nil and "nil" or "present") or ("error: " .. tostring(sc))
        if not okC then err("target " .. u .. ": StatusContainer read: " .. tostring(sc)) end
        t.has_raw_container = try("HasRawComponent", function() return e:HasRawComponent("eoc::status::ContainerComponent") end)
        if okC and sc ~= nil then
            local keys = {}
            local okI, errI = pcall(function()
                for h, id in pairs(sc.Statuses) do keys[#keys + 1] = { instance = hint(h), id = tostring(id) } end
            end)
            if not okI then
                t.container_error = tostring(errI)
                err("target " .. u .. ": container iteration: " .. tostring(errI))
            end
            for _, k in ipairs(keys) do
                if not k.instance then err("target " .. u .. ": container key without instance handle") end
            end
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

-- Independent enumeration of every server status entity: instance, StatusId, Ownership.Owner, ServerStatus.Entity.
local all = try("GetAllEntitiesWithComponent", Ext.Entity.GetAllEntitiesWithComponent, "ServerStatus")
local S = { enumerated = all ~= nil, total = all and #all or 0, scanned = 0, read_errors = 0,
    missing_instance = 0, ownership_absent = 0, owner_unreadable = 0, owner_is_target = 0, owner_other = 0,
    entity_unreadable = 0, entity_eq_owner = 0, entity_eq_self = 0 }
P.scan = S
if not all then err("ServerStatus enumeration failed") end
local LIMIT = 50000
local byInst = {}
for _, s in ipairs(all or {}) do
    if S.scanned >= LIMIT then S.cut = true break end
    S.scanned = S.scanned + 1
    local inst = hint(s)
    local okS, row = pcall(function()
        local c = s.ServerStatus
        return { id = tostring(c.StatusId), type = tostring(c.Type), entity = hint(c.Entity) }
    end)
    if not okS then
        S.read_errors = S.read_errors + 1
        err("ServerStatus read: " .. tostring(row))
    elseif not inst then
        S.missing_instance = S.missing_instance + 1
        err("status entity without instance handle (id " .. row.id .. ")")
    else
        row.instance = inst
        local okO, o = pcall(function() return s.ServerStatusOwnership end)
        if not okO then
            S.read_errors = S.read_errors + 1
            err("ServerStatusOwnership read " .. inst .. ": " .. tostring(o))
        elseif o == nil then
            S.ownership_absent = S.ownership_absent + 1
            err("status entity " .. inst .. " (" .. row.id .. ") has no ServerStatusOwnership")
        else
            local okH, oh = pcall(function() return o.Owner end)
            row.owner = okH and hint(oh) or nil
            if not row.owner then
                S.owner_unreadable = S.owner_unreadable + 1
                err("status entity " .. inst .. " (" .. row.id .. "): Owner unreadable")
            end
        end
        if row.entity == nil then S.entity_unreadable = S.entity_unreadable + 1 end
        if row.entity ~= nil and row.entity == row.owner then S.entity_eq_owner = S.entity_eq_owner + 1 end
        if row.entity ~= nil and row.entity == inst then S.entity_eq_self = S.entity_eq_self + 1 end
        byInst[inst] = row
        if row.owner then
            local t = byHandle[row.owner]
            if t then
                S.owner_is_target = S.owner_is_target + 1
                row.active = try("HasRawComponent", function() return s:HasRawComponent("esv::status::ActiveComponent") end)
                t.owned[#t.owned + 1] = { instance = inst, id = row.id, type = row.type, active = row.active }
            else
                S.owner_other = S.owner_other + 1
            end
        end
    end
end
if all and S.scanned ~= S.total then S.cut = true end
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

-- Controls: every container key must be a scanned status entity owned (Owner) by that actor, and the owned set
-- must equal the key set. key_rows keeps both candidate fields for each key (explains v1's failure).
local controls, controlsOk, controlsBad = 0, 0, 0
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
        controls = controls + 1
        local keySet, nKeys, inScan, ownerOk = {}, 0, 0, 0
        t.key_rows = {}
        for _, k in ipairs(t.container) do
            if k.instance then
                keySet[k.instance] = true
                nKeys = nKeys + 1
                local row = byInst[k.instance]
                if row then
                    inScan = inScan + 1
                    if row.owner == t.handle then ownerOk = ownerOk + 1 end
                end
                t.key_rows[#t.key_rows + 1] = { instance = k.instance, id = k.id, in_scan = row ~= nil,
                    scan_id = row and row.id or nil, owner = row and row.owner or nil, entity = row and row.entity or nil }
            end
        end
        local ownedOnlyKeys = true
        for _, o in ipairs(t.owned) do if not keySet[o.instance] then ownedOnlyKeys = false end end
        t.control_keys, t.control_keys_in_scan, t.control_keys_owner_ok = nKeys, inScan, ownerOk
        t.control_match = nKeys == #t.container and nKeys > 0 and inScan == nKeys and ownerOk == nKeys
            and #t.owned == nKeys and ownedOnlyKeys
        if t.control_match then controlsOk = controlsOk + 1 else controlsBad = controlsBad + 1 end
    end
end
P.controls, P.controls_matching, P.controls_mismatching = controls, controlsOk, controlsBad
local gates = {
    no_errors = P.error_count == 0,
    scan_complete = S.enumerated and not S.cut and S.total > 0,
    no_missing_handles = S.missing_instance == 0 and S.owner_unreadable == 0 and S.ownership_absent == 0
        and S.read_errors == 0,
    controls_present = controls > 0,
    all_controls_match = controls > 0 and controlsBad == 0,
}
P.gates = gates
local routeValid = true
for _, v in pairs(gates) do if not v then routeValid = false end end
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
local failed = {}
for _, k in ipairs(sortedKeys(gates)) do if not gates[k] then failed[#failed + 1] = k end end
local lines = { string.format("LV01 probe v2: %d targets, status entities %d/%d scanned, owner->target %d, controls ok=%d bad=%d, route_validated=%s, errors=%d%s",
    #P.targets, S.scanned, S.total, S.owner_is_target, controlsOk, controlsBad, tostring(routeValid), P.error_count,
    #failed > 0 and (" failed_gates=" .. table.concat(failed, ",")) or "") }
for _, t in ipairs(P.targets) do
    lines[#lines + 1] = string.format("  %-6s %-24s container=%s raw=%s owned=%d osiris=%d -> %s", t.role,
        tostring(t.name or t.uuid), tostring(t.container_read), tostring(t.has_raw_container), #t.owned,
        t.osiris_active_count or -1, tostring(t.verdict))
end
if not rawget(_G, "LV01_PROBE_NO_SAVE") then
    local base = "FightRec2Probe/lv01-status-v2-" .. tostring(math.floor(tonumber(P.epoch) or 0))
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
