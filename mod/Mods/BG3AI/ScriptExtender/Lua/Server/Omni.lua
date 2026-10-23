-- Roll log for the fightbot (fightbot/README.md): every attack roll and damage roll in the party's fight, as the
-- engine resolved it. Dev only: not fair-filtered (enemy rolls, unseen attackers), its own buffer, never RPC.push,
-- and no agent tool of the benchmark reads it. Off until omni.rolls_enable.
--
-- Source: the Script Extender's damage events (live 2026-10-22, fightrec/samples/): DealDamage carries Caster,
-- Target and the hit; the hit's ConditionRolls hold the attack roll (Roll.Result.NaturalRoll/Total, Difficulty =
-- the target's AC, advantage) and BeforeDealDamage's hit (no Caster/Target) the damage dice. All three share the
-- hit's SpellCastGuid. A miss or a passed save fires none of them: AttackedBy with 0 damage and RollResult are all
-- the engine gives, so those rows carry no numbers.

BG3AI = BG3AI or {}
local RPC = BG3AI.RPC
local V = BG3AI.Visibility
local O = BG3AI.Omni or {}
BG3AI.Omni = O

O.CAP = 500
O.on = O.on or false
O.seq = O.seq or 0
O.log = O.log or {}
O.open = O.open or {}   -- SpellCastGuid .. target -> the row being filled
O.hooks = O.hooks or {}

local function now() return math.floor(Ext.Utils.MonotonicTime()) end
local function f(obj, k) local ok, v = pcall(function() return obj[k] end) return ok and v or nil end
local function list(x)   -- an engine array (or a Lua table) as a Lua list
    local out = {}
    if x == nil then return out end
    local ok = pcall(function() for _, v in ipairs(x) do out[#out + 1] = v end end)
    if not ok or #out == 0 then pcall(function() for i = 1, #x do out[#out + 1] = x[i] end end) end
    return out
end
local function label(x)
    if x == nil then return nil end
    local l = f(x, "Label")
    if l ~= nil then return tostring(l) end
    local s = tostring(x)
    return s:match("%((.-)%)") or s   -- "ConditionRollType(AttackRoll)" -> "AttackRoll"
end

local function who(x)
    local u = V.uuid(x)
    if not u or u == "00000000-0000-0000-0000-000000000000" then return nil end
    return { uuid = u, name = V.name(u) }
end
local function entityWho(h)
    local ok, u = pcall(function() return h.Uuid.EntityUuid end)
    return ok and who(u) or nil
end

local function inFight(...)
    local ctx = V.context()
    local combats = {}
    for _, p in ipairs(ctx.party) do
        local c = V.osi(Osi.CombatGetGuidFor, p)
        if c then combats[c] = true end
    end
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        local u = type(w) == "table" and w.uuid or nil
        if u and (ctx.is_party[u] or combats[V.osi(Osi.CombatGetGuidFor, u) or false]) then return true end
    end
    return false
end

-- The d20 rolls of a hit: [{type, natural, total, vs, advantage, disadvantage, critical, dice}]
function O.attackRolls(hit)
    local out = {}
    for _, c in ipairs(list(f(hit, "ConditionRolls"))) do
        local roll = f(c, "Roll")
        local res = roll and f(roll, "Result")
        local r = roll and f(roll, "Roll")
        local dice = {}
        for _, d in ipairs(list(res and f(res, "RollsCount"))) do dice[#dice + 1] = f(d, "RollValue") end
        out[#out + 1] = { type = label(f(c, "RollType")), natural = res and f(res, "NaturalRoll"),
            total = res and f(res, "Total"), vs = f(c, "Difficulty"), advantage = r and f(r, "Advantage") or nil,
            disadvantage = r and f(r, "Disadvantage") or nil, critical = res and label(f(res, "Critical")) or nil,
            dice = #dice > 0 and dice or nil }
    end
    return out
end

-- The damage of a hit: {total, by_type = {Slashing = 10}, dice = [{type, die, natural, total}]}
function O.damage(hit)
    local dmg = f(hit, "Damage")
    if not dmg then return nil end
    local out = { total = f(hit, "TotalDamageDone"), by_type = {}, dice = {} }
    pcall(function() for t, n in pairs(f(dmg, "FinalDamagePerType")) do out.by_type[label(t) or tostring(t)] = n end end)
    pcall(function()
        for t, rolls in pairs(f(dmg, "DamageRolls")) do
            for _, dr in ipairs(list(rolls)) do
                local r, res = f(f(dr, "Roll"), "Roll"), f(dr, "Result")
                out.dice[#out.dice + 1] = { type = label(t) or tostring(t),
                    die = r and label(f(r, "DiceValue")), count = r and f(r, "AmountOfDices"),
                    bonus = r and f(r, "DiceAdditionalValue"), natural = res and f(res, "NaturalRoll"),
                    total = res and f(res, "Total") }
            end
        end
    end)
    return out
end

local function push(row)
    O.seq = O.seq + 1
    row.seq, row.t = O.seq, now()
    O.log[#O.log + 1] = row
    if #O.log > O.CAP then table.remove(O.log, 1) end
    return row
end

local function subscribe(name, fn)
    local ok, err = pcall(function()
        Ext.Events[name]:Subscribe(function(e)
            if not O.on then return end
            local ok2, err2 = pcall(fn, e)
            if not ok2 then Ext.Utils.PrintWarning("[BG3AI] omni " .. name .. ": " .. tostring(err2)) end
        end)
    end)
    O.hooks["Ext.Events." .. name] = ok and "ok" or tostring(err)
end

local function listen(name, arity, fn)
    local ok, err = pcall(Ext.Osiris.RegisterListener, name, arity, "after", function(...)
        if not O.on then return end
        local ok2, err2 = pcall(fn, ...)
        if not ok2 then Ext.Utils.PrintWarning("[BG3AI] omni " .. name .. ": " .. tostring(err2)) end
    end)
    O.hooks[name] = ok and "ok" or tostring(err)
end

if not O.registered then
    O.registered = true

    -- DealDamage: who hit whom, with the attack roll. Opens a row the damage event fills.
    subscribe("DealDamage", function(e)
        local hit = f(e, "Hit")
        local caster, target = entityWho(f(e, "Caster")), entityWho(f(e, "Target"))
        if not inFight(caster, target) then return end
        local guid = tostring(f(hit, "SpellCastGuid") or "")
        local row = push({ kind = "hit", attacker = caster, target = target, spell = f(hit, "SpellId"),
            rolls = O.attackRolls(hit) })
        O.open[guid] = row
    end)
    -- BeforeDealDamage: the damage dice of the last DealDamage with the same cast.
    subscribe("BeforeDealDamage", function(e)
        local hit = f(e, "Hit")
        local row = O.open[tostring(f(hit, "SpellCastGuid") or "")]
        if row and not row.damage then row.damage = O.damage(hit) end
    end)
    -- AttackedBy: the amount the target took; 0 with no open hit = a miss or a passed save (no numbers).
    listen("AttackedBy", 7, function(def, owner, att, dtype, amount, cause, _)
        local target, source = who(def), who(owner) or who(att)
        if not inFight(target, source) then return end
        for _, row in pairs(O.open) do
            if row.target and target and row.target.uuid == target.uuid and row.taken == nil then
                row.taken = amount
                return
            end
        end
        if cause == "Attack" and tonumber(amount) == 0 then
            push({ kind = "no_damage", attacker = source, target = target,
                note = "missed or saved: the engine gives no roll for this" })
        end
    end)
    -- RollResult: saves and checks, pass or fail (no numbers).
    listen("RollResult", 6, function(ev, roller, subject, result, active, crit)
        local r, s = who(roller), who(subject)
        if not inFight(r, s) then return end
        -- result as the engine gives it: which value means a pass differs by event (live: a
        -- GAMEPLAY_SpellSavingThrowSave with result 1 came with the save's status applied), so it isn't read here
        push({ kind = "roll_result", event = ev, roller = r, against = s, result = result,
            critical = crit ~= 0 and crit or nil })
    end)
    -- A cast ends: its hits are complete.
    listen("CastedSpell", 5, function(caster)
        local c = who(caster)
        for guid, row in pairs(O.open) do
            if row.attacker and c and row.attacker.uuid == c.uuid then O.open[guid] = nil end
        end
    end)
end

-- omni.rolls_enable {on=true} -> {on, seq, hooks}
RPC.register("omni.rolls_enable", function(args)
    O.on = args.on ~= false
    if not O.on then O.open = {} end
    return { on = O.on, seq = O.seq, hooks = O.hooks }
end)

-- omni.rolls {since=0, limit=50} -> {on, latest, rows}
RPC.register("omni.rolls", function(args)
    local since, limit = tonumber(args.since) or 0, tonumber(args.limit) or 50
    local out = {}
    for _, r in ipairs(O.log) do
        if r.seq > since then out[#out + 1] = r end
    end
    while #out > limit do table.remove(out, 1) end
    return { on = O.on, latest = O.seq, rows = out }
end)

return O
