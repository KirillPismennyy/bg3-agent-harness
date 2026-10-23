-- Rolls for our Osiris casts. Osi.UseSpell / UseSpellAtPosition casts carry IgnoreSpellRolls (live 2026-10-23,
-- bg3se v33: the executed cast's SpellCastState.CastOptions read SpellCastOptions(IgnoreSpellRolls,
-- AvoidDangerousAuras,IgnoreCastChecks,IgnoreTargetChecks,NoMovement,IgnoreHasSpell) from creation to destruction,
-- and the attack dealt damage with no attack roll; fightbot/SAFETY_REVIEW.md). So every attack hit and no save was
-- made: not what a player's cast does (research/03-actions.md had inferred it).
--
-- When Actions orders a cast it arms CR.arm(job, char, spell); when that caster's cast state appears (deferred, so
-- its fields are filled) and names that spell, the options in CR.CLEAR are removed from it, the write is read
-- back, and re-checked for CR.WATCH_TICKS ticks in case the engine sets them again. The job's result says what
-- happened (job.rolls). Only IgnoreSpellRolls is cleared: the guard already does the cast and target checks
-- and charges the costs (G.check_cast, the resource audit); letting the engine check and charge too could refuse
-- or charge twice. Without Ext.Entity.OnCreateDeferred (bg3le) it does nothing and says so.

BG3AI = BG3AI or {}
local CR = BG3AI.CastRolls or {}
BG3AI.CastRolls = CR

CR.CLEAR = { IgnoreSpellRolls = true }
CR.ARM_MS = 8000        -- an order whose cast state hasn't appeared by then is not ours to touch
CR.WATCH_TICKS = 30
CR.armed = CR.armed or {}       -- caster uuid -> {spell, until_ms, job}
CR.watching = CR.watching or {} -- {state entity, ticks, job}
CR.stats = CR.stats or { armed = 0, cleared = 0, failed = 0, reapplied = 0, unmatched = 0 }

local function now() return Ext.Utils.MonotonicTime() end
local function guid(s) return type(s) == "string" and s:match("%x+%-%x+%-%x+%-%x+%-%x+$") or nil end

-- "SpellCastOptions(IgnoreSpellRolls,NoMovement)" -> {"IgnoreSpellRolls", "NoMovement"}
function CR.labels(opts)
    local s = tostring(opts or "")
    local inner = s:match("%((.*)%)")
    local out = {}
    for l in (inner or ""):gmatch("[^,%s]+") do out[#out + 1] = l end
    return out
end

local function hasCleared(opts)
    for _, l in ipairs(CR.labels(opts)) do if CR.CLEAR[l] then return true end end
    return false
end

-- Remove CR.CLEAR from state.CastOptions: as a list of the labels to keep, else through the bitfield's value.
-- Returns ok, before, after (read back).
function CR.strip(state)
    local before = tostring(state.CastOptions)
    if not hasCleared(state.CastOptions) then return true, before, before end
    local keep = {}
    for _, l in ipairs(CR.labels(state.CastOptions)) do if not CR.CLEAR[l] then keep[#keep + 1] = l end end
    local ok = pcall(function() state.CastOptions = keep end)
    if not ok or hasCleared(state.CastOptions) then
        pcall(function()
            local v = state.CastOptions.__Value
            for name in pairs(CR.CLEAR) do
                local bit = Ext.Enums and Ext.Enums.SpellCastOptions and Ext.Enums.SpellCastOptions[name]
                local n = bit and (tonumber(bit) or bit.__Value)
                if n then v = v & ~n end
            end
            state.CastOptions = v
        end)
    end
    local after = tostring(state.CastOptions)
    return not hasCleared(state.CastOptions), before, after
end

function CR.arm(job, char, spell)
    local u = guid(char)
    if not u then return end
    if not CR.available then
        if job then job.rolls = { fix = "unavailable", why = CR.why } end
        return
    end
    CR.armed[u] = { spell = spell, until_ms = now() + CR.ARM_MS, job = job }
    CR.stats.armed = CR.stats.armed + 1
    if job then job.rolls = { fix = "pending" } end
end

local function spellOf(state)
    local p, o
    pcall(function() p = state.SpellId.Prototype end)
    pcall(function() o = state.SpellId.OriginatorPrototype end)
    return p, o
end

function CR.onState(e)
    local state = e.SpellCastState
    if not state then return end
    local caster
    pcall(function() caster = state.Caster.Uuid.EntityUuid end)
    local a = caster and CR.armed[caster]
    if not a then return end
    if now() > a.until_ms then CR.armed[caster] = nil return end
    local p, o = spellOf(state)
    if a.spell ~= p and a.spell ~= o then   -- another cast of this caster (a reaction): not the ordered one
        CR.stats.unmatched = CR.stats.unmatched + 1
        return
    end
    CR.armed[caster] = nil
    local ok, before, after = CR.strip(state)
    if ok then CR.stats.cleared = CR.stats.cleared + 1 else CR.stats.failed = CR.stats.failed + 1 end
    if a.job then
        a.job.rolls = { fix = ok and "rolls_restored" or "not_cleared", options_before = before, options_after = after }
    end
    if ok then CR.watching[#CR.watching + 1] = { e = e, ticks = 0, job = a.job } end
end

-- The engine might set the options again after creation: re-check for a while.
function CR.tick()
    for i = #CR.watching, 1, -1 do
        local w = CR.watching[i]
        w.ticks = w.ticks + 1
        local okR, state = pcall(function() return w.e.SpellCastState end)
        if not okR or not state or w.ticks > CR.WATCH_TICKS then
            table.remove(CR.watching, i)
        elseif hasCleared(state.CastOptions) then
            local ok = CR.strip(state)
            CR.stats.reapplied = CR.stats.reapplied + 1
            if w.job and w.job.rolls then
                w.job.rolls.reapplied = (w.job.rolls.reapplied or 0) + 1
                if not ok then w.job.rolls.fix = "not_cleared" end
            end
        end
    end
    for u, a in pairs(CR.armed) do
        if now() > a.until_ms then
            if a.job and a.job.rolls and a.job.rolls.fix == "pending" then a.job.rolls.fix = "cast_state_not_seen" end
            CR.armed[u] = nil
        end
    end
end

if not CR.subscribed then
    CR.subscribed = true
    local ok, err = pcall(function()
        assert(Ext.Entity.OnCreateDeferred, "Ext.Entity.OnCreateDeferred is missing")
        Ext.Entity.OnCreateDeferred("SpellCastState", function(e)
            local okC, errC = pcall(CR.onState, e)
            if not okC then Ext.Utils.PrintWarning("[BG3AI] cast rolls: " .. tostring(errC)) end
        end)
        Ext.Events.Tick:Subscribe(function() pcall(CR.tick) end)
    end)
    CR.available, CR.why = ok, not ok and tostring(err) or nil
    if not ok then Ext.Utils.PrintWarning("[BG3AI] cast rolls unavailable (Osiris casts skip rolls): " .. tostring(err)) end
end

BG3AI.RPC.register("act.cast_rolls", function() return { available = CR.available, why = CR.why, stats = CR.stats } end)

return CR
