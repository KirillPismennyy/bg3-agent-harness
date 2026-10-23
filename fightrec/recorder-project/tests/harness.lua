-- Tiny test harness: cases run in order, each in a fresh mock world; failures are kept and reported.
local H = { cases = {}, results = {} }

function H.case(name, fn) H.cases[#H.cases + 1] = { name = name, fn = fn } end

local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
function H.eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. fmt(b) .. ", got " .. fmt(a), 2) end end
function H.ok(v, msg) if not v then error((msg or "expected truthy") , 2) end return v end
function H.no(v, msg) if v then error((msg or "expected falsy") .. ": got " .. fmt(v), 2) end end
function H.ge(a, b, msg) if not (a >= b) then error((msg or "ge") .. ": " .. fmt(a) .. " < " .. fmt(b), 2) end end
function H.le(a, b, msg) if not (a <= b) then error((msg or "le") .. ": " .. fmt(a) .. " > " .. fmt(b), 2) end end

function H.run(filter)
    local pass, fail = 0, 0
    for _, c in ipairs(H.cases) do
        if not filter or c.name:find(filter, 1, true) then
            local t0 = host.hrtime_ns()
            local ok, err = xpcall(c.fn, debug.traceback)
            local ms = (host.hrtime_ns() - t0) / 1e6
            H.results[#H.results + 1] = { name = c.name, ok = ok, err = not ok and tostring(err) or nil, ms = ms }
            if ok then pass = pass + 1 print(string.format("ok   %-70s %7.1f ms", c.name, ms))
            else fail = fail + 1 print(string.format("FAIL %s\n     %s", c.name, tostring(err):gsub("\n", "\n     "))) end
        end
    end
    print(string.format("\n%d passed, %d failed, %d total", pass, fail, pass + fail))
    return fail
end

return H
