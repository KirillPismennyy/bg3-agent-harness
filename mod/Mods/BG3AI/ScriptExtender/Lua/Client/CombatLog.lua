-- Combat log reader (client context) for tools/record_fight.py. Dev only: no agent tool calls these ops.
-- The log page is Pages/CombatLog.xaml, DataContext gui::DCCombatLog, entries ls.CombatLogEntry
-- (research/05-screen-input.md). The DC's property names are UNVERIFIED in this build: combatlog.probe
-- lists them, and combatlog.read finds the entry collection by shape (the first collection whose items
-- are log entries) unless told which one.
-- Only view models are read with UI.props: never a live element (UI.lua header, S017).

BG3AI = BG3AI or {}
local RPC = BG3AI.RPC
local UI = BG3AI.UI
local CL = BG3AI.CombatLog or {}
BG3AI.CombatLog = CL

CL.DC_TYPE = "gui::DCCombatLog"
CL.WIDGET = "CombatLog"
-- Tried first, in order; then any collection whose first item's type says it is a log entry.
CL.COLLECTIONS = { "CombatLogEntries", "Entries", "LogEntries", "CombatLog", "Items", "Lines", "Messages" }
CL.SKIP = { CurrentPlayer = true, Data = true, Players = true, PlayerList = true }  -- the shared DC base: huge
CL.NODE_BUDGET = 4000
CL.LIST_MAX = 30   -- items dumped per nested collection

local function isNoesis(v)
    return type(v) == "userdata" or (type(v) == "table" and UI.typeName(v) ~= nil)
end

-- As ui.props tells one: only a Collection has Count (GetProperty on a missing name logs an error).
local function isCollection(tn) return tn ~= nil and tn:find("Collection") ~= nil end

-- A view model's own type, never an element's: namespaced (gui::DC*, ls::VM*, ls.CombatLogEntry).
local function isViewModel(tn)
    return tn ~= nil and (tn:find("::", 1, true) or tn:find("^ls%.") or tn:find("^gui%.")) and not tn:find("^Noesis")
end

-- Plain data from a view model, depth-limited. Strings and numbers as they are (markup kept: the recorder
-- strips it), commands by name only, elements by type only.
function CL.dump(obj, depth, budget)
    budget = budget or { n = CL.NODE_BUDGET }
    if not isNoesis(obj) then return obj end
    budget.n = budget.n - 1
    local tn = UI.typeName(obj) or "?"
    if budget.n <= 0 then return { _type = tn, _cut = "budget" } end
    if tn:find("Command") then return { _cmd = tn } end
    if isCollection(tn) then
        local n = UI.count(obj)
        local items = {}
        if depth > 0 then
            for i, it in UI.items(obj, CL.LIST_MAX) do items[i] = CL.dump(it, depth - 1, budget) end
        end
        return { _type = tn, _count = n, _items = items }
    end
    if not isViewModel(tn) then
        local ok, s = pcall(function() return obj:ToString() end)
        return { _type = tn, _text = ok and type(s) == "string" and s ~= "" and s or nil }
    end
    local out = { _type = tn }
    if depth <= 0 then out._cut = "depth" return out end
    for k, v in pairs(UI.props(obj)) do
        if not CL.SKIP[k] then out[k] = CL.dump(v, depth - 1, budget) end
    end
    return out
end

-- The combat log's DataContext: the page under ContentRoot (by DC type or name), else a search for it.
function CL.dc()
    local _, dc = UI.widgetByDC(CL.DC_TYPE)
    if dc then return dc, "widget" end
    dc = UI.dc(CL.WIDGET)
    if dc then return dc, "widget-name" end
    local el = UI.findByDC(UI.contentRoot(), CL.DC_TYPE, { hidden = true, max = 20000 })
    if el then
        local ok, d = pcall(function() return el.DataContext end)
        if ok and d then return d, "tree" end
    end
    return nil
end

local function looksLikeEntry(tn) return tn ~= nil and (tn:find("[Ll]og") or tn:find("[Ee]ntry")) end

-- name, collection: the entry list (args.collection, a known name, or the first collection of log entries).
function CL.entries(dc, want)
    local props = UI.props(dc)
    if want then return want, props[want] end
    if CL.chosen and props[CL.chosen] then return CL.chosen, props[CL.chosen] end
    for _, k in ipairs(CL.COLLECTIONS) do
        local v = props[k]
        if isNoesis(v) and isCollection(UI.typeName(v)) then CL.chosen = k return k, v end
    end
    for k, v in pairs(props) do
        local tn = isNoesis(v) and UI.typeName(v)
        if tn and isCollection(tn) and UI.count(v) > 0 then
            local first = UI.path(v, "1")
            if looksLikeEntry(UI.typeName(first)) then CL.chosen = k return k, v end
        end
    end
    return nil
end

-- combatlog.probe {depth=2}: where the log is and what its DC holds, to name the entry collection.
RPC.register("combatlog.probe", function(args)
    local depth = tonumber(args.depth) or 2
    local widgets = {}
    for _, w in ipairs(UI.widgets()) do
        widgets[#widgets + 1] = { n = w.name, dc = w.dc, vis = UI.isVisible(w.el) or nil }
    end
    local dc, how = CL.dc()
    if not dc then return { found = false, widgets = widgets } end
    local props, collections = {}, {}
    for k, v in pairs(UI.props(dc)) do
        if not CL.SKIP[k] then
            local tn = isNoesis(v) and UI.typeName(v) or nil
            if tn and isCollection(tn) then
                local n = UI.count(v)
                props[k] = tn .. "[" .. n .. "]"
                if n > 0 then
                    collections[k] = { count = n, first = CL.dump(UI.path(v, "1"), depth, nil),
                        last = n > 1 and CL.dump(UI.path(v, tostring(n)), depth, nil) or nil }
                end
            elseif tn then
                props[k] = tn:find("Command") and "command" or tn
            else
                props[k] = v
            end
        end
    end
    local chosen = CL.entries(dc, args.collection)
    return { found = true, how = how, type = UI.typeName(dc), chosen = chosen, props = props,
        collections = collections, widgets = args.widgets and widgets or nil }
end)

-- combatlog.read {first=1, last=count, depth=3, collection?} -> {count, collection, entries:[{i, d}]}
-- Entries are 1-based in the collection's order; the recorder finds the new ones by overlap.
RPC.register("combatlog.read", function(args)
    local dc = CL.dc()
    if not dc then return { found = false } end
    local name, coll = CL.entries(dc, args.collection)
    if not coll then return { found = true, count = 0, error = "no entry collection; see combatlog.probe" } end
    local n = UI.count(coll)
    local first = math.max(1, tonumber(args.first) or 1)
    local last = math.min(n, tonumber(args.last) or n)
    local depth = tonumber(args.depth) or 3
    local budget = { n = CL.NODE_BUDGET }
    local out = {}
    for i = first, last do
        out[#out + 1] = { i = i, d = CL.dump(UI.path(coll, tostring(i)), depth, budget) }
    end
    return { found = true, count = n, collection = name, entries = out, cut = budget.n <= 0 or nil }
end)

return CL
