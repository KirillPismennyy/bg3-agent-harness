"""Offline immutable saved-trial -> observed single-action calculation.
No game/UI/network/provider access. BEFORE/raw operands and AFTER oracles are
separate phases. Selected results are never re-labelled individual d20 faces.
"""
from __future__ import annotations
import re
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE=Path(__file__).resolve().parent
SIMULATOR_SHA="94f7ef46cd62dd698df08a986f5b99e6fbda804ad1b61a00ce6d7768e0de9bba"
MOVEMENT_ID="d6b2369d-84f0-4ca4-a3a7-62d2d192a185"

class Refusal(ValueError):
    pass

def require(ok, message):
    if not ok: raise Refusal(message)

def sha(data): return hashlib.sha256(data).hexdigest()
def encoded(value): return (json.dumps(value,sort_keys=True,indent=2,allow_nan=False)+"\n").encode()
def scalar(value):
    return value.get("text",value.get("label")) if isinstance(value,dict) else value
def one(values, label):
    require(len(values)==1,f"Expected unique {label}; found {len(values)}")
    return values[0]

def resource_source_age(age,maximum,label):
    require(type(age) is int and 0<=age<=maximum,label+" consumed resource field source age must be nonnegative and within explicitly accepted bound")

def checkpoint_field_metadata(value,upper):
    if isinstance(value,dict):
        for key,item in value.items():
            if key=="st":require(type(item) is int and 0<=item<=upper,"Checkpoint field metadata timestamp is future/invalid")
            checkpoint_field_metadata(item,upper)
    elif isinstance(value,list):
        for item in value:checkpoint_field_metadata(item,upper)

def checkpoint_interval(record,boundary):
    require(record.get("kind")=="checkpoint" and type(record.get("t")) is int and 0<=record["t"]<=boundary,"Checkpoint record timestamp is future/invalid relative to observation boundary")
    data=record.get("data")
    require(isinstance(data,dict) and type(data.get("begin_t")) is int and type(data.get("end_t")) is int,"Checkpoint requires explicit valid begin_t/end_t interval")
    require(data["begin_t"]==record["t"]<=data["end_t"]<=boundary,"Checkpoint begin/end interval contradicts record start or observation boundary")
    return data["begin_t"],data["end_t"]

def safe_file(root,relative):
    path=(root/relative.replace("\\","/")).resolve()
    require(path.is_relative_to(root.resolve()),"Evidence path escapes its immutable root")
    return path

def after_receipt_metadata(data):
    """Read only top-level transaction envelope values, not expected outcomes.
    Unknown value spans are lexically skipped without JSON-decoding their content.
    Full AFTER JSON decoding remains in the post-execution comparison phase.
    """
    text=data.decode("utf-8");decoder=json.JSONDecoder();index=0;seen=set();result={}
    def whitespace(i):
        while i<len(text) and text[i].isspace():i+=1
        return i
    index=whitespace(index);require(text[index:index+1]=="{","AFTER receipt must be an object");index+=1
    while True:
        index=whitespace(index)
        if text[index:index+1]=="}":index+=1;break
        require(text[index:index+1]=='"',"Malformed AFTER receipt key")
        key,index=decoder.raw_decode(text,index)
        require(key not in seen,"Duplicate AFTER receipt key");seen.add(key)
        index=whitespace(index);require(text[index:index+1]==":","Malformed AFTER receipt separator");index=whitespace(index+1)
        if key in {"started_ms","finished_ms","owner_binding"}:
            result[key],index=decoder.raw_decode(text,index)
        else:
            start=index;depth=0;quoted=False;escaped=False
            while index<len(text):
                char=text[index]
                if quoted:
                    if escaped:escaped=False
                    elif char=="\\":escaped=True
                    elif char=='"':quoted=False
                elif char=='"':quoted=True
                elif char in "[{":depth+=1
                elif char in "]}":
                    if depth==0:break
                    depth-=1
                elif char=="," and depth==0:break
                index+=1
            require(index>start and depth==0 and not quoted,"Unterminated AFTER value span")
        index=whitespace(index)
        require(text[index:index+1] in {",","}"},"Malformed AFTER receipt delimiter")
        if text[index]=="}":index+=1;break
        index+=1
    require(not text[whitespace(index):],"Trailing AFTER receipt content")
    require(set(result)=={"started_ms","finished_ms","owner_binding"} and all(type(result[k]) is int for k in ("started_ms","finished_ms")) and isinstance(result["owner_binding"],dict),"Incomplete AFTER envelope metadata")
    return result

def complete_damage_evidence(value):
    if isinstance(value,dict):
        for key,item in value.items():
            require(not (key in {"cut","depth_cut","_cut","_omitted","truncated"} and item is True),"Damage evidence contains cut/truncation")
            require(not (key in {"errors","error"} and item),"Damage evidence contains error")
            require(not (key in {"complete","available"} and item is False),"Damage evidence is incomplete")
            complete_damage_evidence(item)
    elif isinstance(value,list):
        for item in value:complete_damage_evidence(item)
    else:require(value not in ("<omitted>","<budget>"),"Damage evidence contains omitted value")

def verify_bridge(bridge,expected_sha=SIMULATOR_SHA):
    require(bridge.is_file(),"Replay bridge is missing; rebuild with explicit SimulatorAssembly before launching dotnet")
    simulator=bridge.with_name("bg3sim.dll")
    require(simulator.is_file(),"Adjacent simulator DLL is missing; dotnet was not launched")
    digest=sha(simulator.read_bytes())
    require(digest==expected_sha,"Adjacent simulator DLL hash mismatch; dotnet was not launched")
    return {"bridgeSha256":sha(bridge.read_bytes()),"simulatorSha256":digest,"verifiedBeforeProcessLaunch":True}

def runtime_selection(adapter_path=None,simulator_sha256=None):
    require(simulator_sha256 is None or adapter_path is not None,"An explicit simulator hash requires --adapter; no implicit runtime replacement")
    expected=SIMULATOR_SHA if simulator_sha256 is None else simulator_sha256
    require(isinstance(expected,str) and len(expected)==64 and all(c in "0123456789abcdef" for c in expected),"Simulator SHA256 must be 64 lowercase hex characters")
    bridge=Path(adapter_path).resolve() if adapter_path is not None else (HERE/"replay_adapter/bin/Release/net8.0/TrialReplay.dll").resolve()
    return bridge,{"selection":"default-pinned" if adapter_path is None else "explicit-adapter","adapterPath":str(bridge),"expectedSimulatorSha256":expected}

class Intake:
    def __init__(self,trial,profile):
        self.trial=trial.resolve();self.profile=profile;self.receipts=[];self.verified={}
        self.expected_loaded=False
    def read(self,path,expected=None,maximum=64<<20):
        data=path.read_bytes()
        require(len(data)<=maximum,"Oversized evidence file: "+str(path))
        digest=sha(data)
        if expected: require(digest==expected,"SHA256 mismatch: "+str(path))
        self.receipts.append({"path":str(path),"bytes":len(data),"sha256":digest})
        return data
    def load(self,path,expected=None): return json.loads(self.read(path,expected))
    def verify(self):
        r=self.load(self.trial/"report.json",self.profile.get("trialReportSha256") if self.profile else None)
        require(r["action_attempts"]==1 and r["control_window_qualified"] and not r["errors"],"Trial control window is unqualified")
        m=self.load(self.trial/"evidence/hash-manifest.json",self.profile.get("freezeManifestSha256") if self.profile else None)
        for entry in m["files"]:
            path=safe_file(self.trial/"evidence",entry["file"])
            data=self.read(path,entry["sha256"])
            require(len(data)==entry["bytes"],"Frozen file length mismatch")
            require(path not in self.verified,"Duplicate manifest path")
            self.verified[path]=data
        for key in ("before","after","intent","action"):
            require(key in r["files"],"Missing trial file receipt: "+key)
            data=self.read(self.trial/(key+".json"),r["files"][key]["sha256"])
            if key=="after":self.after_receipt=after_receipt_metadata(data)
        self.report=r
        b=self.load(self.trial/"before.json");intent=self.load(self.trial/"intent.json")
        self.before=b;self.intent=intent
        require(b["required_reads_ok"],"Incomplete BEFORE snapshot")
        binding=b["owner_binding"]
        require(self.after_receipt["owner_binding"]==binding and b["finished_ms"]<self.after_receipt["started_ms"]<=self.after_receipt["finished_ms"],"Hash-bound AFTER envelope identity/time mismatch")
        require(binding==intent["binding"],"Intent/BEFORE binding mismatch")
        for snapshot in (b["recording"],b["snapshot_reads"]["identity"]["result"]):
            require(snapshot["combat_id"]==binding["combat_id"] and snapshot["session_id"]==binding["server_session"],"Snapshot recorder identity mismatch")
        require(binding["expected_recorder_hash"]==binding["server_recorder_hash"]==binding["client_recorder_hash"]==b["native"]["recorder_hash"],"Recorder source hash mismatch")
        self.rows=[]
        for path,data in self.verified.items():
            if path.suffix==".jsonl" and "-server-" in path.name:
                rows=[json.loads(line) for line in data.splitlines() if line]
                header=rows[0]
                require(header["kind"]=="part_header" and header["session_id"]==binding["server_session"] and header["combat_id"]==binding["combat_id"] and header["source_content_sha256"]==binding["expected_recorder_hash"],"Raw stream header binding mismatch")
                for line,row in enumerate(rows[1:],2):
                    row=dict(row);row["_evidence"]=str(path)+":"+str(line);self.rows.append(row)
        self.rows.sort(key=lambda x:x.get("seq",-1))
        seq=[x["seq"] for x in self.rows if "seq" in x]
        require(len(seq)==len(set(seq)),"Duplicate recorder sequence")
        require(seq==list(range(1,max(seq)+1)),"Incomplete recorder sequence; no partial stream replay")
        self.by_seq={r["seq"]:r for r in self.rows if "seq" in r}
        return b,intent
    def resolve_checkpoint(self,uuid,before_ms):
        require(type(before_ms) is int and before_ms>=0,"Invalid checkpoint observation boundary")
        candidates=[(r,a) for r in self.rows if r.get("kind")=="checkpoint" and r["t"]<=before_ms for a in r["data"].get("actors",[]) if a.get("uuid")==uuid]
        require(candidates,"No pre-boundary actor checkpoint")
        r,a=max(candidates,key=lambda pair:pair[0]["seq"]);latest=r;chain=[];merged={};seen=set();field_sources={}
        while True:
            require(r["seq"] not in seen,"Checkpoint base cycle")
            begin_time,end_time=checkpoint_interval(r,before_ms)
            checkpoint_field_metadata(a,end_time)
            seen.add(r["seq"]);chain.append(r["seq"])
            for k,v in a.items():
                if k not in merged:
                    merged[k]=v;field_sources[k]={"seq":r["seq"],"t":r["t"],"ageMs":before_ms-r["t"],"evidence":r["_evidence"]}
            base=a.get("base_seq")
            if base is None: break
            require(base<r["seq"] and base in self.by_seq,"Missing/reversed checkpoint base")
            parent=self.by_seq[base]
            require(type(parent.get("t")) is int and parent["t"]<=begin_time,"Checkpoint parent timestamp exceeds child timestamp")
            _,parent_end=checkpoint_interval(parent,before_ms)
            require(parent_end<=begin_time,"Checkpoint parent read completion exceeds child start")
            r=parent
            a=one([x for x in r["data"].get("actors",[]) if x.get("uuid")==uuid],"checkpoint base actor")
        return merged,{"latestSeq":latest["seq"],"t":latest["t"],"ageMs":before_ms-latest["t"],"atomic":latest["data"].get("atomic"),"chain":chain,"fieldSources":field_sources,"evidence":latest["_evidence"]}
    def joined_miss_random(self,caster,target,path,event):
        complete_damage_evidence(event)
        require(event.get("complete") is True and event.get("component_available") is True and event.get("hit_available") is True and event.get("errors")==[] and event.get("numerical_roll_seen") is True,"Incomplete executed miss event")
        h=event["Hit"];guid=h["SpellCastGuid"];story=h["StoryActionId"]
        require(type(story) is int and story>0 and guid==event["CastState"]["SpellCastGuid"]==self.report["evidence"]["requested_cast_guid"],"Miss cast GUID/story conflict")
        require(self.before["finished_ms"]<event["at_ms"]<=self.after_receipt["started_ms"],"Miss event outside transaction limits")
        require(h["SpellId"]==event["CastState"]["SpellId"]["Prototype"]==self.intent["spell"]=="Projectile_FireBolt","Unsupported miss prototype")
        require(scalar(h["EffectFlags"])=="DamageFlags(Miss,Dodge)" and h["TotalDamageDone"]==0 and type(h["TotalDamageDone"]) is int and scalar(h["DamageType"])=="None","Unsupported/conflicting native miss damage flags")
        conditions=h["ConditionRolls"]
        require(conditions.get("available") is True and conditions.get("truncated") is False and conditions.get("declared_count")==1,"Ambiguous/truncated miss roll")
        condition=one(conditions["values"],"miss attack roll");roll=condition["Roll"];desc=roll["Roll"]["Roll"]
        require(roll.get("available") is True and scalar(condition["RollType"])=="ConditionRollType(AttackRoll)" and condition["SwappedSourceAndTarget"] is False and scalar(h["SpellAttackType"])==scalar(roll["Roll"]["RollType"])=="RangedSpellAttack","Unsupported miss roll type")
        require(scalar(desc["DiceValue"])=="D20" and desc["AmountOfDices"]==1 and type(desc["DiceAdditionalValue"]) is int and -(2**31)<=desc["DiceAdditionalValue"]<2**31 and desc["DiceNegative"] is False,"Unsupported miss attack descriptor")
        rerolls=roll["Roll"]["RerollConditions"]
        require(rerolls.get("available") is True and rerolls.get("declared_count")==0 and rerolls.get("values")==[] and rerolls.get("truncated") is False,"Miss reroll tape unqualified")
        require(type(roll["Roll"]["Advantage"]) is bool and type(roll["Roll"]["Disadvantage"]) is bool and not (roll["Roll"]["Advantage"] and roll["Roll"]["Disadvantage"]),"Invalid miss roll mode")
        selected=roll["Result"]["NaturalRoll"]
        require(type(selected) is int and 1<=selected<=20,"Invalid selected miss d20")
        require(scalar(roll["Result"]["Critical"])=="None","Critical miss route unsupported")
        source={k:scalar(v) for k,v in event["CastState"]["SpellId"].items()};source["SpellCastingAbility"]=scalar(event["CastCache"]["SpellCastingAbility"])
        require(all(source[k]==v for k,v in self.intent["source"].items()),"Executed miss source differs from request")
        def entity_text(value):
            if isinstance(value,dict) and "entity" in value:value=value["entity"]
            value=scalar(value)
            require(isinstance(value,str) and re.fullmatch(r"Entity \([0-9a-fA-F]{16}\)",value) is not None,"Missing/malformed miss entity identity")
            return value
        cast_entity=entity_text(event.get("cast"));caster_entity=entity_text(event["caster"]);target_entity=entity_text(event["target"])
        require(entity_text(event.get("event_entity"))==cast_entity,"Miss numerical event/cast entity conflict")
        lifecycle=[]
        for probe_path,data in self.verified.items():
            if probe_path.suffix!=".json" or probe_path.parent.name not in {"0","1"}:continue
            probe=json.loads(data)
            if probe_path.parent.name=="1" and probe.get("Hit",{}).get("SpellCastGuid")==guid:
                require(probe_path==path,"Ambiguous same-GUID executed event set for miss")
            if probe_path.parent.name!="0":continue
            reads=probe.get("reads",[])
            relevant=probe.get("entity")==cast_entity or any(x.get("components",{}).get("SpellCastState",{}).get("SpellCastGuid")==guid for x in reads)
            if not relevant:continue
            complete_damage_evidence(probe)
            require(entity_text(probe.get("entity"))==cast_entity and probe.get("caster")==caster and probe.get("spell")==self.intent["spell"],"Miss lifecycle cast/actor/spell conflict")
            require(isinstance(reads,list) and reads,"Missing miss lifecycle reads")
            execution_seen=False;requested_source_seen=False;last_phase_rank=-1
            for read in reads:
                components=read.get("components",{});state=components.get("SpellCastState",{});server=components.get("ServerSpellCastState",{})
                require(state.get("SpellCastGuid")==guid and entity_text(state.get("Entity"))==cast_entity and entity_text(state.get("Caster"))==caster_entity,"Miss lifecycle internal cast/caster/GUID conflict")
                targets=state.get("Targets")
                require(isinstance(targets,list) and len(targets)==1 and entity_text(targets[0].get("Target"))==target_entity and targets[0].get("TargetingType")=="Projectile","Miss lifecycle target conflict")
                read_story=server.get("StoryActionId")
                require(type(read_story) is int and read_story in (0,story),"Miss lifecycle contradictory story identity")
                phase=scalar(server.get("Phase"))
                phase_ranks={"ValidationStart":0,"MovementSteering":1,"LogicExecutionUpdate":2,"Finished":3}
                require(phase in phase_ranks and phase_ranks[phase]>=last_phase_rank,"Miss lifecycle phase regression or unsupported phase")
                last_phase_rank=phase_ranks[phase]
                require((not execution_seen or read_story==story) and (phase_ranks[phase]<2 or read_story==story),"Miss lifecycle story regresses after execution phase")
                execution_seen=execution_seen or read_story==story
                read_source={k:scalar(v) for k,v in state["SpellId"].items()};read_source["SpellCastingAbility"]=scalar(components["SpellCastCache"]["SpellCastingAbility"])
                # The explicitly captured preexecution Osiris/default-ability source
                # may precede the requested experimental source rewrite, at story0.
                initial_source=dict(source,SourceType="Osiris",Source="00000000-0000-0000-0000-000000000000",ProgressionSource="00000000-0000-0000-0000-000000000000",SpellCastingAbility=self.before["native"]["actor"]["actor_default_ability"])
                require(read_source==source or (not execution_seen and not requested_source_seen and read_story==0 and phase_ranks[phase]<2 and read_source==initial_source),"Miss lifecycle source conflict or regression")
                requested_source_seen=requested_source_seen or read_source==source
                if read_story==story:lifecycle.append(str(probe_path))
        require(lifecycle,"Missing independent GUID/story/source lifecycle witness for miss")
        conflicts=[r for r in self.rows if r.get("kind")=="BeforeDealDamage" and r.get("data",{}).get("hit",{}).get("SpellCastGuid")==guid]
        require(not conflicts,"Miss route has GUID-bound damage producer; unsupported or conflicting evidence")
        within=[r for r in self.rows if self.before["finished_ms"]<r.get("t",-1)<=self.after_receipt["started_ms"]]
        using=one([r for r in within if r.get("kind")=="UsingSpellOnTarget" and r["data"].get("caster",{}).get("uuid")==caster and r["data"].get("target",{}).get("uuid")==target and r["data"].get("spell")==self.intent["spell"]],"raw miss target use")
        casted=one([r for r in within if r.get("kind")=="CastedSpell" and r["data"].get("caster",{}).get("uuid")==caster and r["data"].get("spell")==self.intent["spell"]],"raw miss cast completion")
        require(using["t"]<=event["at_ms"]<=casted["t"] and using["seq"]<casted["seq"],"Miss raw execution chronology conflict")
        self.join={"route":"executed-miss","castGuid":guid,"storyActionId":story,"source":source,"hitPath":str(path),"hitTimeMs":event["at_ms"],"lifecycleEvidence":sorted(set(lifecycle)),"rawUseSeq":using["seq"],"rawCastSeq":casted["seq"],"rawDamageProducer":"none for cast GUID in complete bound recorder stream","preOracleUpperReceipt":self.after_receipt,"selectedPairUnavailable":True,"discardedAggregateNotFace":roll["Result"].get("DiscardedDiceTotal")}
        return source,[{"kind":"selected-d20","actorId":caster,"value":selected,"advantage":roll["Roll"]["Advantage"],"disadvantage":roll["Roll"]["Disadvantage"],"evidenceReference":str(path)+"#/Hit/ConditionRolls/values/0/Roll/Result/NaturalRoll"}]

    def joined_random(self,caster,target):
        hits=[]
        for path,data in self.verified.items():
            if path.suffix==".json" and path.parent.name=="1":
                value=json.loads(data)
                if value.get("component")=="SpellCastTargetHitEvent" and value.get("caster",{}).get("uuid")==caster and value.get("target",{}).get("uuid")==target:
                    hits.append((path,value))
        misses=[]
        for path,data in self.verified.items():
            if path.suffix==".json" and path.parent.name=="1":
                value=json.loads(data)
                if value.get("component")=="SpellCastEvent" and value.get("caster",{}).get("uuid")==caster and value.get("target",{}).get("uuid")==target:
                    misses.append((path,value))
        if not hits:
            path,event=one(misses,"executed caster/target native miss event")
            return self.joined_miss_random(caster,target,path,event)
        # A separate numerical executed cast event must agree with the hit route.
        for _,event in misses:
            require("Miss" not in str(scalar(event.get("Hit",{}).get("EffectFlags"))),"Conflicting executed miss and hit events")
        path,hit=one(hits,"direct caster/target native hit event")
        require(hit.get("complete") is True and hit.get("errors")==[] and hit.get("numerical_roll_seen") is True,"Incomplete native hit evidence")
        guid=hit["Hit"]["SpellCastGuid"]
        require(guid==hit["CastState"]["SpellCastGuid"] and guid==self.report["evidence"]["requested_cast_guid"],"Requested/native cast GUID conflict")
        story=hit["Hit"]["StoryActionId"]
        conditions=hit["Hit"]["ConditionRolls"]
        require(conditions["available"] and not conditions["truncated"] and conditions["declared_count"]==1,"Ambiguous/truncated native attack rolls")
        roll=one(conditions["values"],"attack roll")["Roll"]
        descriptor=roll["Roll"]["Roll"]
        require(scalar(descriptor["DiceValue"])=="D20" and descriptor["AmountOfDices"]==1,"Unsupported native attack descriptor")
        rerolls=roll["Roll"]["RerollConditions"]
        require(rerolls["declared_count"]==0 and not rerolls["truncated"],"Native reroll tape unqualified")
        damage_rows=[r for r in self.rows if r.get("kind")=="BeforeDealDamage" and r.get("data",{}).get("hit",{}).get("SpellCastGuid")==guid]
        damage=one(damage_rows,"GUID-bound direct damage producer")
        h=damage["data"]["hit"]
        complete_damage_evidence(damage)
        require(h["StoryActionId"]==story and h["Inflicter"]["uuid"]==caster and h["InflicterOwner"]["uuid"]==caster and damage["data"]["caster"]["uuid"]==caster,"Damage actor/owner/story mismatch")
        require(damage["phase"]=="ext_event" and damage["data"]["attribution"]=="Hit.Inflicter","Damage producer attribution unqualified")
        require(h["SpellId"]==hit["Hit"]["SpellId"]==hit["CastState"]["SpellId"]["Prototype"]==self.intent["spell"],"Raw damage/hit/source prototype mismatch")
        require(h["SpellCastGuid"]==hit["CastState"]["SpellCastGuid"],"Damage/source GUID mismatch")
        for object_value,key in ((damage["data"],"target"),(h,"Target"),(h,"TargetUuid")):
            if key in object_value:
                value=object_value[key];observed=value.get("uuid") if isinstance(value,dict) else value
                require(observed==target,"Present raw damage target identity cannot be rebound or inferred away")
        require(self.before["finished_ms"]<damage["t"]<=self.after_receipt["started_ms"] and self.before["finished_ms"]<hit["at_ms"]<=self.after_receipt["started_ms"],"Native hit/damage producer outside hash-bound transaction limits before engine admission")
        damage_roll=one(h["Damage"]["ConditionRoll"]["RollParams"],"individual damage roll")
        d=damage_roll["Roll"]["Roll"]
        require(scalar(d["DiceValue"])=="D10" and d["AmountOfDices"]==1 and d["DiceAdditionalValue"]==0 and not d["DiceNegative"] and not damage_roll["Roll"]["Advantage"] and not damage_roll["Roll"]["Disadvantage"] and damage_roll["Roll"]["RerollConditions"]==[],"Direct damage face descriptor unsupported")
        source=hit["CastState"]["SpellId"]
        source={k:scalar(v) for k,v in source.items()};source["SpellCastingAbility"]=scalar(hit["CastCache"]["SpellCastingAbility"])
        require(source["Prototype"]==self.intent["spell"] and all(source[k]==v for k,v in self.intent["source"].items()),"Executed source does not equal explicit requested source")
        selected=roll["Result"]["NaturalRoll"]
        require(type(selected) is int and 1<=selected<=20,"Invalid selected d20")
        face=damage_roll["Result"]["NaturalRoll"]
        require(type(face) is int and 1<=face<=10,"Invalid direct individual d10")
        require(self.before["finished_ms"]<damage["t"] and self.before["finished_ms"]<hit["at_ms"],"Random result predates BEFORE boundary")
        self.join={"castGuid":guid,"storyActionId":story,"source":source,"hitPath":str(path),"hitTimeMs":hit["at_ms"],"damageTimeMs":damage["t"],"damageSeq":damage["seq"],"damageEvidence":damage["_evidence"],"damageTargetAttribution":"GUID/story inference through unique direct caster/target hit; raw damage producer has no target UUID field","preOracleUpperReceipt":self.after_receipt,"selectedPairUnavailable":True,"discardedAggregateNotFace":roll["Result"].get("DiscardedDiceTotal")}
        # Neither total damage nor attack totals/bonuses are mechanical inputs.
        random=[{"kind":"selected-d20","actorId":caster,"value":selected,"advantage":roll["Roll"]["Advantage"],"disadvantage":roll["Roll"]["Disadvantage"],"evidenceReference":str(path)+"#/Hit/ConditionRolls/values/0/Roll/Result/NaturalRoll"},{"kind":"individual-face","sides":10,"value":face,"evidenceReference":damage["_evidence"]+"#/data/hit/Damage/ConditionRoll/RollParams/0/Result/NaturalRoll"}]
        return source,random

def load_profile(path):
    if path is None:return None
    raw=path.read_bytes();value=json.loads(raw)
    allowed={"schema","mode","randomInputMode","trialReportSha256","freezeManifestSha256","rules","resourceDefinitions","statusBefore","statusAfter","controlled","qualifications","timingLimits"}
    require(set(value)==allowed and value["schema"]==1 and value["mode"]=="conditional","Unsupported profile schema or unexpected/oracle field")
    require(value["randomInputMode"]=="selected-d20-result-seam","Explicit post-selection d20 seam qualification required; no ordered face pair is inferred")
    allowed_control={"geometry","buildProjection","excludedTargetStatusMechanics","acceptDeferredCheckpoint","acceptStaleStatusProbe","actorExtraAttacks","actorUsedThisTurn","actorAwaitingRecharge","targetUnknownState"}
    require(allowed_control<=set(value["controlled"])<=allowed_control|{"acceptContainerListedStatusProjection","acceptValidatedOwnershipInventory"},"Unexpected controlled field, including observed/oracle overrides")
    if "acceptValidatedOwnershipInventory" in value["controlled"]:require(value["controlled"]["acceptValidatedOwnershipInventory"] is True,"Ownership inventory opt-in must be exactly true")
    if "acceptContainerListedStatusProjection" in value["controlled"]:require(value["controlled"]["acceptContainerListedStatusProjection"] is True,"Container-listed status projection opt-in must be exactly true")
    require(set(value["timingLimits"])=={"maxPreCheckpointAgeMs","maxBeforeStatusProbeAgeMs","maxAfterStatusProbeAgeMs","maxPostCheckpointAgeMs","maxBeforeActorResourceFieldSourceAgeMs","maxBeforeTargetResourceFieldSourceAgeMs","maxAfterActorResourceFieldSourceAgeMs","maxAfterTargetResourceFieldSourceAgeMs"} and all(type(v) is int and v>=0 for v in value["timingLimits"].values()),"Explicit finite checkpoint AND before/after consumed resource field-source staleness limits required")
    for record in (value["rules"],value["resourceDefinitions"],value["statusBefore"],value["statusAfter"]):
        require(set(record)=={"path","sha256"},"Malformed hash-bound external evidence")
    value["_loadedSha256"]=sha(raw)
    return value

def status_probe(intake,record,uuid,checkpoint_statuses,phase="before",boundary_ms=None):
    value=intake.load(Path(record["path"]),record["sha256"])
    require(value["route_validated"] and value["error_count"]==0 and all(value["gates"].values()),"Status ownership probe unqualified")
    require(value["combats"]==[intake.before["owner_binding"]["combat_id"]],"Status probe combat binding mismatch")
    boundary=intake.before["started_ms"] if boundary_ms is None else boundary_ms
    age=boundary-value["t_ms"] if phase=="before" else value["t_ms"]-boundary
    limit=intake.profile["timingLimits"]["maxBeforeStatusProbeAgeMs" if phase=="before" else "maxAfterStatusProbeAgeMs"]
    require(0<=age<=limit,"Status probe outside explicitly accepted staleness bound")
    actor=one([x for x in value["targets"] if x["uuid"]==uuid],"status owner")
    require(all(x["active"] for x in actor["owned"]),"Inactive status instance")
    actual=sorted((x["id"],str(x["instance"])) for x in actor["owned"])
    expected=sorted((x["id"],str(x["instance"])) for x in checkpoint_statuses)
    require(actual==expected,"Status probe/checkpoint identity mismatch")
    return actor["owned"],{"probeTimeMs":value["t_ms"],"probeAgeAtBeforeMs":intake.before["started_ms"]-value["t_ms"],"qualification":"separate non-atomic ownership probe; combat+monotonic+checkpoint instance identity crosscheck; probe does not record session/hash"}

def decimal_handle(value):
    require(isinstance(value,str),"Status handle must be an exact decimal string")
    try:number=int(value)
    except (ValueError,TypeError):raise Refusal("Status handle must be a canonical decimal int64 string")
    require(str(number)==value and number!=0 and -(1<<63)<=number<(1<<63),"Status handle must be a canonical nonzero decimal int64 string")
    return value

def fresh_status_entries(snapshot,role):
    """Listed container evidence only; never global absence or lifecycle semantics.
    None means the KEY was absent. Present failed/malformed facets always refuse.
    """
    native=snapshot["native"][role]
    if "status_container_entries" not in native:return None
    facet=native["status_container_entries"]
    require(isinstance(facet,dict) and facet.get("ok") is True and not facet.get("error"),"Present status_container_entries facet failed/malformed; no stale fallback")
    value=facet.get("result")
    require(isinstance(value,dict) and isinstance(value.get("rows"),list),"Status rows must be an explicit JSON array; no stale fallback or unqualified empty-object conversion")
    rows=value["rows"]
    require(type(value.get("count")) is int and 0<=value["count"]==len(rows)<=4096,"Status count invalid or inconsistent")
    require(value.get("owner_uuid")==native["uuid"],"Status owner UUID mismatch")
    owner=decimal_handle(value.get("owner_handle"))
    require(all(type(snapshot.get(k)) is int for k in ("started_ms","finished_ms")) and all(type(value.get(k)) is int for k in ("begin_ms","end_ms")),"Status callback/facet timing missing or malformed")
    require(0<=snapshot["started_ms"]<=value["begin_ms"]<=value["end_ms"]<=snapshot["finished_ms"],"Status facet interval outside callback")
    require(value.get("source")=="StatusContainer.Statuses + ServerStatus + ServerStatusOwnership.Owner" and value.get("coverage")=="present-container-entries-only" and all(value.get(k) is False for k in ("global_scan_performed","absence_proven","lifecycle_semantics_qualified")),"Status coverage/source contract is unqualified")
    seen=set()
    for row in rows:
        require(isinstance(row,dict) and isinstance(row.get("id"),str) and bool(row["id"]) and isinstance(row.get("type"),str) and bool(row["type"]) and type(row.get("active")) is bool,"Malformed status identity/type/active row")
        instance=decimal_handle(row.get("instance"))
        require(instance not in seen,"Duplicate status instance")
        seen.add(instance)
        require(decimal_handle(row.get("owner_handle"))==owner,"Status row owner handle mismatch")
        if "lifetime" in row:
            lifetime=row["lifetime"]
            require(isinstance(lifetime,dict) and type(lifetime.get("ok")) is bool,"Malformed optional raw status lifetime envelope")
            if lifetime["ok"]:
                raw=lifetime.get("result")
                require(isinstance(raw,dict) and type(raw.get("component_present")) is bool,"Malformed optional raw status lifetime result")
                if raw["component_present"]:
                    require(raw.get("units")=="unqualified" and type(raw.get("raw_value")) in (int,float) and math.isfinite(raw["raw_value"]),"Invalid unqualified raw status lifetime")
    return rows,{"source":"native."+role+".status_container_entries","beginMs":value["begin_ms"],"endMs":value["end_ms"],"ownerUuid":native["uuid"],"ownerHandle":owner,"coverage":value["coverage"],"globalOwnershipCompleteness":"unproven","absenceProven":False,"lifecycleSemanticsQualified":False,"qualification":"Fresh sequential callback listed-instance evidence only; no global ownership completeness, absence, source, remaining-turn or lifecycle semantics established."}

INVENTORY_HELPER_SHA256="b48a147c03fc77ee058b0fad2428e9c2a40b300a22c90198a6b92e04d67be901"

def ownership_inventory(snapshot,role):
    """Recompute the bounded ownership proof; present failure never falls back."""
    native=snapshot["native"]
    if "validated_status_inventory" not in native:return None
    facet=native["validated_status_inventory"]
    require(isinstance(facet,dict) and facet.get("ok") is True and not facet.get("error"),"Present validated_status_inventory failed/malformed; no fallback")
    v=facet.get("result")
    require(isinstance(v,dict) and v.get("schema")==1 and v.get("source")=="ServerStatus + ServerStatusOwnership.Owner; container set positive controls" and v.get("coverage")=="complete-server-status-ownership-at-callback","Ownership inventory contract mismatch")
    require(v.get("helper_sha256")==INVENTORY_HELPER_SHA256,"Ownership helper source pin mismatch")
    require(v.get("complete") is True and v.get("route_validated") is True and v.get("errors")==[] and v.get("lifecycle_semantics_qualified") is False,"Ownership inventory incomplete/unqualified")
    for k in ("started_ms","finished_ms"):require(type(snapshot.get(k)) is int,"Snapshot inventory interval unavailable")
    for k in ("begin_ms","end_ms","max_duration_ms","max_entities","total","scanned","controls","positive_controls"):require(type(v.get(k)) is int,"Inventory integer proof field unavailable")
    require(0<=snapshot["started_ms"]<=v["begin_ms"]<=v["end_ms"]<=snapshot["finished_ms"] and 0<v["max_duration_ms"]<=250 and v["end_ms"]-v["begin_ms"]<=v["max_duration_ms"],"Ownership inventory interval/budget invalid")
    require(0<=v["total"]==v["scanned"]<=v["max_entities"]<=50000,"Ownership inventory scan incomplete")
    identity=snapshot["recording"];binding=snapshot["owner_binding"]
    expected={"server_session":identity["session_id"],"combat_id":identity["combat_id"],"recorder_hash":native["recorder_hash"],"file_prefix":identity["file_prefix"]}
    require(v.get("binding_before")==expected==v.get("binding_after") and expected["server_session"]==binding["server_session"] and expected["combat_id"]==binding["combat_id"] and expected["recorder_hash"]==binding["server_recorder_hash"] and identity.get("recorder_active") is True and identity["combat_id"] in identity.get("party_combats",[]),"Ownership inventory recorder/combat binding mismatch")
    require(v.get("selected")=={r:native[r]["uuid"] for r in ("actor","target")},"Ownership inventory selected UUID mismatch")
    rows=v.get("global_rows");actors=v.get("actors")
    require(isinstance(rows,list) and len(rows)==v["scanned"] and isinstance(actors,list) and 2<=len(actors)<=4096,"Ownership inventory rows/control roster malformed")
    instances=set();owned={}
    for row in rows:
        require(isinstance(row,dict) and isinstance(row.get("id"),str) and bool(row["id"]) and isinstance(row.get("type"),str) and bool(row["type"]) and type(row.get("active")) is bool,"Malformed ownership status row")
        h=decimal_handle(row.get("instance"));owner=decimal_handle(row.get("owner_handle"))
        require(h not in instances,"Duplicate global status instance");instances.add(h)
        owned.setdefault(owner,[]).append(row)
    controls=positive=0;uuids=set();handles=set();selected=None
    for actor in actors:
        require(isinstance(actor,dict) and isinstance(actor.get("uuid"),str) and re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}",actor["uuid"]) and actor.get("role") in ("party","combat","selected") and type(actor.get("container_present")) is bool,"Inventory actor identity malformed")
        u=actor["uuid"];h=decimal_handle(actor.get("owner_handle"))
        require(u not in uuids and h not in handles,"Duplicate inventory actor identity");uuids.add(u);handles.add(h)
        listed=actor.get("container_rows");actual=actor.get("owned_rows")
        require(isinstance(listed,list) and isinstance(actual,list) and actual==sorted(owned.get(h,[]),key=lambda r:r["instance"]),"Inventory owned rows mismatch global scan")
        keys=[]
        for r in listed:
            require(isinstance(r,dict) and isinstance(r.get("id"),str) and bool(r["id"]),"Malformed inventory container row")
            keys.append((decimal_handle(r.get("instance")),r["id"]))
        require(len({r[0] for r in keys})==len(keys),"Duplicate inventory container instance")
        if actor["container_present"]:
            controls+=1;positive+=bool(keys)
            require(sorted(keys)==sorted((r["instance"],r["id"]) for r in actual),"Inventory positive control status set mismatch")
        else:require(not listed,"Absent inventory container has listed entries")
        if u==native[role]["uuid"]:selected=actor
    require(controls==v["controls"] and positive==v["positive_controls"] and positive>0,"Inventory positive control required/count mismatch")
    roster=v.get("roster")
    require(isinstance(roster,dict) and set(roster)=={"party","combat"} and all(isinstance(roster[k],dict) and roster[k] and all(u in uuids and flag is True for u,flag in roster[k].items()) for k in roster),"Inventory party/combat roster proof invalid")
    require(uuids==set(roster["party"])|set(roster["combat"])|set(v["selected"].values()),"Inventory controls differ from declared full roster")
    require(all(native[r]["uuid"] in uuids for r in ("actor","target")) and selected is not None,"Inventory selected actor omitted")
    direct=native[role].get("status_container_entries",{"absent":True})
    return selected["owned_rows"],{"source":"native.validated_status_inventory","coverage":v["coverage"],"globalOwnershipCompleteness":"validated-at-callback","absenceProven":not selected["owned_rows"],"lifecycleSemanticsQualified":False,"rows":selected["owned_rows"],"proof":v,"directContainerDiagnostic":direct,"qualification":"Complete bounded server-status ownership scan validated against all present roster containers and nonempty positive controls; absence applies only at this callback, not lifecycle/source semantics or whole scene parity."}


def status_evidence(intake,snapshot,role,checkpoint,phase,profile):
    complete=ownership_inventory(snapshot,role)
    if complete is not None:
        require(profile["controlled"].get("acceptValidatedOwnershipInventory") is True,"Validated ownership inventory requires explicit conditional opt-in")
        rows,receipt=complete
        if role=="actor":require(all(r["active"] is True for r in rows),"Inactive owned actor status cannot be silently dropped/imported active")
        return rows,receipt
    fresh=fresh_status_entries(snapshot,role)
    if fresh is None:
        if role=="target":
            projection=one([x for x in snapshot["turn_order"] if x["uuid"]==snapshot["native"][role]["uuid"]],phase+" target status projection")
            return projection["statuses"],{"source":"legacy-target-status-projection","coverage":"projection-only","globalOwnershipCompleteness":"unproven"}
        require(profile["controlled"]["acceptStaleStatusProbe"] is True,"Legacy "+phase+" actor status evidence requires explicit acceptStaleStatusProbe=true")
        return status_probe(intake,profile["statusBefore" if phase=="before" else "statusAfter"],snapshot["native"][role]["uuid"],checkpoint["statuses"],phase=phase,boundary_ms=snapshot["started_ms"] if phase=="before" else snapshot["finished_ms"])
    rows,receipt=fresh
    receipt["rows"]=rows
    require(profile["controlled"].get("acceptContainerListedStatusProjection") is True,"Fresh status container coverage requires explicit conditional acceptContainerListedStatusProjection seam")
    if role=="actor":
        require(all(x["active"] is True for x in rows),"Inactive listed actor status cannot be silently dropped or imported as active")
        require(sorted((x["id"],x["instance"]) for x in rows)==sorted((x["id"],str(x["instance"])) for x in checkpoint["statuses"]),"Fresh status/checkpoint identity mismatch; stale identities cannot silently replace fresh observation")
        receipt["checkpointCrosscheck"]="Identity match only; checkpoint and callback are separate non-atomic observations and do not prove global completeness."
    return rows,receipt

def resource_rows(native,checkpoint):
    if "raw_resource_entries" not in native:return checkpoint["resources"],"deferred-checkpoint"
    facet=native["raw_resource_entries"]
    require(isinstance(facet,dict),"Present raw_resource_entries facet is malformed; no stale fallback")
    require(facet.get("ok") is True and not facet.get("error"),"Present raw_resource_entries facet failed; no stale fallback")
    value=facet.get("result")
    require(isinstance(value,dict) and isinstance(value.get("rows"),list),"Malformed exact resource facet result; no stale fallback")
    rows=value["rows"]
    require(type(value.get("count")) is int and value["count"]==len(rows) and value.get("precision")=="unrounded","Malformed exact resource facet")
    normalized=[];keys=set()
    for row in rows:
        require(isinstance(row,dict) and isinstance(row.get("resource_uuid"),str) and type(row.get("entry_index")) is int and row["entry_index"]>=1,"Malformed exact resource row identity/index")
        key=(row["resource_uuid"],row["level"])
        require(key not in keys and type(row["level"]) is int and all(type(row[k]) in (int,float) and math.isfinite(row[k]) and row[k]>=0 for k in ("amount","max_amount")),"Malformed/duplicate exact resource row")
        keys.add(key);normalized.append({"id":row["resource_uuid"],"level":row["level"],"amount":row["amount"],"max":row["max_amount"]})
    return normalized,"callback-exact-unrounded"

def named_pools(rows,names):
    mapped={}
    for row in rows:
        require(row["id"] in names,"Unknown native resource UUID")
        name=names[row["id"]]
        require(row["level"] not in mapped.get(name,{}),"Duplicate native resource level")
        require(all(type(row[k]) in (int,float) and math.isfinite(row[k]) and row[k]>=0 for k in ("amount","max")),"Invalid native resource amount")
        if name!="Movement":require(row["amount"]==int(row["amount"]),"Fractional resource budget cannot be truncated")
        mapped.setdefault(name,{})[row["level"]]=row
    def ordinary(name):return one([r for level,r in mapped.get(name,{}).items() if level==0],name)
    core={"actions":int(ordinary("ActionPoint")["amount"]),"bonusActions":int(ordinary("BonusActionPoint")["amount"]),"reactionPoints":int(ordinary("ReactionActionPoint")["amount"]),"rawMovement":ordinary("Movement")["amount"],"maximumMovement":ordinary("Movement")["max"],"spellSlots":{str(level):int(r["amount"]) for level,r in mapped.get("SpellSlot",{}).items()},"resources":{name:int(one(list(items.values()),"non-tiered resource")["amount"]) for name,items in mapped.items() if name not in {"ActionPoint","BonusActionPoint","ReactionActionPoint","Movement","SpellSlot"}}}
    return core

def checkpoint_inputs(intake,snapshot,role,phase,profile):
    """Resolve historical state only for fields this role/phase consumes.
    Validate present native alternatives first: malformed data cannot select fallback.
    """
    native=snapshot["native"][role]
    resource_native="raw_resource_entries" in native
    if resource_native:resource_rows(native,None)
    complete=ownership_inventory(snapshot,role)
    if complete is None:fresh_status_entries(snapshot,role)
    consumed=[]
    if not resource_native:consumed.append("resources")
    if role=="actor" and complete is None:consumed.append("statuses")
    evidence={"path":str(intake.trial/(phase+".json")),"sha256":intake.report["files"][phase]["sha256"],"started_ms":snapshot["started_ms"],"finished_ms":snapshot["finished_ms"]}
    if not consumed:return {},{"noCheckpointConsumed":True,"consumedFields":[],"snapshotEvidence":evidence}
    boundary=snapshot["started_ms"] if phase=="before" else snapshot["finished_ms"]
    checkpoint,receipt=intake.resolve_checkpoint(native["uuid"],boundary)
    receipt=dict(receipt,noCheckpointConsumed=False,consumedFields=consumed,snapshotEvidence=evidence)
    if profile is not None:
        require(profile["controlled"]["acceptDeferredCheckpoint"] is True,"Stale checkpoint evidence cannot become an exact boundary")
        limit=profile["timingLimits"]["maxPreCheckpointAgeMs" if phase=="before" else "maxPostCheckpointAgeMs"]
        require(0<=receipt["ageMs"]<=limit,("Pre-checkpoint outside explicitly accepted staleness bound" if phase=="before" else "Post checkpoint outside explicitly accepted staleness bound"))
        if phase=="after":require(receipt["t"]>=intake.before["finished_ms"],"No post-action raw checkpoint")
    return checkpoint,receipt


def request(intake,before,profile):
    native=before["native"];caster=native["actor"]["uuid"];target=native["target"]["uuid"]
    party=one([x for x in before["party"] if x["uuid"]==caster and x["name"]==intake.intent["actor"]],"BEFORE caster")
    enemy=one([x for x in before["turn_order"] if x["uuid"]==target and x["name"]==intake.intent["target"]],"BEFORE target")
    require(caster!=target and party["hp"]==native["actor"]["hp"] and enemy["hp"]==native["target"]["hp"],"Native/projected actor identity/HP conflict")
    source,random=intake.joined_random(caster,target)
    require(source in [{k:v for k,v in s.items() if k in source} for s in native["actor"]["sources"]],"Executed source not in BEFORE caster sourcebook")
    require(source["SpellCastingAbility"]=="Intelligence","Unsupported source ability")
    cp,cp_receipt=checkpoint_inputs(intake,before,"actor","before",profile)
    target_cp,target_cp_receipt=checkpoint_inputs(intake,before,"target","before",profile)
    actor_rows,actor_precision=resource_rows(native["actor"],cp)
    target_rows,target_precision=resource_rows(native["target"],target_cp)
    movement=one([x for x in actor_rows if x["id"]==MOVEMENT_ID and x["level"]==0],"raw movement pool")
    gaps=["full-build-and-reaction-state","native-collision-and-Vines-contact","target-status-mechanics","individual-disadvantage-face-pair","actor-extra-attack-used-and-recharge-state"]
    if target_precision!="callback-exact-unrounded":gaps.append("target-current-resource-pools")
    if actor_precision!="callback-exact-unrounded":gaps.append("actor-current-resource-pools")
    for role in ("actor","target"):
        if ownership_inventory(before,role) is None:
            if fresh_status_entries(before,role) is None:gaps.append(role+"-fresh-listed-status-inventory")
    if "validated_status_inventory" not in native:gaps.append("global-owned-status-completeness")
    if cp_receipt["noCheckpointConsumed"] or cp_receipt["atomic"] is not True or cp_receipt["ageMs"]:gaps.append("atomic-current-raw-movement-and-status-boundary")
    if profile is None:return None,{"status":"refused","mode":"strict","missingInputs":gaps,"join":intake.join,"rawCheckpoint":cp_receipt,"wholeSceneParityAccepted":False,"nativeRngReproduced":False,"engineInvoked":False}
    c=profile["controlled"]
    owned,status_receipt=status_evidence(intake,before,"actor",cp,"before",profile)
    target_statuses,target_status_receipt=status_evidence(intake,before,"target",target_cp,"before",profile)
    intake.before_target_statuses=target_statuses
    require(c["geometry"]=="explicit-visibility-empty-contact" and c["buildProjection"]=="compiled-plain-spell-operands-only" and c["excludedTargetStatusMechanics"]==sorted(x["id"] for x in target_statuses),"Unsupported conditional projection or target-status identity conflict")
    if "validated_status_inventory" not in native and "status_container_entries" not in native["actor"]:require(c["acceptStaleStatusProbe"] is True,"Stale evidence cannot become an exact boundary")
    actor_field_age=0 if actor_precision=="callback-exact-unrounded" else cp_receipt["fieldSources"]["resources"]["ageMs"]
    target_field_age=0 if target_precision=="callback-exact-unrounded" else target_cp_receipt["fieldSources"]["resources"]["ageMs"]
    resource_source_age(actor_field_age,profile["timingLimits"]["maxBeforeActorResourceFieldSourceAgeMs"],"Before actor")
    resource_source_age(target_field_age,profile["timingLimits"]["maxBeforeTargetResourceFieldSourceAgeMs"],"Before target")
    observed_statuses=[{"instanceId":str(x["instance"]),"ownerId":caster,"statusId":x["id"],"evidenceReference":json.dumps(cp_receipt["snapshotEvidence"],sort_keys=True)+( ("; checkpoint "+cp_receipt["evidence"]) if not cp_receipt["noCheckpointConsumed"] and "statuses" in cp_receipt["consumedFields"] else "")+"; status evidence "+json.dumps(status_receipt,sort_keys=True)} for x in owned]
    require(set(c["targetUnknownState"])=={"extraAttacks","pactSlots","abilityUses","usedThisTurn","awaitingRecharge"},"Unknown controlled target state field; native pool overrides prohibited")
    resource_def=profile["resourceDefinitions"]
    resource_xml=ET.fromstring(intake.read(Path(resource_def["path"]),resource_def["sha256"]))
    names={}
    for node in resource_xml.findall(".//node[@id='ActionResourceDefinition']"):
        attributes={a.attrib["id"]:a.attrib.get("value") for a in node.findall("attribute")}
        names[attributes["UUID"]]=attributes["Name"]
    actor_pools=named_pools(actor_rows,names);target_pools=named_pools(target_rows,names)
    intake.resource_names=names
    actor_resources=party["resources"];slots={k:int(v[0]) for k,v in actor_resources.get("SpellSlot",{}).items()}
    require(all(actor_resources[k][0]==int(actor_resources[k][0]) for k in ("ActionPoint","BonusActionPoint","ReactionActionPoint")) and all(v[0]==int(v[0]) for v in actor_resources.get("SpellSlot",{}).values()),"Fractional projected resource budget cannot be truncated")
    other={k:int(v[0]) for k,v in actor_resources.items() if k not in {"ActionPoint","BonusActionPoint","ReactionActionPoint","Movement"} and isinstance(v,list)}
    state={"actorId":caster,"hp":native["actor"]["hp"],"actions":int(actor_resources["ActionPoint"][0]),"bonusActions":int(actor_resources["BonusActionPoint"][0]),"extraAttacks":c["actorExtraAttacks"],"reactionPoints":int(actor_resources["ReactionActionPoint"][0]),"rawMovement":movement["amount"],"maximumMovement":movement["max"],"temporaryHp":native["actor"]["temp_hp"],"spellSlots":slots,"pactSlots":{},"resources":other,"abilityUses":{},"usedThisTurn":c["actorUsedThisTurn"],"awaitingRecharge":c["actorAwaitingRecharge"],"statuses":observed_statuses,"evidenceReference":"observed BEFORE native facets and only explicitly consumed checkpoint fields; controlled fields segregated in profile"}
    # Projected AP/bonus/reaction observations take precedence over older rows;
    # require agreement before importing rather than overriding either silently.
    require(all(state[k]==actor_pools[k] for k in ("actions","bonusActions","reactionPoints","rawMovement","maximumMovement","spellSlots")),"Native callback/projected/checkpoint current pool conflict")
    target_state={"actorId":target,"hp":native["target"]["hp"],"temporaryHp":native["target"]["temp_hp"],"statuses":[],"evidenceReference":"observed native HP/temp and qualified resource rows; controlled excluded target-status mechanics",**target_pools,**c["targetUnknownState"]}
    units=[];nodes=[]
    for role,unit,projection,s in (("actor",native["actor"],party,state),("target",native["target"],enemy,target_state)):
        pos=unit["pos"];nodes.append({"id":role,"x":pos[0],"y":pos[2],"z":pos[1],"sourceGroundSurface":""})
        units.append({"id":unit["uuid"],"team":"Players" if role=="actor" else "Enemies","isPartyMember":role=="actor","level":projection["level"],"hp":unit["max_hp"],"initialHp":unit["hp"],"armorClass":projection["ac"],"strength":projection["abilities"]["str"],"dexterity":projection["abilities"]["dex"],"wisdom":projection["abilities"]["wis"],"charisma":projection["abilities"]["cha"],"movement":s["maximumMovement"],"position":role,"spellSlots":s["spellSlots"],"pactSpellSlots":s["pactSlots"],"resources":s["resources"]})
    rule=profile["rules"];intake.read(Path(rule["path"]),rule["sha256"],maximum=128<<20)
    payload={"schema":1,"scene":{"id":"conditional-saved-trial-"+intake.trial.name,"map":{"nodes":nodes,"visibility":[{"from":"actor","to":"target"}]},"units":units},"before":{"round":before["round"],"activeActorId":caster,"units":[state,target_state],"buildAndReactionEvidence":"controlled: "+c["buildProjection"],"geometryEvidence":"controlled: "+c["geometry"]},"intent":{"kind":"Ability","abilityId":source["Prototype"],"targetId":target},"source":source,"compilerContext":{"level":party["level"],"proficiencyBonus":native["actor"]["proficiency_bonus"],"spellcastingModifier":math.floor((party["abilities"]["int"]-10)/2)},"randomInputs":random,"rulesPath":rule["path"],"rulesSha256":rule["sha256"],"simulatorSha256":SIMULATOR_SHA}
    qualifications={"rawCheckpoint":cp_receipt,"targetRawCheckpoint":target_cp_receipt,"actorResourceFieldSourceAgeMs":actor_field_age,"targetResourceFieldSourceAgeMs":target_field_age,"resourceAgeQualification":"Checkpoint ages and consumed field-source ages are distinct and reported only when historical fields are consumed; no-checkpoint receipts identify the actual native snapshot evidence.","actorPoolPrecision":actor_precision,"targetPoolPrecision":target_precision,"statusProbe":status_receipt,"targetStatusEvidence":target_status_receipt,"missingNativeInputs":gaps,"controlledFields":c,"profileQualifications":profile["qualifications"],"nativeTargetStatusesRetainedButUnmodeled":target_statuses,"nativeGeometryAdmission":False,"nativeRngReproduced":False,"wholeSceneParityAccepted":False,"experimentalSourceEquivalence":"unproven","afterClientGenerationIndependentlyQualified":False,"afterGenerationLimitation":"Historical AFTER owner binding is a copied poll before the callback; no independently validated post-readiness epoch proof is consumed by this adapter."}
    return payload,qualifications

def usable_movement(resources):
    if "MovementObservation" not in resources:return resources["Movement"][0],"legacy rounded usable movement projection"
    observation=resources["MovementObservation"]
    require(isinstance(observation,dict),"Malformed movement observation")
    raw=observation.get("raw");usable=observation.get("usable_projection")
    require(isinstance(raw,dict) and isinstance(usable,dict) and raw.get("available") is True and usable.get("available") is True and raw.get("precision")=="unrounded","Unqualified native usable movement observation")
    for value in (raw.get("current"),raw.get("max"),usable.get("current"),usable.get("max")):
        require(type(value) in (int,float) and math.isfinite(value) and value>=0,"Invalid native usable movement numeric value")
    require(type(usable.get("mask_applied")) is bool and usable["max"]==raw["max"] and usable["current"]<=raw["current"]<=raw["max"],"Conflicting usable movement projection")
    require((usable["mask_applied"] and usable["current"]==0) or (not usable["mask_applied"] and usable["current"]==raw["current"]),"Conflicting movement mask")
    require(math.floor(usable["current"]*10+0.5)/10==resources["Movement"][0] and math.floor(usable["max"]*10+0.5)/10==resources["Movement"][1],"Rounded/unrounded usable movement projection conflict")
    return usable["current"],"callback unrounded guard usable projection; movement legality remains unqualified"

def compare(intake,payload,actual,profile):
    # This is the ONLY phase that parses AFTER/action expected outcomes.
    intake.expected_loaded=True
    after=intake.load(intake.trial/"after.json",intake.report["files"]["after"]["sha256"])
    action=intake.load(intake.trial/"action.json",intake.report["files"]["action"]["sha256"])
    require(after["owner_binding"]==intake.before["owner_binding"] and after["started_ms"]>intake.before["finished_ms"],"AFTER identity/time binding mismatch")
    require(all(after[k]==v for k,v in intake.after_receipt.items()),"AFTER oracle envelope differs from pre-admission bound receipt")
    require(after["required_reads_ok"] and action["status"]=="done","Expected outcome boundary unqualified")
    for producer in ("hitTimeMs",)+( ("damageTimeMs",) if "damageTimeMs" in intake.join else () ):
        require(intake.before["finished_ms"]<intake.join[producer]<=after["started_ms"],"Native "+producer+" outside strict BEFORE/AFTER transaction bounds")
    require(action["result"]["experimental_source"]["cast_guid"]==intake.join["castGuid"] and action["result"]["target"]["uuid"]==payload["intent"]["targetId"],"Expected outcome action identity mismatch")
    comparisons=[]
    def check(field,expected,observed,qualification="qualified observed comparison",kind="scalar"):
        comparisons.append({"field":field,"expected":expected,"actual":observed,"matched":expected==observed,"qualification":qualification,"kind":kind})
    units={u["view"]["id"]:u for u in actual["result"]["units"]}
    caster=payload["before"]["activeActorId"];target=payload["intent"]["targetId"]
    observed_target=one([x for x in intake.before["turn_order"] if x["uuid"]==target],"BEFORE target status projection")
    projected_target=one([x for x in payload["before"]["units"] if x["actorId"]==target],"request target state")
    check("before.target.statusIds",sorted(x["id"] for x in intake.before_target_statuses),sorted(x["statusId"] for x in projected_target["statuses"]),"known projection exclusion: native target-status mechanics remain unmodeled",kind="coverage-exclusion")
    for role,uuid in (("actor",caster),("target",target)):
        require(after["native"][role]["uuid"]==uuid,"AFTER actor/target identity mismatch")
        view=units[uuid]["view"]
        check(role+".hp",after["native"][role]["hp"],view["hp"])
        check(role+".maxHp",after["native"][role]["max_hp"],view["maxHp"])
        check(role+".temporaryHp",after["native"][role]["temp_hp"],view["temporaryHp"])
        node=one([n for n in payload["scene"]["map"]["nodes"] if n["id"]==view["position"]],"result position")
        check(role+".position",after["native"][role]["pos"],[node["x"],node["z"],node["y"]])
    actor_after=one([a for a in after["party"] if a["uuid"]==caster],"AFTER caster projection")
    for native_key,model_key in (("ActionPoint","actions"),("BonusActionPoint","bonusActions"),("ReactionActionPoint","reactionPoints")):
        check("actor."+native_key,actor_after["resources"][native_key][0],units[caster]["view"][model_key])
    usable,usable_qualification=usable_movement(actor_after["resources"])
    check("actor.usableMovement",usable,units[caster]["view"]["movement"],usable_qualification)
    cp,receipt=checkpoint_inputs(intake,after,"actor","after",profile)
    after_rows,after_precision=resource_rows(after["native"]["actor"],cp)
    actor_field_age=0 if after_precision=="callback-exact-unrounded" else receipt["fieldSources"]["resources"]["ageMs"]
    resource_source_age(actor_field_age,profile["timingLimits"]["maxAfterActorResourceFieldSourceAgeMs"],"After actor")
    movement=one([x for x in after_rows if x["id"]==MOVEMENT_ID and x["level"]==0],"AFTER raw movement")
    if "MovementObservation" in actor_after["resources"]:
        observed_raw=actor_after["resources"]["MovementObservation"]["raw"]
        require(observed_raw["current"]==movement["amount"] and observed_raw["max"]==movement["max"],"Guard movement raw observation conflicts with native pool")
    check("actor.rawMovement",movement["amount"],units[caster]["rawMovement"],after_precision)
    owned,after_status_receipt=status_evidence(intake,after,"actor",cp,"after",profile)
    check("actor.statusIdentities",sorted((x["id"],str(x["instance"])) for x in owned),sorted((x["statusId"],x["instanceId"]) for x in units[caster]["statusInstances"]),json.dumps(after_status_receipt,sort_keys=True))
    target_after_statuses,target_after_status_receipt=status_evidence(intake,after,"target",{},"after",profile)
    check("target.statusIds",sorted(x["id"] for x in target_after_statuses),sorted(x["statusId"] for x in units[target]["statusInstances"]),"known projection exclusion, not mechanical equivalence; "+json.dumps(target_after_status_receipt,sort_keys=True),kind="coverage-exclusion")
    target_cp,target_receipt=checkpoint_inputs(intake,after,"target","after",profile)
    target_rows,target_precision=resource_rows(after["native"]["target"],target_cp)
    target_field_age=0 if target_precision=="callback-exact-unrounded" else target_receipt["fieldSources"]["resources"]["ageMs"]
    resource_source_age(target_field_age,profile["timingLimits"]["maxAfterTargetResourceFieldSourceAgeMs"],"After target")
    pools=named_pools(target_rows,intake.resource_names)
    for key in ("actions","bonusActions","reactionPoints","rawMovement","maximumMovement"):
        actual_value=units[target][key] if key in ("rawMovement","maximumMovement") else units[target]["view"][key]
        check("target."+key,pools[key],actual_value,target_precision)
    hit_path=Path(intake.join["hitPath"]);hit=json.loads(intake.verified[hit_path])
    require(hit["at_ms"]<=after["started_ms"],"Native hit outside transaction boundary")
    check("source.ability",scalar(hit["Hit"]["AttackRollAbility"]),payload["source"]["SpellCastingAbility"])
    events=actual["result"]["events"]
    resolution=one(actual["result"]["attackResolutions"],"actual attack resolution receipt")
    require(resolution["actorId"]==caster and resolution["targetId"]==target and resolution["abilityId"]==payload["intent"]["abilityId"],"Actual attack resolution identity mismatch")
    condition=one(hit["Hit"]["ConditionRolls"]["values"],"native attack comparison")
    native_roll=condition["Roll"]
    check("attack.natural",native_roll["Result"]["NaturalRoll"],resolution["natural"])
    check("attack.totalUsedForComparison",native_roll["Result"]["Total"],resolution["totalUsedForComparison"],"native stored Total versus actual engine comparison total; no causal bonus attribution")
    check("attack.armorUsedForComparison",condition["Difficulty"],resolution["armorUsedForComparison"],"native stored Difficulty versus actual engine comparison armor")
    check("attack.mode",{"advantage":native_roll["Roll"]["Advantage"],"disadvantage":native_roll["Roll"]["Disadvantage"]},{"advantage":resolution["advantage"],"disadvantage":resolution["disadvantage"]})
    check("attack.hit","Hit" in scalar(hit["Hit"]["EffectFlags"]).split("(")[1].split(")")[0].split(","),resolution["hit"])
    expected_damage={}
    miss=intake.join.get("route")=="executed-miss"
    if miss:
        require(action["result"].get("no_damage") is True and "damage" not in action["result"] and "total_damage" not in action["result"],"Native miss action outcome must explicitly report no_damage with no conflicting damage fields")
    for packet in action["result"].get("damage",[]) if miss else action["result"]["damage"]:
        require(packet["target"]==target and isinstance(packet["type"],str),"Native damage packet target/type unqualified")
        expected_damage[packet["type"]]=expected_damage.get(packet["type"],0)+packet["amount"]
    expected_total=0 if miss else action["result"]["total_damage"]
    require(sum(expected_damage.values())==expected_total,"Native damage list/total conflict")
    if miss:
        require(hit["Hit"]["TotalDamageDone"]==0 and after["native"]["target"]["hp"]==intake.before["native"]["target"]["hp"] and after["native"]["target"]["temp_hp"]==intake.before["native"]["target"]["temp_hp"],"Native miss zero-damage/HP corroboration conflict")
    else:
        raw_hit=intake.by_seq[intake.join["damageSeq"]]["data"]["hit"]
        require(raw_hit["Damage"]["FinalDamagePerType"]==expected_damage and scalar(raw_hit["DamageType"]) in expected_damage,"Native raw damage producer and independently segregated typed outcome conflict")
    actual_damage={}
    for event in events:
        if event["kind"]=="damage" and event["target"]==target:
            actual_damage[event["detail"]]=actual_damage.get(event["detail"],0)+event["value"]
    check("damage.byType",expected_damage,actual_damage,"native qualified typed damage packets versus actual engine damage event detail/type; unexpected types remain visible")
    check("damage.total",expected_total,sum(actual_damage.values()),"total damage is separate from the typed comparison")
    return comparisons,{"actor":receipt,"target":target_receipt,"actorResourceFieldSourceAgeMs":actor_field_age,"targetResourceFieldSourceAgeMs":target_field_age,"actorStatusEvidence":after_status_receipt,"targetStatusEvidence":target_after_status_receipt}

def run(trial,profile_path,output,*,adapter_path=None,simulator_sha256=None):
    bridge,selection=runtime_selection(adapter_path,simulator_sha256)
    require(trial.is_dir(),"Explicit trial directory does not exist")
    require(not output.resolve().is_relative_to(trial.resolve()),"Outputs must not modify the immutable trial")
    require(not output.exists(),"Output directory must be new")
    output.mkdir(parents=True)
    profile=load_profile(profile_path)
    intake=Intake(trial,profile);before,_=intake.verify()
    payload,qualification=request(intake,before,profile)
    qualification["runtimeSelection"]=selection
    if payload is None:
        qualification["receipts"]=intake.receipts;(output/"report.json").write_bytes(encoded(qualification));return qualification
    payload["simulatorSha256"]=selection["expectedSimulatorSha256"]
    payload_path=output/"operands.json";payload_path.write_bytes(encoded(payload))
    bridge_receipt=verify_bridge(bridge,selection["expectedSimulatorSha256"])
    completed=subprocess.run(["dotnet",str(bridge),str(payload_path)],capture_output=True,text=True,timeout=60)
    (output/"adapter.stdout.json").write_text(completed.stdout,encoding="utf-8");(output/"adapter.stderr.txt").write_text(completed.stderr,encoding="utf-8")
    require(completed.returncode==0,"Observed action adapter refused: "+completed.stderr)
    actual=json.loads(completed.stdout)
    require(sha(bridge.read_bytes())==bridge_receipt["bridgeSha256"],"Bridge binary changed during invocation")
    require(actual["requestSha256"]==sha(payload_path.read_bytes()) and actual["simulatorSha256"]==selection["expectedSimulatorSha256"] and actual["api"]=="BattleEngine.ExecuteObservedAction","API execution receipt mismatch")
    comparisons,post_cp=compare(intake,payload,actual,profile)
    mismatches=[x for x in comparisons if not x["matched"] and x["kind"]!="coverage-exclusion"]
    exclusions=[x for x in comparisons if x["kind"]=="coverage-exclusion"]
    result={"schema":1,"status":"scalar_mismatch" if mismatches else "executed_with_known_projection_exclusions","mode":"conditional","engineInvoked":True,"api":actual["api"],"join":intake.join,"qualification":qualification,"expectedOutcomesLoadedAfterEngine":intake.expected_loaded,"comparison":comparisons,"mismatches":mismatches,"earliestDivergence":mismatches[0] if mismatches else None,"knownProjectionExclusions":exclusions,"fullSceneAdmissionBlocked":True,"attackComparatorSemantics":"native stored Total/Difficulty versus exact actual totalUsedForComparison/armorUsedForComparison; no causal effective-bonus decomposition or RNG-pair claim","unavailableComparisons":["causal attribution of effective attack bonus components","native target usable movement is not independently qualified","full target status behavior and complete scene/build/reaction equivalence"],"postRawCheckpoints":post_cp,"receipts":intake.receipts,"operandSha256":sha(payload_path.read_bytes()),"prelaunchBridgeReceipt":bridge_receipt,"adapterDllSha256":bridge_receipt["bridgeSha256"],"profileSha256":profile["_loadedSha256"],"gameplayParityAccepted":False}
    (output/"report.json").write_bytes(encoded(result));return result

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("trial",type=Path);parser.add_argument("--profile",type=Path);parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--adapter",type=Path,help="Explicit built adapter DLL; simulator DLL must be adjacent")
    parser.add_argument("--simulator-sha256",help="Exact lowercase SHA256 for the selected simulator; requires --adapter")
    args=parser.parse_args()
    try:
        report=run(args.trial,args.profile,args.output,adapter_path=args.adapter,simulator_sha256=args.simulator_sha256)
        print(json.dumps({"status":report["status"],"engineInvoked":report["engineInvoked"],"report":str((args.output/"report.json").resolve()),"mismatchCount":len(report.get("mismatches",[]))}))
        return 2 if report["status"]=="refused" else 3 if report["status"]=="scalar_mismatch" else 0
    except Exception as error:
        print(json.dumps({"status":"error","error_type":type(error).__name__,"error":str(error)}),file=sys.stderr);return 1
if __name__=="__main__":sys.exit(main())
