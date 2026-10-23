-- Native-like proxies record invalid read ATTEMPTS before throwing. Catching
-- errors cannot pass these tests: the attempt counter must stay zero.
local function read(path)local f=assert(io.open(path,"r"));local s=f:read("*a");f:close();return s end
local state,guard=read(assert(arg[1])),read(assert(arg[2]))
local checks,invalid,reads=0,{},{}
local schemas={Weapon={WeaponRange="ConstantInt",Damage="FixedString",Description="TranslatedString",Boosts="FixedString"},
 Armor={ArmorClass="ConstantInt",ArmorType="FixedString",Description="TranslatedString",Boosts="FixedString",DefaultBoosts="FixedString",PassivesOnEquip="FixedString"},
 Object={ObjectCategory="FixedString"},StatusData={Boosts="FixedString",Description="TranslatedString"},
 SpellData={DisplayName="TranslatedString",Level="ConstantInt",SpellType="FixedString",UseCosts="FixedString",RootSpellID="FixedString",SpellContainerID="FixedString",PowerLevel="ConstantInt",TargetRadius="FixedString",AreaRadius="FixedString",SpellFlags="Flags",TooltipAttackSave="FixedString",ContainerSpells="FixedString"}}
local function proxy(name,kind,data)
 return setmetatable({}, {__index=function(_,key)
  if key=="ModifierList" then return kind end
  reads[#reads+1]=name.."."..key
  if not(schemas[kind] and schemas[kind][key]) then invalid[#invalid+1]=name.."."..key;error("native logs before throwing")end
  return data[key]
 end})
end
local stats={ARM_Underwear_Shadowheart=proxy("ARM_Underwear_Shadowheart","Armor",{ArmorClass=10,ArmorType="Cloth",Description="underwear-desc",Boosts="",DefaultBoosts="",PassivesOnEquip=""}),
 CHA_PLT_Fissure=proxy("CHA_PLT_Fissure","Object",{ObjectCategory="Environment"}),
 WPN_Bow=proxy("WPN_Bow","Weapon",{WeaponRange=1800,Damage="1d6",Boosts="",Description="bow-desc"}),
 WPN_Pike=proxy("WPN_Pike","Weapon",{WeaponRange=250}),
 JUMP_STATUS=proxy("JUMP_STATUS","StatusData",{Boosts="JumpMaxDistanceMultiplier(3);IgnoreFallDamage()"}),
 Projectile_FireBolt=proxy("Projectile_FireBolt","SpellData",{DisplayName="Fire Bolt",Level=0,SpellType="Projectile",UseCosts="ActionPoint:1",RootSpellID="",SpellContainerID="",PowerLevel=0,TargetRadius="18",AreaRadius="",SpellFlags={},TooltipAttackSave="RangedSpellAttack",ContainerSpells=""})}
local Ext={Stats={Get=function(id)return stats[id]end,GetModifierAttributes=function(kind)return schemas[kind]end},
 Enums={ItemSlot={[0]="MeleeMainHand",[1]="RangedMainHand",[2]="Underwear"}}}
local U={loca=function(h)return h end}
local function helper(source)
 local a=assert(source:find("-- Schema-aware stat reads.",1,true))
 local b=assert(source:find("-- End schema-aware stat reads.",a,true))
 local env=setmetatable({Ext=Ext},{__index=_G})
 return assert(load(source:sub(a,b-1).."\nreturn declaredStatField","safe stat helper","t",env))()
end
local function section(source,start,finish,env,expression)
 local a=assert(source:find(start,1,true));local b=assert(source:find(finish,a+#start,true))
 return assert(load(source:sub(a,b-1).."\nreturn "..expression,"actual stat reader","t",setmetatable(env,{__index=_G})))()
end
local function check(v,message)checks=checks+1;assert(v,message)end
local sf,gf=helper(state),helper(guard)
check(sf(stats.CHA_PLT_Fissure,"Description")==nil,"Object Description remains unknown without invalid read")
check(gf(stats.CHA_PLT_Fissure,"Boosts")==nil,"Object Boosts remains unknown without invalid read")
check(gf(stats.ARM_Underwear_Shadowheart,"WeaponRange")==nil,"Armor range absent without invalid read")
check(sf(stats.WPN_Bow,"WeaponRange")==1800 and gf(stats.WPN_Pike,"WeaponRange")==250,"valid weapons preserve range")
check(sf(stats.JUMP_STATUS,"Boosts"):find("JumpMaxDistanceMultiplier",1,true)~=nil,"valid status boosts preserved")
local spellInfo=section(state,"S.spellCache = S.spellCache or {}","local function cooldowns(e)",
 {S={},Ext=Ext,U=U,osi=function(fn,...)return fn(...)end,declaredStatField=sf},"spellInfo")
local info=spellInfo("Projectile_FireBolt")
check(info.name=="Fire Bolt" and info.range=="18" and info.level==0,"valid spell facts intact")
check(info.save==nil,"unused save expression removed")
for _,entry in ipairs(reads)do check(not entry:find("SpellSaveDC",1,true),"SpellSaveDC never queried")end
local ranges=section(state,"local function weaponRanges(e)","local function spellSource(s)",
 {Ext=Ext,declaredStatField=sf},"weaponRanges")
local items={ [0]={Item={Data={StatsId="WPN_Pike"}}},[1]={Item={Data={StatsId="WPN_Bow"}}},
 [2]={Item={Data={StatsId="ARM_Underwear_Shadowheart"}}} }
local inventory={InventoryData={Type="Equipment"},InventoryContainer={Items=items}}
local entity={InventoryOwner={Inventories={inventory}}}
local result=ranges(entity)
check(result.MeleeMainWeaponRange==2.5 and result.RangedMainWeaponRange==18,"equipment weapons retain valid ranges")
local equipped="ARM_Underwear_Shadowheart"
local weaponRange=section(guard,"local function weapon_range(char, slot)","-- Resolve the range of a spell",{Ext=Ext,
 G={q=function(op)if op=="GetEquippedItem"then return "item"else return equipped end end},declaredStatField=gf},"weapon_range")
check(weaponRange("actor","MeleeMainHand")==nil,"wrong equipped type leaves range unknown")
equipped="WPN_Pike";check(weaponRange("actor","MeleeMainHand")==2.5,"valid Guard weapon range works")
local jump=section(guard,"G._jumpBoosts = G._jumpBoosts or {}","-- -> jump multiplier",{Ext=Ext,G={},declaredStatField=gf},"jumpBoosts")
check(jump("CHA_PLT_Fissure")==false,"non-status Object is not treated as jump status")
check(jump("JUMP_STATUS").mult==3 and jump("JUMP_STATUS").no_fall,"real status boosts still parsed")
local statField=section(state,"local function statField(st, k)","local function statsFacts(st, o)",
 {declaredStatField=sf},"statField")
check(statField(stats.ARM_Underwear_Shadowheart,"ModifierList")=="Armor","metadata getter preserved")
check(statField(stats.ARM_Underwear_Shadowheart,"Description")=="underwear-desc","valid equipment description preserved")
check(statField(stats.CHA_PLT_Fissure,"Description")==nil,"actual item-description read helper avoids unsupported field")
local facts=section(state,"local function statsFacts(st, o)","-- statsFacts per StatsId.",
 {statField=statField},"statsFacts")
local armor={};facts(stats.ARM_Underwear_Shadowheart,armor)
check(armor.ac==10 and armor.armor=="Cloth","valid equipment armor semantics preserved")
local unknownArmor={};facts(proxy("unknown armor","Armor",{ArmorType="Cloth",Boosts="AC(2)"}),unknownArmor)
check(unknownArmor.ac==nil,"missing armor base cannot become zero or boost-only AC")
local zeroArmor={};facts(proxy("zero armor","Armor",{ArmorClass=0,ArmorType="Cloth",Boosts="AC(2)"}),zeroArmor)
check(zeroArmor.ac==2,"observed zero armor class retains known boost semantics")
check(#invalid==0,"ZERO undeclared native read attempts, not merely caught errors")
local schemaAPI=Ext.Stats.GetModifierAttributes;Ext.Stats.GetModifierAttributes=nil
local cold=helper(state)
check(cold(stats.WPN_Bow,"WeaponRange")==nil,"unavailable schema leaves unknown instead of speculative read")
Ext.Stats.GetModifierAttributes=schemaAPI
check(#invalid==0,"unknown schema fallback made no invalid read attempts")
check(sf({WeaponRange=1800},"WeaponRange")==1800,"plain Lua bundle has raw data access without native proxy")
print(checks.." strict stat schema checks passed; invalid attempts="..#invalid)
