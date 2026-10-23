-- Test-side reader of v2 parts held in a mock file system (independent of tools/reassemble.py).
local json = require("json")
local R = {}

local function lines(s)
    local out, i = {}, 1
    while true do
        local j = s:find("\n", i, true)
        if not j then
            if i <= #s then out[#out + 1] = { text = s:sub(i), partial = true } end
            break
        end
        out[#out + 1] = { text = s:sub(i, j - 1) }
        i = j + 1
    end
    return out
end

-- prefix: e.g. "FightRec2/<session>-server-fight01"
function R.read(fs, prefix)
    local nums = {}
    for p in pairs(fs) do
        local n = p:sub(1, #prefix) == prefix and p:sub(#prefix + 1):match("^%-p(%d+)%.jsonl$")
        if n then nums[#nums + 1] = tonumber(n) end
    end
    table.sort(nums)
    local res = { parts = {}, records = {}, bySeq = {}, issues = {}, duplicates = 0, final = false }
    for idx, n in ipairs(nums) do
        if n ~= idx then res.issues[#res.issues + 1] = "missing part before " .. n end
        local path = string.format("%s-p%05d.jsonl", prefix, n)
        local part = { n = n, path = path, records = {} }
        for i, ln in ipairs(lines(fs[path])) do
            local ok, v = pcall(json.decode, ln.text)
            if ln.partial then res.issues[#res.issues + 1] = path .. ": partial last line" end
            if not ok then
                res.issues[#res.issues + 1] = path .. ":" .. i .. ": unparsable"
            elseif i == 1 then
                if v.kind ~= "part_header" then res.issues[#res.issues + 1] = path .. ": no header" end
                part.header = v
            elseif v.kind == "part_trailer" then
                part.trailer = v
            else
                part.records[#part.records + 1] = v
                if res.bySeq[v.seq] then
                    res.duplicates = res.duplicates + 1
                else
                    res.bySeq[v.seq] = v
                    res.records[#res.records + 1] = v
                end
            end
        end
        if part.trailer then
            if part.trailer.count ~= #part.records then res.issues[#res.issues + 1] = path .. ": trailer count mismatch" end
            if part.trailer.final then res.final = true res.finalTrailer = part.trailer end
        end
        res.parts[#res.parts + 1] = part
    end
    table.sort(res.records, function(a, b) return a.seq < b.seq end)
    res.maxSeq = 0
    for i, r in ipairs(res.records) do
        if r.seq ~= i then res.issues[#res.issues + 1] = "seq gap/inversion at " .. i .. " (seq " .. r.seq .. ")" break end
        res.maxSeq = r.seq
    end
    return res
end

function R.kinds(res)
    local k = {}
    for _, r in ipairs(res.records) do k[r.kind] = (k[r.kind] or 0) + 1 end
    return k
end

function R.find(res, kind, pred)
    for _, r in ipairs(res.records) do if r.kind == kind and (not pred or pred(r)) then return r end end
end

function R.all(res, kind)
    local out = {}
    for _, r in ipairs(res.records) do if r.kind == kind then out[#out + 1] = r end end
    return out
end

return R
