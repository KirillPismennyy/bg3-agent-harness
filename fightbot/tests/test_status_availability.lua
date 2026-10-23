-- Executes the actual pure status projection from State.lua; no engine/runtime.
local file = assert(io.open(arg[1], "r"))
local source = file:read("*a"); file:close()
local first = assert(source:find("function S.statusesView(e)", 1, true))
local last = assert(source:find("local function concentration(e)", first, true))
local S = {}
local V = { statusCache = {} }
local env = setmetatable({ S = S, V = V, comp = function(e, key) return e[key] end,
    U = { loca = function(name) return name end },
    Ext = { Stats = { Get = function(id)
        if id == "FAIL" then error("native Stats read failed") end
        return { DisplayName = id, StatusPropertyFlags = id == "HIDDEN" and { "DisablePortraitIndicator" } or {} }
    end } },
}, { __index = _G })
-- Run the real statusInfo implementation, including swallowed failure/cache paths.
file = assert(io.open(arg[2], "r")); local visibility = file:read("*a"); file:close()
local si = assert(visibility:find("function V.statusInfo(id)", 1, true))
local se = assert(visibility:find("-- Item effect states", si, true))
assert(load(visibility:sub(si, se - 1), "actual statusInfo", "t", env))()
assert(load(source:sub(first, last - 1), "actual statusesView", "t", env))()
local tests = 0
local function check(value) tests = tests + 1; assert(value, "failed assertion " .. tests) end
local rows, meta = S.statusesView({})
check(#rows == 0 and meta.available == false and meta.reason == "component_absent_or_unavailable")
check(meta.source == "StatusContainer.Statuses" and meta.scope == "visible")
rows, meta = S.statusesView({ StatusContainer = { Statuses = {} } })
check(#rows == 0 and meta.available == true and meta.raw_enumeration_available and meta.reason == nil)
rows, meta = S.statusesView({ StatusContainer = {} })
check(#rows == 0 and meta.available == false and meta.reason == "enumeration_failed")
rows, meta = S.statusesView({ StatusContainer = { Statuses = setmetatable({}, {
    __pairs = function() error("native collection unreadable") end }) } })
check(#rows == 0 and meta.available == false)
local handle = { StatusLifetime = { Lifetime = 7 } }
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [handle] = "SLEEP", [{}] = "HIDDEN" } } })
check(#rows == 1 and rows[1].id == "SLEEP" and rows[1].turns == 2 and not meta.available)
check(meta.reason == "status_projection_unavailable" and meta.raw_enumeration_available)
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [{}] = "HIDDEN" } } })
check(#rows == 0 and not meta.available and meta.scope == "visible")
check(meta.reason == "status_projection_unavailable")
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [{}] = "FAIL" } } })
check(#rows == 0 and not meta.available and meta.reason == "status_projection_unavailable")
check(V.statusCache.FAIL == false and meta.raw_enumeration_available)
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [{}] = "FAIL" } } })
check(not meta.available and meta.reason == "status_projection_unavailable")
V.OMNISCIENT = true
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [{}] = "HIDDEN" } } })
check(#rows == 1 and rows[1].hidden == true and meta.available and meta.scope == "omniscient")
check(rows[1].name == "HIDDEN" and meta.raw_enumeration_available)
V.statusInfo = function() error("lookup failed") end
rows, meta = S.statusesView({ StatusContainer = { Statuses = { [handle] = "SLEEP" } } })
check(#rows == 0 and not meta.available and meta.reason == "enumeration_failed")
print(tests .. " status availability assertions passed")
