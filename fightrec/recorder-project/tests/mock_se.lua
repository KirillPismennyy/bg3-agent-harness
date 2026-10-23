-- Deterministic fake Script Extender for offline tests and benchmarks. It mirrors only the declarations pinned in
-- docs/API-PINS.txt (SaveFile/AppendFile -> bool, Subscribe -> id or nil for missing events, GetPosition -> three
-- returns, ...). Passing against it validates the implementation's logic, NOT live SE compatibility.
local json = require("json")

local M = {}

local World = {}
World.__index = World

-- Osiris accepts "Name_<uuid>" and bare "<uuid>" for the same object; the mock resolves both.
local function norm(u)
    return type(u) == "string" and (u:match("%x+%-%x+%-%x+%-%x+%-%x+$") or u) or u
end
M.norm = norm

local function guidFrom(n)
    return string.format("%08x-%04x-%04x-%04x-%012x", n, n % 65536, 0x4000 + n % 4096, 0x8000 + n % 4096, n * 7919)
end
M.guid = guidFrom

-- Engine object: a proxy table that refuses any access once its callback scope has ended (like SE lifetimes).
function World:obj(typeName, fields)
    local w = self
    local rec = { type = typeName, fields = fields or {}, expired = false }
    local p = {}
    setmetatable(p, {
        __index = function(_, k)
            if rec.expired then
                w.violations[#w.violations + 1] = typeName .. "." .. tostring(k)
                error("Attempted to access " .. typeName .. " whose lifetime has expired")
            end
            local v = rec.fields[k]
            -- rec.absent: mapped component names the entity lacks read nil (pinned LuaEntityProxy.inl Index)
            if v == nil and w.strictFields and not rec.lenient and not (rec.absent and rec.absent[k]) then
                error("Property '" .. tostring(k) .. "' does not exist on " .. typeName)
            end
            return v
        end,
        __newindex = function() error("engine object is read-only in this mock") end,
        __pairs = function()
            if rec.expired then
                w.violations[#w.violations + 1] = typeName .. ":pairs"
                error("Attempted to iterate " .. typeName .. " whose lifetime has expired")
            end
            return next, rec.fields, nil
        end,
        __tostring = function() return typeName .. " (mock)" end,
        __name = typeName,
    })
    self.objs[p] = rec
    self.scope[#self.scope + 1] = rec
    return p
end

function World:expireScope()
    for _, rec in ipairs(self.scope) do rec.expired = true end
    self.scope = {}
end

function World:isEngine(v) return self.objs[v] ~= nil end

-- Objects created inside a dispatch expire when it returns; objects the caller built for a top-level dispatch
-- (event payloads) expire with it too. Nested dispatches do not expire their caller's objects.
local function scopeCall(w, fn, ...)
    local saved = w.scope
    w.scope = {}
    w.depth = w.depth + 1
    local r = table.pack(pcall(fn, ...))
    w.depth = w.depth - 1
    w:expireScope()
    w.scope = saved
    if w.depth == 0 then w:expireScope() end
    if not r[1] then w.dispatchErrors[#w.dispatchErrors + 1] = tostring(r[2]) end
    return table.unpack(r, 1, r.n)
end

---------------------------------------------------------------------------------------------------------------
function M.new(opts)
    opts = opts or {}
    local w = setmetatable({
        t = opts.t0 or 100000, server = opts.server ~= false, fs = {}, ioLog = {}, io = { save = 0, append = 0,
            load = 0, bytes = 0, save_bytes = 0, append_bytes = 0 },
        ioHook = nil, fsSize = {}, discardFs = opts.discardFs, noIoLog = opts.noIoLog, listeners = {}, events = {}, nextSub = 1, objs = setmetatable({}, { __mode = "k" }),
        scope = {}, depth = 0, violations = {}, dispatchErrors = {}, prints = {}, warnings = {}, errors = {}, globalWrites = {},
        defers = {}, deferMode = opts.deferMode or "ok", party = {}, combatOf = {}, positions = {}, posMode = "xyz",
        entities = {}, statusTurns = {}, equipment = {}, names = {}, guidN = 0, seVersion = opts.seVersion,
        knownEvents = opts.knownEvents or { Tick = true, BeforeDealDamage = true, DealDamage = true, DealtDamage = true,
            GameStateChanged = true, ExecuteFunctor = true, AfterExecuteFunctor = true },
        osirisMissing = opts.osirisMissing or {}, strictFields = opts.strictFields ~= false, osiCalls = 0,
        noUnregister = opts.noUnregister,
    }, World)
    w:buildEnv(opts)
    return w
end

function World:buildEnv(opts)
    local w = self
    local Ext = {}
    Ext.IsServer = function() return w.server end
    Ext.Utils = {
        Print = function(...) w.prints[#w.prints + 1] = table.concat({ ... }, " ") end,
        PrintWarning = function(...) w.warnings[#w.warnings + 1] = table.concat({ ... }, " ") end,
        PrintError = function(...) w.errors[#w.errors + 1] = table.concat({ ... }, " ") end,
        MonotonicTime = function() return w.t end,
        GameVersion = function() return "v4.76.31.656" end,
        Version = function() return w.seVersion end,
        GenerateGuid = function() w.guidN = w.guidN + 1 return guidFrom(0x5e550000 + w.guidN + (opts.guidSalt or 0)) end,
        -- pinned Utils.inl: HandleToInteger(EntityHandle) -> int64; the mock keeps one stable id per handle
        HandleToInteger = function(h)
            local r = w.objs[h]
            if not r or r.fields.__id == nil then error("HandleToInteger: not an entity handle") end
            return r.fields.__id
        end,
    }
    if opts.noGuid then Ext.Utils.GenerateGuid = nil end
    Ext.Timer = {
        MonotonicTime = function() return w.t end,
        MicrosecTime = function() return w.t * 1000.0 end,
        ClockEpoch = function() return 1792664924 + w.t // 1000 end,
    }
    Ext.Json = {
        Stringify = function(x, o)
            if w.stringifyHook then w.stringifyHook(x) end
            return json.encode(x)
        end,
        Parse = function(s) return json.decode(s) end,
    }
    -- Pinned IO.inl: SaveFile/AppendFile(path, contents) -> bool; LoadFile(path) -> string|nil.
    local function io(op, path, content)
        w.io[op] = w.io[op] + 1
        w.io.bytes = w.io.bytes + #content
        w.io[op .. "_bytes"] = w.io[op .. "_bytes"] + #content
        local action = w.ioHook and w.ioHook(op, path, content, w) or nil
        if not w.noIoLog then
            w.ioLog[#w.ioLog + 1] = { op = op, path = path, bytes = #content, action = action or "ok", t = w.t }
        end
        local function apply(c)
            if w.discardFs then -- benchmarks: keep sizes only, so Lua memory measures the recorder, not the "disk"
                w.fsSize[path] = (op == "append" and (w.fsSize[path] or 0) or 0) + #c
                return
            end
            if op == "append" then w.fs[path] = (w.fs[path] or "") .. c else w.fs[path] = c end
        end
        if action == nil or action == "ok" then apply(content) return true end
        if action == "false" then return false end
        if action == "throw" then error("mock I/O failure for " .. path) end
        if action == "nil" then apply(content) return nil end
        if action == "applied_false" then apply(content) return false end
        if action == "applied_throw" then apply(content) error("mock I/O failure after write " .. path) end
        if action == "partial_false" then apply(content:sub(1, #content // 2)) return false end
        if action == "partial_throw" then apply(content:sub(1, #content // 2)) error("mock partial write " .. path) end
        error("unknown mock io action " .. tostring(action))
    end
    Ext.IO = {
        SaveFile = function(path, content) return io("save", path, content) end,
        AppendFile = function(path, content) return io("append", path, content) end,
        LoadFile = function(path)
            w.io.load = w.io.load + 1
            if w.loadHook then return w.loadHook(path, w) end
            return w.fs[path]
        end,
    }
    if opts.noAppend then Ext.IO.AppendFile = nil end
    Ext.Osiris = {
        RegisterListener = function(name, arity, when, fn)
            if w.osirisMissing[name] then error("Osiris event '" .. name .. "' not found") end
            w.listeners[name] = w.listeners[name] or {}
            table.insert(w.listeners[name], { arity = arity, when = when, fn = fn })
        end,
    }
    if not w.noUnregister then Ext.Osiris.UnregisterListener = function() error("not modelled") end end
    -- Pinned EventManager/SubscribableEvent: unknown events are MissingSubscribableEvent whose Subscribe returns nil.
    Ext.Events = setmetatable({}, { __index = function(_, name)
        if not w.knownEvents[name] then
            return { Subscribe = function() w.errors[#w.errors + 1] = "Attempted to subscribe to nonexistent event: " .. name end,
                Unsubscribe = function() end }
        end
        local ev = w.events[name]
        if not ev then
            ev = { name = name, handlers = {} }
            function ev:Subscribe(fn, o)
                local id = w.nextSub | (0x77 << 32)
                w.nextSub = w.nextSub + 1
                self.handlers[#self.handlers + 1] = { id = id, fn = fn }
                return id
            end
            function ev:Unsubscribe(id)
                for i, h in ipairs(self.handlers) do if h.id == id then table.remove(self.handlers, i) return end end
            end
            w.events[name] = ev
        end
        return ev
    end })
    Ext.Types = {
        Serialize = function(x)
            local rec = w.objs[x]
            if not rec then error("not serializable") end
            if rec.expired then w.violations[#w.violations + 1] = rec.type .. ":Serialize" error("expired") end
            if rec.noSerialize then error("type does not support serialization") end
            local function copy(v)
                local r = w.objs[v]
                if r then
                    local o = {}
                    for k, vv in pairs(r.fields) do o[k] = copy(vv) end
                    return o
                end
                if type(v) == "table" then
                    local o = {}
                    for k, vv in pairs(v) do o[k] = copy(vv) end
                    return o
                end
                return v
            end
            return copy(x)
        end,
        GetObjectType = function(x) local r = w.objs[x] return r and r.type or nil end,
        GetTypeInfo = function() return nil end,
    }
    Ext.Entity = { Get = function(u) return w:entity(u) end }
    Ext.Stats = { Get = function(id) return { DisplayName = "h_" .. tostring(id) } end }
    Ext.Loca = { GetTranslatedString = function(h) return "Loca:" .. tostring(h) end }
    if not w.server then
        Ext.UI = {
            GetRoot = function() return w.uiRoot and w.uiRoot() or nil end,
        }
        if w.deferMode ~= "missing" then
            Ext.UI.Defer = function(fn)
                if w.deferMode == "throw" then error("Defer failed (mock)") end
                w.defers[#w.defers + 1] = fn
            end
        end
    end
    self.Ext = Ext

    local Osi = {}
    local function count() w.osiCalls = w.osiCalls + 1 end
    Osi.GetPosition = function(u)
        count()
        local p = w.positions[u] or w.positions[norm(u)]
        if not p then error("GetPosition: no position for " .. tostring(u)) end
        if w.posMode == "x_only" then return p[1] end
        if w.posMode == "nil_y" then return p[1], nil, p[3] end
        return p[1], p[2], p[3]
    end
    Osi.CombatGetGuidFor = function(u)
        count()
        if w.combatOf[u] then return w.combatOf[u] end
        local n = norm(u)
        for k, c in pairs(w.combatOf) do if norm(k) == n then return c end end
        return nil
    end
    Osi.DB_Players = { Get = function(_, _) count()
        local rows = {}
        for i, u in ipairs(w.party) do rows[i] = { u } end
        return rows
    end }
    Osi.DB_Is_InCombat = { Get = function(_, _, c) count()
        local rows = {}
        local keys = {}
        for u, cc in pairs(w.combatOf) do if cc == c then keys[#keys + 1] = u end end
        table.sort(keys)
        for i, u in ipairs(keys) do rows[i] = { u, c } end
        return rows
    end }
    Osi.GetDisplayName = function(u) count() return "h_name_" .. tostring(u) end
    Osi.ResolveTranslatedString = function(h) count() return (w.names[norm((h:gsub("^h_name_", "")))] or "Name") end
    Osi.IsEnemy = function(a, b) count() return 0 end
    Osi.GetStatusTurns = function(u, s) count() return w.statusTurns[norm(u) .. "|" .. tostring(s)] or 2 end
    Osi.GetEquippedItem = function(u, slot) count() local e = w.equipment[norm(u)] return e and e[slot] or nil end
    Osi.GetRegion = function() count() return "WLD_Main_A" end
    self.Osi = Osi

    local env = { Ext = Ext, Osi = Osi }
    setmetatable(env, {
        __index = _G,
        __newindex = function(t, k, v)
            w.globalWrites[k] = (w.globalWrites[k] or 0) + 1
            rawset(t, k, v)
        end,
    })
    self.env = env
end

-- Characters ---------------------------------------------------------------------------------------------------
function World:addCharacter(u, o)
    o = o or {}
    local pos = o.pos or { 1.5, 2.25, -3.75 }
    self.positions[u], self.positions[norm(u)] = pos, pos
    self.names[norm(u)] = o.name or ("Char " .. u:sub(-4))
    if o.party then self.party[#self.party + 1] = u end
    self.combatOf[u] = o.combat
    self.entities[norm(u)] = { hp = o.hp or 20, max = o.max or 20, temp = 0, statuses = o.statuses == nil and { "BLESS" } or o.statuses,
        resources = o.resources or { { "11111111-0000-0000-0000-000000000001", 1, 1, 1 } } }
end

function World:removeEntity(u) self.entities[norm(u)] = nil end

function World:entity(u)
    local d = self.entities[norm(u)]
    if not d then return nil end
    local w = self
    local statuses = {}
    for i, s in ipairs(d.statuses or {}) do
        local id, inst = s, i
        if type(s) == "table" then id, inst = s[1], s[2] end
        statuses[w:obj("EntityHandle", { __id = inst })] = id
    end
    local res = {}
    for i, r in ipairs(d.resources) do
        res[r[1]] = { w:obj("ActionResourceEntry", { ResourceUUID = r[1], Level = r[2], Amount = r[3], MaxAmount = r[4] }) }
    end
    -- statuses = false: the entity has no StatusContainer component (live finding LV01 shape)
    local container = d.statuses ~= false and w:obj("StatusContainerComponent", { Statuses = statuses }) or nil
    local e = w:obj("Entity", {
        Health = w:obj("HealthComponent", { Hp = d.hp, MaxHp = d.max, TemporaryHp = d.temp, MaxTemporaryHp = 0 }),
        StatusContainer = container,
        ActionResources = w:obj("ActionResourcesComponent", { Resources = res }),
        Resistances = w:obj("ResistancesComponent", { AC = 14 }),
        Uuid = w:obj("UuidComponent", { EntityUuid = u }),
        Data = w:obj("DataComponent", { StatsId = "Stats_" .. u:sub(-4) }),
    })
    if not container then w.objs[e].absent = { StatusContainer = true } end
    return e
end

function World:handle(u)
    return self:obj("Entity", { Uuid = self:obj("UuidComponent", { EntityUuid = u }) })
end

-- Driving --------------------------------------------------------------------------------------------------------
function World:load(path, chunkName)
    local fh = assert(io.open(path, "rb"))
    local src = fh:read("a")
    fh:close()
    local f, err = load(src, "@" .. (chunkName or path), "t", self.env)
    if not f then error(err) end
    return scopeCall(self, f)
end

function World:loadString(src, chunkName)
    local f, err = load(src, "@" .. chunkName, "t", self.env)
    if not f then error(err) end
    return scopeCall(self, f)
end

function World:fire(name, ...)
    for _, l in ipairs(self.listeners[name] or {}) do scopeCall(self, l.fn, ...) end
end

function World:throw(name, fields)
    local ev = self.events[name]
    if not ev then return end
    for _, h in ipairs(ev.handlers) do
        local e = self:obj(name .. "Event", fields)
        scopeCall(self, h.fn, e)
    end
end

function World:advance(ms) self.t = self.t + ms end

function World:tick(ms)
    if ms then self.t = self.t + ms end
    self:throw("Tick", { Time = { DeltaTime = (ms or 0) / 1000 } })
end

function World:runDefers(max)
    local n = 0
    while #self.defers > 0 and (not max or n < max) do
        local fn = table.remove(self.defers, 1)
        scopeCall(self, fn)
        n = n + 1
    end
    return n
end

function World:files(prefix)
    local out = {}
    for p in pairs(self.fs) do if not prefix or p:sub(1, #prefix) == prefix then out[#out + 1] = p end end
    table.sort(out)
    return out
end

function World:dumpTo(dir)
    for p, c in pairs(self.fs) do host.write_file(dir .. "/" .. p, c) end
end

-- Walk everything reachable from root (tables, closures' upvalues) except the mock environment itself and report
-- any live engine object retained there.
function World:retainedEngineObjects(root)
    local seen, found = {}, {}
    local skip = { [self.env] = true, [self.Ext] = true, [self.Osi] = true, [_G] = true, [self] = true }
    local function visit(v, path, depth)
        if depth > 60 then return end
        local tv = type(v)
        if tv ~= "table" and tv ~= "function" then return end
        if seen[v] or skip[v] then return end
        seen[v] = true
        if self.objs[v] then found[#found + 1] = path return end
        if tv == "table" then
            for k, vv in next, v do
                visit(k, path .. ".<key>", depth + 1)
                visit(vv, path .. "." .. tostring(k), depth + 1)
            end
            local mt = getmetatable(v)
            if mt then visit(mt, path .. ".<mt>", depth + 1) end
        else
            local i = 1
            while true do
                local n, uv = debug.getupvalue(v, i)
                if not n then break end
                if n ~= "_ENV" then visit(uv, path .. "^" .. n, depth + 1) end
                i = i + 1
            end
        end
    end
    visit(root, "root", 0)
    return found
end

-- UI tree ---------------------------------------------------------------------------------------------------------
-- spec.entries: list of { ts=, text= } ; rebuilt each GetRoot (Noesis objects live only for one deferred callback)
function World:setCombatLog(spec)
    local w = self
    self.uiSpec = spec
    self.uiRoot = function()
        local s = w.uiSpec
        local groups = {}
        for i, e in ipairs(s.entries) do
          if e.build then -- custom nested group (e.g. the live LV02 hit entry shape)
            groups[i] = e.build(w)
          else
            local entryVM = w:obj("gui::CombatLogEntryVM", { Type = "gui::CombatLogEntryVM", Timestamp = e.ts })
            rawget(w.objs[entryVM], "fields").GetAllProperties = function() return { Timestamp = e.ts } end
            local entries = w:obj("Noesis::ObservableCollection", { Type = "Noesis::ObservableCollection", Count = 1 })
            local erec = w.objs[entries]
            erec.fields.At = function(_, j) return j == 0 and entryVM or nil end
            erec.fields.GetProperty = function(_, k) return k == "Count" and 1 or nil end
            local text = w:obj("gui::TextVM", { Type = "gui::TextVM", Text = e.text })
            w.objs[text].fields.GetAllProperties = function() return { Text = e.text } end
            local g = w:obj("gui::CombatLogGroupVM", { Type = "gui::CombatLogGroupVM", Entries = entries, CtxTransText = text })
            w.objs[g].fields.GetAllProperties = function() return { Entries = entries, CtxTransText = text } end
            groups[i] = g
          end
        end
        local coll = w:obj("Noesis::ObservableCollection", { Type = "Noesis::ObservableCollection", Count = #groups })
        local crec = w.objs[coll]
        crec.fields.At = function(_, j) return groups[j + 1] end
        crec.fields.GetProperty = function(_, k) return k == "Count" and #groups or nil end
        local cl = w:obj("gui::CombatLogData", { Type = "gui::CombatLogData", EntryGroups = coll })
        local data = w:obj("gui::DataVM", { Type = "gui::DataVM", CombatLog = cl })
        local dc = w:obj("gui::DCCombatLog", { Type = "gui::DCCombatLog", Data = data })
        w.objs[dc].fields.GetAllProperties = function() return {} end
        local panel = w:obj("Noesis::Grid", { Type = "Noesis::Grid", Name = "CombatLog", DataContext = dc, VisualChildrenCount = 0 })
        local filler = {}
        for i = 1, (s.filler or 0) do
            filler[i] = w:obj("Noesis::Border", { Type = "Noesis::Border", VisualChildrenCount = 0 })
            w.objs[filler[i]].lenient = true
        end
        local kids = {}
        for i = 1, #filler do kids[#kids + 1] = filler[i] end
        kids[#kids + 1] = panel
        local root = w:obj("Noesis::Grid", { Type = "Noesis::Grid", VisualChildrenCount = #kids })
        w.objs[root].fields.VisualChild = function(_, i) return kids[i + 1] end
        for _, o in ipairs({ panel, root, coll, cl, data, dc, entries }) do w.objs[o].lenient = true end
        w.objs[root].lenient = true
        for _, gg in ipairs(groups) do w.objs[gg].lenient = true end
        return root
    end
end

return M
