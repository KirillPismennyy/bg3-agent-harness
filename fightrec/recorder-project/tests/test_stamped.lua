-- A stamped build (tools/stamp_build.py) reports its claimed source content hash in meta and part headers;
-- re-executing the same stamped file is idempotent; the unstamped source has a different identity and is refused.
local mock = require("mock_se")
local R = require("partreader")
local path = arg[1]
local w = mock.new()
local u = "S_Player_1_" .. mock.guid(1001)
w:addCharacter(u, { party = true })
assert(w:load(path, "FightRec.lua (stamped)"))
local rt = rawget(w.env, "FightRecV2")
assert(rt.source_content_sha256:match("^%x+$") and #rt.source_content_sha256 == 64,
    "stamped hash reported: " .. tostring(rt.source_content_sha256))
assert(rt.source_identity.status == "claimed_by_build_stamp_unverified_at_runtime", rt.source_identity.status)
local s = R.read(w.fs, "FightRec2/" .. rt.session_id .. "-server-session")
assert(s.parts[1].header.source_content_sha256 == rt.source_content_sha256, "part header carries source identity")
assert(R.find(s, "meta").data.source_content_sha256 == rt.source_content_sha256)
local n = #w.listeners.TurnStarted
assert(w:load(path, "FightRec.lua (stamped, again)"))
assert(rawget(w.env, "FightRecV2Refusal") == nil, "same claimed build re-executed: not a refusal")
assert(#w.listeners.TurnStarted == n, "no duplicate registration")
rt.pumpAll(true)
assert(R.find(R.read(w.fs, "FightRec2/" .. rt.session_id .. "-server-session"), "reexecuted_same_generation"))
assert(w:load(host.repo .. "/recorder/FightRec.lua", "recorder/FightRec.lua"))
assert(rawget(w.env, "FightRecV2") == rt, "unstamped load did not replace the stamped generation")
assert(rawget(w.env, "FightRecV2Refusal"), "replacement refused")
print("ok   stamped artifact claims content sha256 " .. rt.source_content_sha256 ..
    "; same-build re-execution idempotent; unstamped replacement refused")
return 0
