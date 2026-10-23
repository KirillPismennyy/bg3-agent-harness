using Bg3Sim;
using System.Security.Cryptography;
using System.Text.Json;

try
{
    if(args.Length!=1)throw new ArgumentException("One isolated operand request path is required.");
    using var document=JsonDocument.Parse(File.ReadAllBytes(args[0]));var r=document.RootElement;
    var allowed=new HashSet<string>{"schema","scene","before","intent","source","compilerContext","randomInputs","rulesPath","rulesSha256","simulatorSha256"};
    if(r.EnumerateObject().Any(p=>!allowed.Contains(p.Name))||r.GetProperty("schema").GetInt32()!=1)throw new ArgumentException("Unexpected request field or schema; oracle fields are prohibited.");
    string Hash(byte[] bytes)=>Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    string simulator=typeof(BattleEngine).Assembly.Location;
    if(Hash(File.ReadAllBytes(simulator))!=r.GetProperty("simulatorSha256").GetString())throw new InvalidDataException("Simulator DLL hash mismatch.");
    byte[] ruleBytes=File.ReadAllBytes(r.GetProperty("rulesPath").GetString()!);
    if(Hash(ruleBytes)!=r.GetProperty("rulesSha256").GetString())throw new InvalidDataException("Source rules hash mismatch.");
    var source=r.GetProperty("source");string prototype=source.GetProperty("Prototype").GetString()!;
    if(prototype!="Projectile_FireBolt"||source.GetProperty("SpellCastingAbility").GetString()!="Intelligence")throw new ArgumentException("Only the qualified Intelligence FireBolt adapter is implemented.");
    using var ruleDoc=JsonDocument.Parse(ruleBytes);
    var fields=ruleDoc.RootElement.GetProperty("stats").GetProperty(prototype).GetProperty("resolved").EnumerateObject().ToDictionary(p=>p.Name,p=>p.Value.GetString()!);
    var c=r.GetProperty("compilerContext");
    var compiled=SourceSpellCompiler.Compile(prototype,fields,new(){Level=c.GetProperty("level").GetInt32(),ProficiencyBonus=c.GetProperty("proficiencyBonus").GetInt32(),SpellcastingModifier=c.GetProperty("spellcastingModifier").GetInt32(),SpellcastingAbility=AbilityScore.Intelligence,BaseAttackBonus=0});
    if(compiled.Ability==null||compiled.Unsupported.Count!=0)throw new InvalidOperationException("Source compile unsupported: "+string.Join(";",compiled.Unsupported));
    var scene=r.GetProperty("scene").Deserialize<Scenario>(BattleEngine.JsonOptions)!;
    var before=r.GetProperty("before").Deserialize<ObservedMidturnState>(BattleEngine.JsonOptions)!;
    scene.Units.Single(u=>u.Id==before.ActiveActorId).Abilities=[compiled.Ability];
    var intent=r.GetProperty("intent").Deserialize<CombatDecision>(BattleEngine.JsonOptions)!;
    var random=r.GetProperty("randomInputs").EnumerateArray().Select<JsonElement,ObservedActionRandomInput>(x=>x.GetProperty("kind").GetString() switch {
        "selected-d20"=>new ObservedSelectedD20(x.GetProperty("actorId").GetString()!,x.GetProperty("value").GetInt32(),x.GetProperty("advantage").GetBoolean(),x.GetProperty("disadvantage").GetBoolean(),x.GetProperty("evidenceReference").GetString()!,SuppliedInputOrigin.Observed),
        "individual-face"=>new ObservedActionDieFace(x.GetProperty("sides").GetInt32(),x.GetProperty("value").GetInt32(),x.GetProperty("evidenceReference").GetString()!,SuppliedInputOrigin.Observed),
        _=>throw new ArgumentException("Unqualified random input kind.")}).ToArray();
    var result=BattleEngine.ExecuteObservedAction(scene,before,intent,random);
    Console.WriteLine(JsonSerializer.Serialize(new{schema=1,status="executed",api="BattleEngine.ExecuteObservedAction",simulatorSha256=Hash(File.ReadAllBytes(simulator)),requestSha256=Hash(File.ReadAllBytes(args[0])),source,compilerContext=c,compiledAbility=compiled.Ability,result},new JsonSerializerOptions(BattleEngine.JsonOptions){WriteIndented=true,PropertyNamingPolicy=JsonNamingPolicy.CamelCase}));
}
catch(Exception error)
{
    Console.Error.WriteLine(JsonSerializer.Serialize(new{status="error",error_type=error.GetType().FullName,error=error.Message,detail=error.ToString()}));Environment.ExitCode=1;
}
