-- Synchronous, read-only ownership proof. Embedded by trial_capture.snapshot_code.
local function validated_status_inventory()
 local begin_ms=Ext.Utils.MonotonicTime()
 local max_entities,max_duration_ms=50000,250
 local function bounded()
  assert(Ext.Utils.MonotonicTime()-begin_ms<=max_duration_ms,"status inventory time bound exceeded")
 end
 local function hid(h)
  local n=Ext.Utils.HandleToInteger(h)
  assert(math.type(n)=="integer" and n~=0,"status inventory handle unavailable")
  return tostring(n)
 end
 local function uuid(u)
  assert(type(u)=="string","UUID unavailable")
  local v=u:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
  assert(v,"canonical UUID unavailable");return v:lower()
 end
 local function identity()
  local i=rpc("fightbot.identity").result
  assert(i and i.recorder_active==true and type(i.session_id)=="string" and type(i.combat_id)=="string","recorder identity unavailable")
  local member=false
  for _,c in ipairs(i.party_combats or {}) do if c==i.combat_id then member=true end end
  assert(member,"recorder combat not party combat")
  local hash=FightRecV2 and FightRecV2.source_content_sha256
  assert(type(hash)=="string" and #hash==64,"recorder hash unavailable")
  return {server_session=i.session_id,combat_id=i.combat_id,recorder_hash=hash,file_prefix=i.file_prefix}
 end
 local before=identity()
 local actors,by_uuid,by_handle={},{},{}
 local roster={party={},combat={}}
 local function dense(list,fn)
  local n=#list;assert(n<=4096,"control roster bound exceeded")
  local count=0
  for index,value in pairs(list) do
   assert(math.type(index)=="integer" and index>=1 and index<=n,"non-dense control roster")
   count=count+1;bounded();fn(value)
  end
  assert(count==n,"partial control roster")
 end
 local function add(u,role)
  u=uuid(u)
  if by_uuid[u] then return end
  local e=assert(Ext.Entity.Get(u),"control entity unavailable")
  local h=hid(e);assert(not by_handle[h],"duplicate actor owner handle")
  local t={uuid=u,owner_handle=h,role=role,container_present=e.StatusContainer~=nil,container_rows={},owned_rows={}}
  local seen={}
  if t.container_present then
   for key,id in pairs(e.StatusContainer.Statuses) do
    bounded();local k=hid(key)
    assert(not seen[k] and type(id)=="string" and id~="","duplicate/malformed container key")
    seen[k]=true;t.container_rows[#t.container_rows+1]={instance=k,id=id}
   end
  end
  assert(#actors<4096,"combined control roster bound exceeded")
  actors[#actors+1]=t;by_uuid[u]=t;by_handle[h]=t
 end
 dense(assert(Osi.DB_Players:Get(nil),"party controls unavailable"),function(r)
  local u=uuid(r[1]);assert(not roster.party[u],"duplicate party roster UUID");roster.party[u]=true;add(u,"party")
 end)
 dense(assert(Osi.DB_Is_InCombat:Get(nil,before.combat_id),"combat controls unavailable"),function(r)
  local u=uuid(r[1]);assert(not roster.combat[u],"duplicate combat roster UUID");roster.combat[u]=true;add(u,"combat")
 end)
 assert(next(roster.party) and next(roster.combat),"empty party/combat roster")
 add(q.actor,"selected");add(q.target,"selected")
 local all=assert(Ext.Entity.GetAllEntitiesWithComponent("ServerStatus"),"status enumeration unavailable")
 local total=#all;assert(total<=max_entities,"status inventory entity bound exceeded")
 local rows,instances={},{}
 for index,s in pairs(all) do
  assert(math.type(index)=="integer" and index>=1 and index<=total,"non-dense status enumeration")
  bounded();local instance=hid(s);assert(not instances[instance],"duplicate global status instance")
  instances[instance]=true
  local server=assert(s.ServerStatus,"server status unavailable")
  assert(server.StatusId~=nil and tostring(server.StatusId)~="" and server.Type~=nil,"status identity unavailable")
  local owner=hid(assert(s.ServerStatusOwnership,"status ownership unavailable").Owner)
  local active=s:HasRawComponent("esv::status::ActiveComponent")
  assert(type(active)=="boolean","status active tag unavailable")
  local r={instance=instance,id=tostring(server.StatusId),type=tostring(server.Type),owner_handle=owner,active=active}
  rows[#rows+1]=r
  if by_handle[owner] then
   local owned=by_handle[owner].owned_rows
   owned[#owned+1]={instance=instance,id=r.id,type=r.type,owner_handle=owner,active=active}
  end
 end
 assert(#rows==total,"partial status enumeration")
 local controls,positive=0,0
 local function sort(t)table.sort(t,function(a,b)return a.instance<b.instance end)end
 for _,a in ipairs(actors) do
  sort(a.container_rows);sort(a.owned_rows)
  if a.container_present then
   controls=controls+1
   if #a.container_rows>0 then positive=positive+1 end
   assert(#a.container_rows==#a.owned_rows,"control status cardinality mismatch")
   for n,r in ipairs(a.container_rows) do
    local owned=a.owned_rows[n]
    assert(r.instance==owned.instance and r.id==owned.id,"control status set mismatch")
   end
  end
 end
 assert(positive>0,"nonempty positive status control required")
 bounded();local after=identity()
 for k,v in pairs(before) do assert(after[k]==v,"recorder identity changed during inventory") end
 bounded();sort(rows);table.sort(actors,function(a,b)return a.uuid<b.uuid end)
 local end_ms=Ext.Utils.MonotonicTime()
 assert(end_ms-begin_ms<=max_duration_ms,"status inventory final time bound exceeded")
 return {schema=1,source="ServerStatus + ServerStatusOwnership.Owner; container set positive controls",
  begin_ms=begin_ms,end_ms=end_ms,max_duration_ms=max_duration_ms,max_entities=max_entities,
  helper_sha256=inventory_helper_sha256,roster=roster,binding_before=before,binding_after=after,total=total,scanned=#rows,global_rows=rows,actors=actors,
  selected={actor=uuid(q.actor),target=uuid(q.target)},controls=controls,positive_controls=positive,
  complete=true,route_validated=true,errors={},lifecycle_semantics_qualified=false,
  coverage="complete-server-status-ownership-at-callback"}
end
