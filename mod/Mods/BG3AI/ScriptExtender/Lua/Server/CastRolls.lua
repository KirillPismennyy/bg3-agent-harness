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

-- EXPERIMENTAL intervention, not a player-equivalent route. Requires an
-- explicit current prepared source; prototype-only calls use the legacy route
-- only after the read-only source gate qualifies a unique matching ability.
CR.SOURCE_FIELDS = { "Prototype", "OriginatorPrototype", "SourceType", "Source", "ProgressionSource" }
local CAST_ABILITIES = { Strength=true, Dexterity=true, Constitution=true, Intelligence=true, Wisdom=true, Charisma=true }
local function sourceSnapshot(id, cache)
    local out = {}
    for _, k in ipairs(CR.SOURCE_FIELDS) do out[k] = tostring(assert(id[k], "unreadable " .. k)) end
    if cache then out.SpellCastingAbility = tostring(assert(cache.SpellCastingAbility, "missing cast ability")) end
    return out
end
local function sourceEqual(a, b, ability)
    for _, k in ipairs(CR.SOURCE_FIELDS) do if a[k] ~= b[k] then return false end end
    return not ability or a.SpellCastingAbility == b.SpellCastingAbility
end
local function preparedSource(s, G, prepared)
    local prepareType = tostring(assert(s.PrepareType, "source preparation kind unavailable"))
    assert(prepareType == "AlwaysPrepared" or prepareType == "RequiresPreparation",
        "source preparation kind unqualified: " .. prepareType)
    if prepareType == "RequiresPreparation" then assert(prepared, "current preparations unavailable") end
    return not G.unprepared(s, prepared)
end
function CR.check_legacy_source(char, spell)
    local G = assert(BG3AI.Guard, "source inspection unavailable")
    assert(G.prepared_ids and G.unprepared, "source preparation checks unavailable")
    local e = assert(Ext.Entity.Get(char), "source actor missing")
    local spells = assert(e.SpellBook and e.SpellBook.Spells, "spellbook source unavailable")
    local prepared, observed, sawWeapon, matching = G.prepared_ids(e), {}, false, false
    for _, s in ipairs(spells) do
        if tostring(assert(s.Id and s.Id.Prototype, "book prototype unavailable")) == spell then
            matching = true
            local okA, ability = pcall(function() return s.SpellCastingAbility end)
            if okA and ability ~= nil and tostring(ability) == "None" then
                sawWeapon = true -- no casting ability; ordinary weapon route unchanged
            elseif preparedSource(s, G, prepared) then
                assert(okA and ability ~= nil and CAST_ABILITIES[tostring(ability)], "source casting ability unavailable")
                local row = sourceSnapshot(s.Id)
                for _, k in ipairs(CR.SOURCE_FIELDS) do assert(row[k] ~= "", "source identity missing " .. k) end
                row.SpellCastingAbility = tostring(ability)
                local duplicate = false
                for _, prior in ipairs(observed) do
                    if sourceEqual(prior, row) then
                        assert(prior.SpellCastingAbility == row.SpellCastingAbility, "source ability conflicts within book")
                        duplicate = true
                    end
                end
                if not duplicate then observed[#observed + 1] = row end
            end
        end
    end
    assert(matching, "matching spellbook source unavailable")
    if #observed == 0 then
        assert(sawWeapon, "no qualified prepared source")
        return { route = "legacy", ability = "None", equivalence = "unproven" }
    end
    assert(#observed == 1 and not sawWeapon, "explicit source selector required: multiple prepared source identities")
    local default = tostring(assert(e.Stats and e.Stats.SpellCastingAbility, "actor default casting ability unavailable"))
    assert(CAST_ABILITIES[default], "actor default casting ability unavailable")
    assert(observed[1].SpellCastingAbility == default,
        "explicit source selector required: prepared source ability differs from actor default")
    return { route = "legacy", source = observed[1], actor_default_ability = default, equivalence = "unproven" }
end
function CR.validate_source(char, spell, selector)
    assert(CR.available, "cast hook unavailable")
    assert(type(selector) == "table", "source must be an explicit object")
    for _, k in ipairs(CR.SOURCE_FIELDS) do
        assert(type(selector[k]) == "string" and selector[k] ~= "", "source missing " .. k)
    end
    assert(type(selector.SpellCastingAbility) == "string" and CAST_ABILITIES[selector.SpellCastingAbility],
        "source missing or unqualified casting ability")
    assert(selector.Prototype == spell, "source prototype differs from action")
    local G = assert(BG3AI.Guard, "source preparation checks unavailable")
    assert(G.prepared_ids and G.unprepared, "source preparation checks unavailable")
    local e = assert(Ext.Entity.Get(char), "source actor missing")
    local prepared, matches, selected = G.prepared_ids(e), 0, nil
    for _, s in ipairs(assert(e.SpellBook.Spells, "spellbook unavailable")) do
        local observed = sourceSnapshot(s.Id)
        if sourceEqual(observed, selector) then
            assert(preparedSource(s, G, prepared), "source not prepared")
            observed.SpellCastingAbility = tostring(assert(s.SpellCastingAbility, "source ability unreadable"))
            assert(observed.SpellCastingAbility == selector.SpellCastingAbility, "source ability conflicts with spellbook")
            matches, selected = matches + 1, observed
        end
    end
    assert(matches == 1, matches == 0 and "source absent or not prepared" or "source identity ambiguous")
    return selected
end

local function hasLabel(opts, want)
    for _, label in ipairs(CR.labels(opts)) do if label == want then return true end end
    return false
end
local function expectedTarget(state, want)
    if #state.Targets ~= 1 then return false end
    local t = state.Targets[1]
    if t.Target2 ~= nil or t.TargetProxy ~= nil then return false end
    return t.Target and t.Target.Uuid and tostring(t.Target.Uuid.EntityUuid) == want
end
local function writeSource(state, cache, selected)
    for _, k in ipairs(CR.SOURCE_FIELDS) do
        if tostring(state.SpellId[k]) ~= selected[k] then state.SpellId[k] = selected[k] end
    end
    if tostring(cache.SpellCastingAbility) ~= selected.SpellCastingAbility then
        cache.SpellCastingAbility = selected.SpellCastingAbility
    end
end
function CR.apply_source(e, state, a)
    local report = a.job.source_route
    local valid, selected = pcall(CR.validate_source, a.caster, a.spell, a.source)
    if not valid then
        report.status, report.error = "source_no_longer_available", tostring(selected)
        return false
    end
    report.cast_guid = state.SpellCastGuid and tostring(state.SpellCastGuid) or nil
    report.phase = tostring(e.ServerSpellCastState.Phase)
    local cache = e.SpellCastCache
    local before = sourceSnapshot(state.SpellId, assert(cache, "cast cache unavailable"))
    report.before = before
    local ok, err = pcall(writeSource, state, cache, a.source)
    local readOk, after = pcall(sourceSnapshot, state.SpellId, cache)
    if readOk then report.after = after end
    if ok and readOk and sourceEqual(after, a.source, true) then
        report.status = "source_written_readback"
        return true
    end
    report.status, report.error = "source_write_failed", tostring(err or "source readback mismatch")
    local rollbackOk = pcall(writeSource, state, cache, before)
    local rollbackRead, rollback = pcall(sourceSnapshot, state.SpellId, cache)
    report.rollback_confirmed = rollbackOk and rollbackRead and sourceEqual(rollback, before, true) or false
    if rollbackRead then report.rollback_after = rollback end
    return false
end

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

function CR.arm(job, char, spell, source, target)
    local u = guid(char)
    if not u then return end
    if source then assert(CR.available, "cast hook unavailable") end
    if not CR.available then
        if job then job.rolls = { fix = "unavailable", why = CR.why } end
        return
    end
    local selected
    if source then
        assert(job, "experimental source requires a tracked job")
        assert(not CR.armed[u], "caster already has an armed order")
        assert(guid(target), "experimental source requires one entity target")
        selected = CR.validate_source(char, spell, source)
        job.source_route = { experimental = true, status = "armed", selected = selected,
            expected_target = guid(target), equivalence = "unproven" }
    end
    CR.armed[u] = { spell = spell, until_ms = now() + CR.ARM_MS, job = job,
        source = selected, target = guid(target), caster = u }
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
    if now() > a.until_ms then
        if a.source and a.job then a.job.source_route.status = "matching_cast_not_seen" end
        if a.job and a.job.rolls then a.job.rolls.fix = "cast_state_not_seen" end
        CR.armed[caster] = nil
        return
    end
    local p, o = spellOf(state)
    if a.spell ~= p and a.spell ~= o then   -- another cast of this caster (a reaction): not the ordered one
        CR.stats.unmatched = CR.stats.unmatched + 1
        return
    end
    if a.source then
        -- All guards run before any mutation. A matching prototype is insufficient.
        local matchOk, match = pcall(function()
            return tostring(state.SpellId.SourceType) == "Osiris"
                and tostring(e.ServerSpellCastState.Phase) == "ValidationStart"
                and hasLabel(state.CastOptions, "IgnoreSpellRolls")
                and not hasLabel(state.CastOptions, "IsPreview")
                and not hasLabel(state.CastOptions, "IsHoverPreview")
                and not hasLabel(state.CastOptions, "FromClient")
                and expectedTarget(state, a.target)
        end)
        if not matchOk or not match then CR.stats.unmatched = CR.stats.unmatched + 1 return end
        CR.armed[caster] = nil
        local applied, result = pcall(CR.apply_source, e, state, a)
        if not applied then
            a.job.source_route.status, a.job.source_route.error = "source_patch_unavailable", tostring(result)
        end
        -- A refused source write cannot undo an already ordered cast. Preserve
        -- the roll-suppression fix, but never represent this trial as qualified.
        if not applied or not result then a.source = nil end
    end
    CR.armed[caster] = nil
    local ok, before, after = CR.strip(state)
    if ok then CR.stats.cleared = CR.stats.cleared + 1 else CR.stats.failed = CR.stats.failed + 1 end
    if a.job then
        a.job.rolls = { fix = ok and "rolls_restored" or "not_cleared", options_before = before, options_after = after }
    end
    if ok then CR.watching[#CR.watching + 1] = { e = e, ticks = 0, job = a.job, source = a.source } end
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
        if okR and state and w.source and w.job and w.job.source_route then
            local okS, observed = pcall(sourceSnapshot, state.SpellId, w.e.SpellCastCache)
            if not okS or not sourceEqual(observed, w.source, true) then
                w.job.source_route.status = "source_changed_after_readback"
            end
        end
    end
    for u, a in pairs(CR.armed) do
        if now() > a.until_ms then
            if a.job and a.job.rolls and a.job.rolls.fix == "pending" then a.job.rolls.fix = "cast_state_not_seen" end
            if a.source and a.job then a.job.source_route.status = "matching_cast_not_seen" end
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
