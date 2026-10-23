-- Minimal deterministic JSON for the offline harness (stands in for Ext.Json; NOT the extender's encoder).
-- encode: sorted object keys; a table whose keys are exactly 1..n is an array; refuses functions, userdata,
-- engine mock objects (anything with a metatable) and cycles, so a retained engine object fails loudly.
local json = {}

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function str(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if math.type(k) ~= "integer" or k < 1 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function enc(v, out, seen)
    local tv = type(v)
    if tv == "nil" then out[#out + 1] = "null"
    elseif tv == "boolean" then out[#out + 1] = tostring(v)
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json: non-finite number") end
        if math.type(v) == "integer" then out[#out + 1] = tostring(v)
        else out[#out + 1] = string.format("%.17g", v) end
    elseif tv == "string" then out[#out + 1] = str(v)
    elseif tv == "table" then
        if getmetatable(v) ~= nil then error("json: refusing table with metatable (engine object?)") end
        if seen[v] then error("json: cycle") end
        seen[v] = true
        local arr, n = isArray(v)
        if arr and n > 0 then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                enc(v[i], out, seen)
            end
            out[#out + 1] = "]"
        elseif arr then
            out[#out + 1] = "{}"
        else
            local keys = {}
            for k in pairs(v) do
                local tk = type(k)
                if tk ~= "string" and tk ~= "number" then error("json: bad key type " .. tk) end
                keys[#keys + 1] = tostring(k)
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                out[#out + 1] = str(k)
                out[#out + 1] = ":"
                enc(val, out, seen)
            end
            out[#out + 1] = "}"
        end
        seen[v] = nil
    else
        error("json: cannot encode " .. tv)
    end
end

function json.encode(v)
    local out = {}
    enc(v, out, {})
    return table.concat(out)
end

-- decoder
local function skip(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
end
local dec
local function decStr(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then error("json: unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local n = s:sub(j + 1, j + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if map[n] then out[#out + 1] = map[n] j = j + 2
            elseif n == "u" then
                local cp = tonumber(s:sub(j + 2, j + 5), 16)
                out[#out + 1] = utf8.char(cp)
                j = j + 6
            else error("json: bad escape") end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end
dec = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local t = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            local k
            k, i = decStr(s, skip(s, i))
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("json: expected : at " .. i) end
            t[k], i = dec(s, i + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return t, i + 1 end
            if d ~= "," then error("json: expected , at " .. i) end
            i = i + 1
        end
    elseif c == "[" then
        local t = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return t, i + 1 end
        while true do
            t[#t + 1], i = dec(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return t, i + 1 end
            if d ~= "," then error("json: expected , at " .. i) end
            i = i + 1
        end
    elseif c == '"' then return decStr(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return json.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then error("json: unexpected '" .. c .. "' at " .. i) end
        return math.tointeger(tonumber(num)) or tonumber(num), i + #num
    end
end
json.null = setmetatable({}, { __tostring = function() return "null" end })

function json.decode(s)
    local v, i = dec(s, 1)
    i = skip(s, i)
    if i <= #s then error("json: trailing data at " .. i) end
    return v
end

return json
