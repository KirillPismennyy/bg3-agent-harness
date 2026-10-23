-- Control for bench/bench.lua (IR-18): registers the same hooks as the recorders and does nothing, so the
-- harness/mock cost of dispatching the workload can be separated from recorder cost.
local OSIRIS = { { "CombatStarted", 1 }, { "CombatRoundStarted", 2 }, { "CombatEnded", 1 }, { "TurnStarted", 1 },
    { "TurnEnded", 1 }, { "UsingSpellOnTarget", 6 }, { "CastedSpell", 5 }, { "AttackedBy", 7 }, { "RollResult", 6 },
    { "StatusApplied", 4 }, { "StatusRemoved", 4 }, { "HitpointsChanged", 2 }, { "DownedChanged", 2 }, { "Died", 1 },
    { "Equipped", 2 }, { "Unequipped", 2 }, { "UseFinished", 3 } }
if Ext.IsServer() then
    for _, o in ipairs(OSIRIS) do Ext.Osiris.RegisterListener(o[1], o[2], "after", function() end) end
    for _, e in ipairs({ "BeforeDealDamage", "DealDamage", "DealtDamage", "Tick" }) do
        Ext.Events[e]:Subscribe(function() end)
    end
else
    Ext.Events.Tick:Subscribe(function() end)
end
NullRecorder = true
