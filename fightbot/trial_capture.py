"""Bound one cast to before/after observations using an existing debugger owner."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import time
import uuid


def _write(path, value):
    data = json.dumps(value, indent=2, sort_keys=True, default=str).encode("utf-8")
    with path.open("xb") as stream:
        stream.write(data)
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def _lua_string(value):
    eq = "="
    while "]" + eq + "]" in value:
        eq += "="
    return "[" + eq + "[" + value + "]" + eq + "]"


def snapshot_code(actor, target, spell):
    params = _lua_string(json.dumps(dict(actor=actor, target=target, spell=spell)))
    return '''-- trial-capture:snapshot
local q=Ext.Json.Parse(PARAMS)
local started_ms=Ext.Utils.MonotonicTime()
local function read(fn)
 local ok,value=pcall(fn)
 return {ok=ok,result=ok and value or nil,error=not ok and tostring(value) or nil}
end
local function rpc(op,args) return read(function()
 local r=Ext.Json.Parse(BG3AI.rpc(Ext.Json.Stringify({op=op,args=args or {}})))
 assert(r.ok,r.error or "RPC failed");return r.result
end) end
local function exact(u,book)
 local e=assert(Ext.Entity.Get(u),"entity unavailable")
 local p=e.Transform.Transform.Translate
 for i=1,3 do assert(type(p[i])=="number","native position unavailable") end
 assert(type(e.Health.Hp)=="number","native HP unavailable")
 local out={uuid=u,pos={p[1],p[2],p[3]},vertical_y=p[2],hp=e.Health.Hp,max_hp=e.Health.MaxHp,temp_hp=e.Health.TemporaryHp}
 if book then
  out.actor_default_ability=tostring(e.Stats.SpellCastingAbility)
  out.raw_resource_amounts=read(function()return BG3AI.Guard.resources(u)end)
  local okPb,pb=pcall(function()return e.Stats.ProficiencyBonus end)
  out.proficiency_bonus_read={ok=okPb and type(pb)=="number",result=okPb and pb or nil,
   error=(not okPb or type(pb)~="number") and tostring(pb or "proficiency unavailable") or nil}
  if okPb and type(pb)=="number" then out.proficiency_bonus=pb end
  out.sources={}
  for _,s in ipairs(e.SpellBook.Spells) do if tostring(s.Id.Prototype)==q.spell then
   local row={SpellCastingAbility=tostring(s.SpellCastingAbility),PrepareType=tostring(s.PrepareType)}
   for _,k in ipairs({"Prototype","OriginatorPrototype","SourceType","Source","ProgressionSource"}) do
    row[k]=s.Id[k]~=nil and tostring(s.Id[k]) or nil
   end
   out.sources[#out.sources+1]=row
  end end
 end
 return out
end
local out={identity=rpc("fightbot.identity"),combat=rpc("state.combat"),
 actor=rpc("state.character",{uuid=q.actor,sections={"abilities","resources","conditions","equipment"}}),
 target=rpc("state.entity",{uuid=q.target}),actions=rpc("state.actions",{uuid=q.actor}),
 native_actor=read(function()return exact(q.actor,true)end),native_target=read(function()return exact(q.target,false)end),
 recorder_hash=FightRecV2 and FightRecV2.source_content_sha256 or nil}
out.started_ms=started_ms;out.finished_ms=Ext.Utils.MonotonicTime()
return Ext.Json.Stringify(out)'''.replace("PARAMS", params)


def _binding(status):
    return {k: status.get(k) for k in ("server_session", "client_session", "combat_id",
        "server_recorder_hash", "client_recorder_hash", "expected_recorder_hash")}


def _snapshot(owner, actor, target, spell, status):
    value = None
    try:
        value = owner.evaluate(snapshot_code(actor, target, spell), context="server", statement=True)
        raw = json.loads(value)
        if not isinstance(raw, dict):
            raise ValueError("snapshot reply is not an object")
    except Exception as exc:
        return {"recording": {}, "owner_binding": _binding(status), "required_reads_ok": False,
            "snapshot_reads": {"error": str(exc), "error_type": type(exc).__name__, "raw_reply": value}}
    def result(key):
        row = raw.get(key) or {}
        return row.get("result") if row.get("ok") else None
    actor_row, target_row = result("actor"), result("target")
    combat = result("combat") or {}
    required = ("identity", "combat", "actor", "target", "actions", "native_actor", "native_target")
    return {"recording": result("identity") or {}, "owner_binding": _binding(status),
        "client_session": status.get("client_session"), "round": combat.get("round"),
        "party": [{**actor_row, "uuid": actor}] if isinstance(actor_row, dict) else [],
        "turn_order": [{**target_row, "uuid": target}] if isinstance(target_row, dict) else [],
        "native": {"actor": result("native_actor"), "target": result("native_target"),
                   "recorder_hash": raw.get("recorder_hash")},
        "snapshot_reads": raw, "required_reads_ok": all((raw.get(k) or {}).get("ok") is True for k in required),
        "started_ms": raw.get("started_ms"), "finished_ms": raw.get("finished_ms"),
        "scope": "one server callback; actor and target only; not a complete simulator scene"}


def _snapshot_bound(snapshot, binding):
    identity = snapshot.get("recording") or {}
    return (snapshot.get("required_reads_ok") is True
        and identity.get("session_id") == binding.get("server_session")
        and identity.get("combat_id") == binding.get("combat_id")
        and identity.get("file_prefix") and identity.get("recorder_active")
        and identity.get("combat_id") in (identity.get("party_combats") or [])
        and snapshot.get("native", {}).get("recorder_hash") == binding.get("server_recorder_hash"))


def _arm_probe(owner, relative_dir):
    code = '''-- trial-capture:arm-probe
assert(not(MissRollProbe and MissRollProbe.active),"existing numerical probe active")
MissRollProbeConfig={dir=DIR,max_records=32,max_callbacks=96,max_ticks=3600}
assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("FightBotProbe/miss_roll_probe.lua"))))()
assert(MissRollProbe and MissRollProbe.active,"numerical probe not active")
assert(#MissRollProbe.registrations==5,"numerical probe registration count differs")
for _,r in ipairs(MissRollProbe.registrations) do assert(r.ok,"numerical probe hook unavailable") end
return Ext.Json.Stringify({probe_relative_dir=MissRollProbe.dir,registrations=MissRollProbe.registrations,
 numerical_capture_proven=false})'''.replace("DIR", _lua_string(relative_dir))
    return json.loads(owner.evaluate(code, context="server", statement=True))


def _stop_probe(owner, relative_dir):
    code = '''-- trial-capture:stop-probe
assert(MissRollProbe and MissRollProbe.dir==DIR,"numerical probe ownership changed")
MissRollProbe.stop("trial_capture_complete")
return Ext.Json.Stringify({active=MissRollProbe.active,dir=MissRollProbe.dir,records=#MissRollProbe.records,
callbacks=MissRollProbe.callbacks,numerical_capture_proven=false})'''.replace("DIR", _lua_string(relative_dir))
    return json.loads(owner.evaluate(code, context="server", statement=True))


def capture_trial(owner, bot, *, actor, target, spell, ready_token, destination, recorder_dir,
                  source=None, numerical_probe=False, freeze_fn=None, flush_timeout_s=2.0,
                  script_extender_dir=None, sleep=time.sleep, monotonic=time.monotonic):
    """Issue at most one cast; preserve every refusal/error. Never opens a socket."""
    root = Path(destination)
    root.mkdir(parents=True, exist_ok=True)
    trial = root / (time.strftime("trial-%Y%m%dT%H%M%S-") + uuid.uuid4().hex)
    trial.mkdir(exist_ok=False)
    files, errors = {}, []
    report = {"schema": 1, "trial_dir": str(trial.resolve()), "action_attempts": 0,
        "qualifications": {"before_bound": False, "post_bound": False, "generation_unchanged": False,
                           "action_done": False, "simulator_scene_complete": False},
        "errors": errors, "files": files}
    before, after, action = {}, {}, {"status": "not_issued"}
    probe = None
    probe_requested_dir = None
    state = {}
    flush_window = 0.0
    evidence_dirs = []
    try:
        flush_candidate = float(flush_timeout_s)
        if not math.isfinite(flush_candidate) or flush_candidate < 0:
            raise ValueError("flush timeout must be a finite nonnegative number")
        flush_window = min(flush_candidate, 5)
        recorder_dir = Path(recorder_dir).resolve()
        se_dir = Path(script_extender_dir).resolve() if script_extender_dir else (
            recorder_dir.parent if recorder_dir.name == "FightRec2" else None)
        if numerical_probe and se_dir is None:
            raise ValueError("explicit Script Extender directory required for probe paths")
        state = owner.poll()
        binding = _binding(state)
        files["intent"] = _write(trial / "intent.json", {"actor": actor, "target": target, "spell": spell,
            "source": source, "binding": binding, "numerical_probe": numerical_probe})
        if not state.get("ready") or ready_token != state.get("ready_token"):
            raise ValueError("fresh READY token required; no action issued")
        actor_uuid, target_uuid = bot.resolve(actor), bot.resolve(target)
        lifecycle = (state.get("probe") or {}).get("dir")
        if lifecycle and se_dir:
            path = (se_dir / lifecycle).resolve()
            if not path.is_relative_to(se_dir):
                raise ValueError("lifecycle probe directory escapes Script Extender root")
            evidence_dirs.append(path)
        if numerical_probe:
            probe_requested_dir = "FightBotProbe/trial-" + trial.name + "/"
            probe = _arm_probe(owner, probe_requested_dir)
            if probe.get("probe_relative_dir") != probe_requested_dir:
                raise ValueError("numerical probe directory does not match trial")
            evidence_dirs.append(se_dir / probe_requested_dir)
            files["probe_arm"] = _write(trial / "probe-arm.json", probe)
        before = _snapshot(owner, actor_uuid, target_uuid, spell, state)
        files["before"] = _write(trial / "before.json", before)
        report["qualifications"]["before_bound"] = bool(_snapshot_bound(before, binding))
        if not report["qualifications"]["before_bound"]:
            raise ValueError("essential before snapshot unavailable or identity changed; no action issued")
        def one_action():
            report["action_attempts"] += 1
            return bot.cast(char=actor_uuid, spell=spell, target=target_uuid, source=source)
        try:
            action = owner.run_action(ready_token, one_action)
        except Exception as exc:
            action = {"status": "unknown" if report["action_attempts"] else "not_issued",
                      "error": str(exc), "error_type": type(exc).__name__}
        files["action"] = _write(trial / "action.json", action)
        report["qualifications"]["action_done"] = action.get("status") == "done"
        post_status = owner.poll()
        report["qualifications"]["generation_unchanged"] = _binding(post_status) == binding
        after = _snapshot(owner, actor_uuid, target_uuid, spell, post_status)
        files["after"] = _write(trial / "after.json", after)
        report["qualifications"]["post_bound"] = bool(_snapshot_bound(after, binding))
        final_status = owner.poll()
        files["post_readiness"] = _write(trial / "post-readiness.json", final_status)
        report["qualifications"]["generation_unchanged"] = (
            report["qualifications"]["generation_unchanged"] and _binding(final_status) == binding)
    except Exception as exc:
        errors.append({"stage": "capture", "error": str(exc), "type": type(exc).__name__})
    finally:
        try:
            if "action" not in files:
                try:
                    files["action"] = _write(trial / "action.json", action)
                except Exception as exc:
                    errors.append({"stage": "action_artifact", "error": str(exc), "type": type(exc).__name__})
            # Elapsed time only; cleanup must still run if sleep/clock fails.
            try:
                deadline = monotonic() + flush_window
                while monotonic() < deadline:
                    sleep(min(0.1, max(0, deadline - monotonic())))
            except Exception as exc:
                errors.append({"stage": "flush_wait", "error": str(exc), "type": type(exc).__name__})
        finally:
            if probe_requested_dir:
                try:
                    stopped = _stop_probe(owner, probe_requested_dir)
                    report["probe_cleanup"] = stopped
                    try:
                        files["probe_stop"] = _write(trial / "probe-stop.json", stopped)
                    except Exception as exc:
                        errors.append({"stage": "probe_stop_artifact", "error": str(exc), "type": type(exc).__name__})
                except Exception as exc:
                    errors.append({"stage": "probe_stop", "error": str(exc), "type": type(exc).__name__})
        if freeze_fn is None:
            try:
                from freeze_trial import freeze_trial
                freeze_fn = freeze_trial
            except ImportError as exc:
                errors.append({"stage": "evidence", "error": str(exc), "type": type(exc).__name__})
        if freeze_fn is not None:
            try:
                report["evidence"] = freeze_fn(before, after, action, recorder_dir=Path(recorder_dir),
                    probe_dirs=evidence_dirs, destination=trial)
            except Exception as exc:
                errors.append({"stage": "evidence", "error": str(exc), "type": type(exc).__name__})
        report["control_window_qualified"] = all(report["qualifications"][k]
            for k in ("before_bound", "post_bound", "generation_unchanged", "action_done")) and not errors
        report["numerical_roll_proven"] = False  # only evidence analysis can establish this
        report["action_status"] = action.get("status")
        report["action_error"] = action.get("error")
        try:
            report["report_file"] = _write(trial / "report.json", report)
        except Exception as exc:
            errors.append({"stage": "report_artifact", "error": str(exc), "type": type(exc).__name__})
            report["control_window_qualified"] = False
            report["report_write_error"] = str(exc)
    report["report_path"] = str((trial / "report.json").resolve())
    return report


def summarize_trial(report):
    """Keep large native evidence on disk; stdout is an index, never acceptance."""
    evidence = report.get("evidence") or {}
    candidates = evidence.get("candidates") or []
    selected = [c for c in candidates if c.get("requested_guid_match") is True]
    return {k: report.get(k) for k in (
        "schema", "trial_dir", "report_path", "report_file", "action_attempts", "action_status",
        "action_error", "qualifications", "control_window_qualified", "numerical_roll_proven",
        "errors", "report_write_error", "probe_cleanup")} | {
            "evidence_index": {"requested_cast_guid": evidence.get("requested_cast_guid"),
                "candidate_count": len(candidates), "frozen_file_count": len(evidence.get("files") or []),
                "errors": evidence.get("errors") or [], "unknowns": evidence.get("unknowns") or [],
                "requested_candidates": [{k: c.get(k) for k in (
                    "cast_guid", "story_action_ids", "story_consistent", "direct_actor_target_pairs",
                    "target_confirmed_directly", "target_conflict", "numerical_attack_available", "acceptance")}
                    for c in selected], "acceptance": evidence.get("acceptance", "not_assessed")}}
