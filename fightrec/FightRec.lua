-- FightRec v2: records Baldur's Gate 3 fights to numbered JSONL parts. Needs only Norbyte's Script Extender.
-- Derived from baseline/FightRec.lua (kept byte-for-byte unchanged); design: docs/DESIGN.txt v1.1, schema: README.txt.
-- One file for both contexts: the server half records fights, the client half reads the combat log panel.
-- Writes to the Script Extender data folder, in its own namespace (never the baseline's FightRec/ files):
--   FightRec2/<session>-server-fight<NN>-p<NNNNN>.jsonl  numbered, independently readable parts per fight
--   FightRec2/<session>-server-session-p<NNNNN>.jsonl    lifecycle/capability records of this Lua state
--   FightRec2/<session>-client-combatlog-p<NNNNN>.jsonl  combat log panel entries (auxiliary)
--   FightRec2/<session>-<ctx>-<stream>-manifest.json      written once when a stream completes normally
-- API declarations relied on are pinned in docs/API-PINS.txt (Norbyte/bg3se af85fd2, the cached v33 build).
-- That pin is a declaration reference, NOT proof of the loaded runtime: every engine read stays guarded.

local VERSION = "2.0.0-dev.3"
local SCHEMA = 2
local SOURCE_CONTENT_SHA256 = "8ec6f5c36bc6d3b468a444e0a83069985b9eb7262be165aa0da6ea09460e6e3e" -- FR2-BUILD-STAMP (tools/stamp_build.py: sha256 of the UNSTAMPED source)
local DECLARATION_PIN = "Norbyte/bg3se@af85fd2bd2be28646539060d45df487f4d3314b9 (cached v33 Version.txt); " ..
    "declarations only, loaded runtime unverified"

local DEFAULTS = {
    DIR = "FightRec2/",
    FLUSH_MS = 2000,             -- rewrite (or append to) a dirty active part at most this often
    PART_TARGET_BYTES = 262144,  -- C: seal a part before it would exceed this; never truncates a record
    RECORD_HARD_MAX = 4194304,   -- an encoded record larger than this becomes an explicit record_too_large error
    Q_MAX_RECORDS = 20000,       -- admitted-but-undrained records (reservations included)
    Q_MAX_BYTES = 8388608,       -- ... and their bytes (a reservation counts RESERVE_BYTES)
    Q_HIGH_WATER = 0.75,         -- fraction of either limit: optional capture is suspended above it
    Q_LOW_WATER = 0.5,           -- ... and resumed below it
    RESERVE_BYTES = 1600,        -- >= the largest minimal terminal record, so a terminal error never grows the queue
    MAX_NEST = 16,               -- nested captures deeper than this are refused (counted as loss)
    RETRY_MIN_MS = 500,
    RETRY_MAX_MS = 16000,
    FINISH_TIMEOUT_MS = 30000,   -- pending reservations of a finishing stream become explicit errors after this
    FINISH_GIVEUP_MS = 300000,   -- a finishing stream whose writes keep failing is abandoned (counted, warned)
    PARTS_INDEX_MAX = 128,       -- sealed-part summaries kept in memory/manifest (older ones counted, not kept)
    PREP_KEEP = 300,             -- party observations kept from outside combat ...
    PREP_MS = 600000,            -- ... if at most this old when the next fight starts
    CHECKPOINT_ON_TURN = true,   -- small dynamic checkpoint of the actor at TurnStarted/TurnEnded
    CHECKPOINT_ON_ACTION = true, -- ... of caster/target right after CastedSpell/UsingSpellOnTarget
    CHECKPOINT_RESOURCES = true, -- include ActionResources in small checkpoints
    CHECKPOINT_DELTA = true,
    CHECKPOINT_STATUS_TURNS = true, -- one Osi.GetStatusTurns call per status per sampled actor     -- non-anchor checkpoints carry only fields changed since the actor's base_seq sample
    DIRTY_QUIET_MS = 400,        -- deferred checkpoint of actors named by events, after this much quiet ...
    DIRTY_MAX_MS = 2000,         -- ... or at most this long after the first mark
    RECONCILE_MS = 6000,         -- periodic deferred reconciliation of every fight participant (0 = off)
    CHECKPOINT_MAX_ACTORS = 4,   -- deferred checkpoint actors sampled per Tick
    MOVEMENT_ENABLED = false,    -- optional position polling; off until its live cost is measured
    MOVE_POLL_MS = 250,
    MOVE_MIN_M = 0.25,
    WRITE_MODE = "savefile",     -- "append" is used only with APPEND_SEMANTICS_VERIFIED and a passing self-test
    APPEND_SEMANTICS_VERIFIED = false,
    CHECKSUM = "none",           -- "fnv1a32": per-part checksum of record lines (costs Lua time per byte)
    EXPERIMENTAL_FUNCTORS = false, -- ExecuteFunctor/AfterExecuteFunctor diagnostics; never on by default
    DAMAGE_REFLECT = true,       -- bounded reflection of Hit/Attack in damage events (the legacy raw view)
    REFLECT_BUDGET = 3000,       -- engine members visited per reflected value (enumeration stops at the budget)
    REFLECT_USE_SERIALIZE = true, -- try Ext.Types.Serialize first (as the baseline did); its C++ work is unbudgeted
    DUMP_MAX = 50000,
    LOG_POLL_MS = 500,           -- client: delay after a poll COMPLETES before the next is scheduled
    MAX_PER_POLL = 2,
    DEFER_STALL_MS = 10000,      -- a deferred poll not run after this is reported; after 3x it is abandoned
    DEFER_FAIL_LIMIT = 3,        -- consecutive Ext.UI.Defer failures before UI capture is marked unsupported
    SEARCH_BUDGET = 40000,
    ENTRY_DEPTH = 8,
    ENTRY_BUDGET = 6000,
    PROFILE = false,             -- per-kind callback time via Ext.Timer.MicrosecTime
}

------------------------------------------------------------------------
-- Generation ownership (DESIGN 9 DR-01)
------------------------------------------------------------------------

local function warn(msg)
    pcall(function() Ext.Utils.PrintWarning("[FightRec2] " .. msg) end)
end
local function say(msg)
    pcall(function() Ext.Utils.Print("[FightRec2] " .. msg) end)
end

local function fnv1a32(s, h)
    h = h or 2166136261
    for i = 1, #s, 64 do
        local bytes = { s:byte(i, math.min(i + 63, #s)) }
        for j = 1, #bytes do h = ((h ~ bytes[j]) * 16777619) & 0xffffffff end
    end
    return h
end

local function mergeConfig(over)
    local cfg, unknown = {}, {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    if type(over) == "table" then
        for k, v in pairs(over) do
            if DEFAULTS[k] == nil then unknown[#unknown + 1] = tostring(k)
            elseif type(v) == type(DEFAULTS[k]) then cfg[k] = v
            else unknown[#unknown + 1] = tostring(k) .. "(type)" end
        end
    end
    table.sort(unknown)
    return cfg, unknown
end

local function configFingerprint(cfg)
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(cfg[k]) end
    return string.format("%08x", fnv1a32(table.concat(parts, ";")))
end

local CFG, CFG_UNKNOWN = mergeConfig(FightRecV2Config)
local IDENTITY = VERSION .. "|" .. (SOURCE_CONTENT_SHA256 or "unknown") .. "|" .. configFingerprint(CFG)

local refusal
if type(Ext) ~= "table" or type(Ext.IsServer) ~= "function" then
    refusal = "no Script Extender Ext.IsServer"
elseif type(FightRec) == "table" and FightRec.registered then
    -- The baseline registers Osiris listeners that cannot be detached through a verified API: its callbacks
    -- would keep running beside v2 and write under the same session. Refuse rather than relabel them.
    refusal = "baseline FightRec callbacks are registered in this Lua state; start v2 in a fresh Lua state " ..
        "(reset/reload without the baseline)"
elseif type(FightRecV2) == "table" and FightRecV2.identity ~= nil then
    local prev = FightRecV2
    if prev.identity == IDENTITY and prev.generation and prev.generation.active then
        -- Same claimed build and config: the running generation continues; nothing new is registered. With an
        -- unknown source identity "same" cannot be verified, so this is recorded as unverified, not as same.
        prev.reexecuted(IDENTITY, SOURCE_CONTENT_SHA256 ~= nil)
        if not SOURCE_CONTENT_SHA256 then
            FightRecV2Refusal = { identity = IDENTITY, reason = "source identity unknown: cannot verify this is the " ..
                "running build; the running generation continues unchanged" }
        end
        do return end
    end
    refusal = "a different FightRec v2 generation (" .. tostring(prev.identity) .. ") owns this Lua state; " ..
        "its subscriptions cannot be retired through a verified API, so a lifecycle reset is required"
    pcall(prev.refused, IDENTITY, refusal)
end
if refusal then
    warn("not activated: " .. refusal)
    FightRecV2Refusal = { identity = IDENTITY, reason = refusal }
    do return end
end

local monotonic = (Ext.Timer and Ext.Timer.MonotonicTime) or (Ext.Utils and Ext.Utils.MonotonicTime)
if type(monotonic) ~= "function" and not (type(monotonic) == "table" or type(monotonic) == "userdata") then
    warn("not activated: no monotonic clock (Ext.Timer.MonotonicTime)")
    FightRecV2Refusal = { identity = IDENTITY, reason = "no monotonic clock" }
    do return end
end
local function now() return math.floor(monotonic()) end
local microsec = Ext.Timer and Ext.Timer.MicrosecTime
local rt

local IS_SERVER = Ext.IsServer() and true or false
local CTX = IS_SERVER and "server" or "client"

rt = {
    identity = IDENTITY, version = VERSION, schema = SCHEMA, cfg = CFG, context = CTX,
    source_content_sha256 = SOURCE_CONTENT_SHA256 or "unknown",
    obs = 0, depth = 0, streams = {}, hooks = {}, hookErrors = {}, profile = {},
    lifecycleEvents = {}, refusals = 0, reexecutions = 0,
}
rt.prof = CFG.PROFILE and microsec ~= nil
-- IR-05: a stamp is a build-time CLAIM about the unstamped source bytes; the running artifact's own hash is not
-- computable here. Verify offline with tools/stamp_build.py --verify <deployed file>.
rt.source_identity = { content_sha256 = SOURCE_CONTENT_SHA256 or "unknown",
    status = SOURCE_CONTENT_SHA256 and "claimed_by_build_stamp_unverified_at_runtime" or "unknown",
    artifact_sha256 = "not computable at runtime; record it externally (tools/stamp_build.py prints it)" }
rt.generation = { identity = IDENTITY, active = true, subs = {}, osiris = 0, retired = false,
    inactive_calls = 0, osiris_unsubscribe_verified = false }

local function epoch()
    local ok, t = pcall(function() return Ext.Timer.ClockEpoch() end)
    return ok and t or nil
end

do -- a session identity that survives same-second reloads (IR-06: full GUID, no shared RNG reseeding)
    local ok, g = pcall(function() return Ext.Utils.GenerateGuid() end)
    local tag = ok and type(g) == "string" and (g:gsub("[^%x]", "")) or nil
    if tag and #tag >= 32 then
        rt.session_id_source = "Ext.Utils.GenerateGuid"
    else
        -- fallback: clock + a fresh table address of this Lua state; collision-checked below before any write
        tag = string.format("f%x%s", now(), (tostring({}):gsub("[^%x]", "")))
        rt.session_id_source = "fallback (monotonic ms + table address), collision-checked"
    end
    rt.session_id = tostring(epoch() or now()) .. "-" .. tag
end

-- Never overwrite an earlier session's files: probe the first part path before any write.
local function exists(path)
    local ok, s = pcall(function() return Ext.IO.LoadFile(path) end)
    if not ok then return nil end
    return s ~= nil
end
do
    local base, n = rt.session_id, 1
    while true do
        local e = exists(CFG.DIR .. rt.session_id .. "-" .. CTX .. "-session-p00001.jsonl")
        if e == false then rt.collision_check = "checked" break end
        if e == nil then
            rt.collision_check = "unavailable (LoadFile missing or failing)"
            if rt.session_id_source ~= "Ext.Utils.GenerateGuid" then
                warn("not activated: no GUID and no LoadFile to rule out overwriting an earlier session")
                FightRecV2Refusal = { identity = IDENTITY, reason = "session identity not provably unique" }
                rt = nil
            end
            break
        end
        n = n + 1
        if n > 9 then
            warn("not activated: session id collisions persist (" .. base .. ")")
            FightRecV2Refusal = { identity = IDENTITY, reason = "session id collision" }
            rt = nil
            break
        end
        rt.session_id = base .. "-" .. n
        rt.collision_retries = n - 1
    end
end
if not rt then do return end end
rt.generation.id = rt.session_id .. "/" .. CTX

------------------------------------------------------------------------
-- Encoding
------------------------------------------------------------------------

local STRINGIFY_OPTS = { Beautify = false, StringifyInternalTypes = true, AvoidRecursion = true }
local function encode(x) return Ext.Json.Stringify(x, STRINGIFY_OPTS) end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jstr(s, max)
    s = tostring(s)
    max = max or 160
    if #s > max then s = s:sub(1, max):gsub("[\192-\255][\128-\191]*$", "") end
    return '"' .. (s:gsub('[\0-\31"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end)) .. '"'
end

-- A terminal record that needs no engine call: used when a reserved seq cannot be completed normally.
local function int(x) return type(x) == "number" and (math.tointeger(x) or math.floor(x)) or -1 end
-- Bounded: what <= 40, kind <= 64, err <= 160 input bytes (x6 when every byte is escaped) => < MINIMAL_MAX.
local MINIMAL_MAX = 1600
local function minimalError(seq, t, obs, kind, what, err, class)
    return string.format('{"seq":%d,"t":%d,"obs":%d,"kind":"terminal_error","data":{"what":%s,"for_kind":%s,' ..
        '"class":%s,"error":%s}}', int(seq), int(t), int(obs), jstr(what, 40), jstr(kind, 64),
        jstr(class or "required", 10), jstr(err, 160))
end
if CFG.RESERVE_BYTES < MINIMAL_MAX then CFG.RESERVE_BYTES = MINIMAL_MAX end

local function errh(e) return tostring(e) end

-- An engine value as owned plain data: never keeps userdata, never calls into it after returning.
local function scalar(v)
    local tv = type(v)
    if tv == "nil" or tv == "number" or tv == "string" or tv == "boolean" then return v end
    local ok, label = pcall(function() return v.Label end)
    if ok and label ~= nil and type(label) ~= "userdata" then return tostring(label) end
    local okt, s = pcall(tostring, v)
    return okt and s or "<unconvertible>"
end

------------------------------------------------------------------------
-- Streams: bounded queue of terminal reservations -> numbered parts (DESIGN 4, 9 DR-02)
------------------------------------------------------------------------

local Stream = {}
Stream.__index = Stream

local function newStream(name, info)
    local s = setmetatable({
        name = name, info = info or {},
        prefix = CFG.DIR .. rt.session_id .. "-" .. CTX .. "-" .. name,
        nextSeq = 1, drainSeq = 1, slots = {}, qRecords = 0, qBytes = 0,
        partN = 0, part = nil, parts = {}, partsDropped = 0,
        state = "open", capture = "ok", degraded = false, writeMode = rt.writeMode, retryAt = 0, lastWrite = -1e15, backoff = 0,
        c = { admitted = 0, lost_required = 0, lost_optional = 0, suppressed_optional = 0, terminal_errors = 0,
            emergency = 0, write_attempts = 0, write_false = 0, write_throw = 0, write_ok = 0, bytes_requested = 0,
            bytes_acked = 0, max_q_records = 0, max_q_bytes = 0, max_age_ms = 0, late_after_end = 0,
            oversized_parts = 0, append_recoveries = 0, abandoned_reservations = 0, refused_after_complete = 0,
            degradations = 0 },
        pendingLoss = nil, warnedLoss = false, failing = false, degradeLog = {},
    }, Stream)
    -- Never overwrite an existing first part (IR-06): try the base prefix and -c2..-c9; if every candidate is
    -- taken the stream is unwritable and refuses all observations (counted as loss, warned), writing nothing.
    local base = s.prefix
    for k = 1, 10 do
        if k == 10 then
            s.state, s.capture, s.unwritable = "abandoned", "failed", "file namespace exhausted at " .. base
            warn(name .. ": every candidate file name already exists (" .. base .. "[-c2..-c9]); stream not written")
            break
        end
        if k > 1 then s.prefix, s.collisionSuffix = base .. "-c" .. k, "-c" .. k end
        if not exists(string.format("%s-p%05d.jsonl", s.prefix, 1)) then break end
    end
    if s.collisionSuffix and not s.unwritable then
        warn(name .. ": existing files at " .. base .. "; writing to " .. s.prefix)
    end
    rt.streams[#rt.streams + 1] = s
    return s
end

rt.newStream = newStream -- internal: offline writer-only benchmark (bench/bench.lua); not a console API

function Stream:indexPart(entry)
    self.parts[#self.parts + 1] = entry
    if #self.parts > CFG.PARTS_INDEX_MAX then
        table.remove(self.parts, 1)
        self.partsDropped = self.partsDropped + 1
    end
end

function Stream:limits()
    return CFG.Q_MAX_RECORDS, CFG.Q_MAX_BYTES
end

function Stream:updateDegrade(t)
    local maxR, maxB = self:limits()
    local fill = math.max(self.qRecords / maxR, self.qBytes / maxB)
    if not self.degraded and fill > CFG.Q_HIGH_WATER then
        self.degraded = { from = t, reason = "queue_high_water", suppressed = 0 }
        self.c.degradations = self.c.degradations + 1
    elseif self.degraded and fill < CFG.Q_LOW_WATER then
        local d = self.degraded
        self.degraded = false
        if #self.degradeLog < 32 then
            self.degradeLog[#self.degradeLog + 1] = { from = d.from, to = t, reason = d.reason, suppressed = d.suppressed }
        end
        self.pendingDegradeReport = true
    end
end

function Stream:noteLoss(class, t, obs, kind, reason)
    if class == "optional" then
        self.c.lost_optional = self.c.lost_optional + 1
    else
        self.c.lost_required = self.c.lost_required + 1
        if self.capture == "ok" or self.capture == "degraded" then self.capture = "incomplete" end
    end
    local L = self.pendingLoss
    if not L then
        L = { first_t = t, first_obs = obs, required = 0, optional = 0, by_kind = {}, kinds = 0, other = 0, reasons = {} }
        self.pendingLoss = L
    end
    L.last_t, L.last_obs = t, obs
    L[class == "optional" and "optional" or "required"] = L[class == "optional" and "optional" or "required"] + 1
    L.reasons[reason] = (L.reasons[reason] or 0) + 1
    kind = tostring(kind)
    if L.by_kind[kind] then L.by_kind[kind] = L.by_kind[kind] + 1
    elseif L.kinds < 24 then L.by_kind[kind] = 1 L.kinds = L.kinds + 1
    else L.other = L.other + 1 end
    if class ~= "optional" and not self.warnedLoss then
        self.warnedLoss = true
        warn(self.name .. ": required observations lost (" .. reason .. "); capture is INCOMPLETE")
    end
end

-- Admission happens before a seq exists: a refused observation has no seq and is counted as loss.
function Stream:admit(class, t, obs, kind)
    if self.unwritable then
        self:noteLoss(class, t, obs, kind, "stream_unwritable")
        return nil
    end
    if self.state == "complete" or self.state == "abandoned" then
        self.c.refused_after_complete = self.c.refused_after_complete + 1
        return nil
    end
    self:updateDegrade(t)
    if class == "optional" and self.degraded then
        self.c.suppressed_optional = self.c.suppressed_optional + 1
        self.degraded.suppressed = self.degraded.suppressed + 1
        return nil
    end
    local maxR, maxB = self:limits()
    if self.qRecords + 1 > maxR or self.qBytes + CFG.RESERVE_BYTES > maxB then
        self:noteLoss(class, t, obs, kind, "queue_full")
        return nil
    end
    local seq = self.nextSeq
    self.nextSeq = seq + 1
    self.slots[seq] = { t = t, obs = obs, kind = kind, class = class, bytes = CFG.RESERVE_BYTES }
    self.qRecords, self.qBytes = self.qRecords + 1, self.qBytes + CFG.RESERVE_BYTES
    if self.qRecords > self.c.max_q_records then self.c.max_q_records = self.qRecords end
    if self.qBytes > self.c.max_q_bytes then self.c.max_q_bytes = self.qBytes end
    self.c.admitted = self.c.admitted + 1
    if self.state == "finishing" and self.endSeq then self.c.late_after_end = self.c.late_after_end + 1 end
    return seq
end

function Stream:setLine(seq, line)
    local slot = self.slots[seq]
    if not slot or slot.line ~= nil then return false end
    local len = line and #line or 0
    slot.line = line
    self.qBytes = self.qBytes - slot.bytes + len
    slot.bytes = len
    if self.qBytes > self.c.max_q_bytes then self.c.max_q_bytes = self.qBytes end
    return true
end

-- The single terminal transition for a reserved seq that could not become its owned record.
function Stream:failSlot(seq, t, obs, kind, what, err)
    local slot = self.slots[seq]
    local class = slot and slot.class or "required"
    self.c.terminal_errors = self.c.terminal_errors + 1
    self.lastTerminalErr = seq
    -- IR-02: a required payload replaced by an error makes the capture incomplete; optional ones are counted.
    if class == "optional" then
        self.c.terminal_errors_optional = (self.c.terminal_errors_optional or 0) + 1
    elseif self.capture == "ok" then
        self.capture = "incomplete"
    end
    local ok, line = pcall(minimalError, seq, t, obs, kind, what, err, class)
    if not ok or type(line) ~= "string" then
        line = false
        self.c.emergency = self.c.emergency + 1
        self.capture = "failed"
        warn(self.name .. ": cannot encode even a minimal terminal record for seq " .. tostring(seq))
    end
    self:setLine(seq, line)
end

function Stream:commit(seq, t, obs, kind, phase, data, flags)
    local rec = { seq = seq, t = t, obs = obs, kind = kind, phase = phase, data = data }
    if flags then for k, v in pairs(flags) do rec[k] = v end end
    if self.endSeq and seq > self.endSeq then rec.late_after_end = true end
    local ok, line = pcall(encode, rec)
    if ok and type(line) ~= "string" then ok, line = false, "Stringify returned " .. type(line) end
    local what = "encode_error"
    if ok and #line > CFG.RECORD_HARD_MAX then
        ok, line = false, "record_too_large: " .. #line .. " bytes > RECORD_HARD_MAX " .. CFG.RECORD_HARD_MAX
    end
    -- IR-01: completing a reservation may not push retained queue bytes past Q_MAX_BYTES + RECORD_HARD_MAX.
    local slot = self.slots[seq]
    if ok and slot and self.qBytes - slot.bytes + #line > CFG.Q_MAX_BYTES + CFG.RECORD_HARD_MAX then
        what, ok, line = "queue_bytes_exceeded", false, "record of " .. #line .. " bytes would exceed the queue bound"
    end
    if not ok then return self:failSlot(seq, t, obs, kind, what, line) end
    self:setLine(seq, line)
end

-- A complete owned record emitted by the recorder itself (stats, reports): admit + commit at once.
function Stream:emit(class, kind, data, t, flags)
    t = t or now()
    rt.obs = rt.obs + 1
    local seq = self:admit(class, t, rt.obs, kind)
    if not seq then return nil end
    self:commit(seq, t, rt.obs, kind, "recorder", data, flags)
    return seq
end

local function writeCall(fnName, path, content)
    local fn = Ext.IO and Ext.IO[fnName]
    local ok, ret = pcall(fn, path, content)
    if not ok then return false, "throw", tostring(ret) end
    -- Pinned IO.inl: SaveFile/AppendFile return bool. Anything but true is not an acknowledgement.
    if ret ~= true then return false, "false", "returned " .. tostring(ret) end
    return true
end

function Stream:header(p)
    local h = { kind = "part_header", schema_version = SCHEMA, recorder_version = VERSION,
        source_content_sha256 = rt.source_content_sha256, generation = rt.generation.id, session_id = rt.session_id, context = CTX,
        stream_id = self.name, part = p.n, first_seq = p.firstSeq, write_mode = self.writeMode, created_t = p.created,
        clock = rt.clock, combat_id = self.info.combat_id, fight = self.info.fight,
        file_prefix_suffix = self.collisionSuffix }
    if p.extra then for k, v in pairs(p.extra) do h[k] = v end end
    local ok, line = pcall(encode, h)
    if ok and type(line) == "string" then return line end
    return string.format('{"kind":"part_header","schema_version":%d,"session_id":%s,"context":%s,"stream_id":%s,' ..
        '"part":%d,"first_seq":%d,"header_error":%s}', SCHEMA, jstr(rt.session_id), jstr(CTX), jstr(self.name), p.n,
        p.firstSeq, jstr(line))
end

-- Every new part path is checked before its first write (IR-06 round 3): an existing file (e.g. an orphan later
-- part of an earlier session) is never overwritten; the stream fails explicitly instead. This is a check-then-
-- write by a single writer, not an exclusive create: a concurrent external writer could still race it.
function Stream:openPart(t, extra)
    local path = string.format("%s-p%05d.jsonl", self.prefix, self.partN + 1)
    if exists(path) then
        self.unwritable = "part path already exists: " .. path
        self:abandon(t, "existing file at " .. path .. " was not overwritten")
        return nil
    end
    self.partN = self.partN + 1
    local p = { n = self.partN, firstSeq = self.drainSeq, lines = {}, seqs = {}, count = 0, bytes = 0, dirty = true,
        committed = 0, onDisk = false, created = t, extra = extra, path = path }
    if CFG.CHECKSUM == "fnv1a32" then p.ck = 2166136261 end
    p.headerLine = self:header(p)
    self.part = p
    return p
end

-- Reuse an empty, never-written active part so part numbers stay contiguous.
function Stream:freshPart(t, extra)
    local p = self.part
    if p and p.count == 0 and not p.onDisk then
        p.extra = extra
        p.headerLine = self:header(p)
        return p
    end
    return self:openPart(t, extra)
end

function Stream:appendLine(p, seq, line)
    p.count = p.count + 1
    p.lines[p.count], p.seqs[p.count] = line, seq
    p.bytes = p.bytes + #line + 1
    p.lastSeq = seq
    p.dirty = true
    if p.ck then p.ck = fnv1a32(line .. "\n", p.ck) end
end

function Stream:trailer(p)
    local tr = { kind = "part_trailer", part = p.n, first_seq = p.count > 0 and p.seqs[1] or nil,
        last_seq = p.lastSeq, count = p.count, record_bytes = p.bytes, final = p.final or false,
        checksum = p.ck and { alg = "fnv1a32", value = string.format("%08x", p.ck), over = "record lines incl. LF" } or nil }
    if p.final then
        tr.end_reason, tr.capture, tr.stream_last_seq = self.endReason, self.capture, self.nextSeq - 1
        tr.counters = self.c
    end
    local ok, line = pcall(encode, tr)
    if ok and type(line) == "string" then return line end
    return string.format('{"kind":"part_trailer","part":%d,"last_seq":%d,"count":%d,"record_bytes":%d,"final":%s,"trailer_error":%s}',
        p.n, p.lastSeq or -1, p.count, p.bytes, tostring(p.final or false), jstr(line))
end

local function joinLines(p, from, to)
    if to < from then return "" end
    return table.concat(p.lines, "\n", from, to) .. "\n"
end

function Stream:noteWrite(t, ok, why, err, n)
    self.c.write_attempts = self.c.write_attempts + 1
    self.c.bytes_requested = self.c.bytes_requested + n
    if ok then
        self.c.write_ok = self.c.write_ok + 1
        self.c.bytes_acked = self.c.bytes_acked + n
        self.lastWrite, self.backoff, self.retryAt = t, 0, 0
        if self.failing then
            self.failing.recovered_t = t
            self.pendingRecovery, self.failing = self.failing, false
        end
    else
        if why == "throw" then self.c.write_throw = self.c.write_throw + 1 else self.c.write_false = self.c.write_false + 1 end
        self.backoff = math.min(CFG.RETRY_MAX_MS, math.max(CFG.RETRY_MIN_MS, self.backoff * 2))
        self.retryAt = t + self.backoff
        if not self.failing then
            self.failing = { first_t = t, failures = 0 }
            warn("cannot write " .. tostring(self.part and self.part.path) .. ": " .. tostring(err) .. " (retained for retry)")
        end
        self.failing.failures, self.failing.last_t, self.failing.last_error = self.failing.failures + 1, t, tostring(err)
    end
end

-- Write the active part (rewrite in savefile mode, the uncommitted tail in append mode). Acknowledged only on true.
function Stream:writePart(t, seal)
    local p = self.part
    local tail = seal and (self:trailer(p) .. "\n") or ""
    if self.writeMode == "append" and p.onDisk then
        local batch = joinLines(p, p.committed + 1, p.count) .. tail
        local ok, why, err = writeCall("AppendFile", p.path, batch)
        self:noteWrite(t, ok, why, err, #batch)
        if not ok then
            local outcome = self:appendRecover(p, batch, t)
            if outcome ~= "applied" then return false end
        end
    else
        local content = p.headerLine .. "\n" .. joinLines(p, 1, p.count) .. tail
        local ok, why, err = writeCall("SaveFile", p.path, content)
        self:noteWrite(t, ok, why, err, #content)
        if not ok then return false end
    end
    p.onDisk, p.committed, p.dirty = true, p.count, false
    return true
end

-- Append failed (false or throw): it may have written nothing, everything or a prefix. Never blindly re-append.
function Stream:appendRecover(p, batch, t)
    local expected = p.headerLine .. "\n" .. joinLines(p, 1, p.committed)
    local okL, disk = pcall(function() return Ext.IO.LoadFile(p.path) end)
    if okL and type(disk) == "string" then
        if disk == expected then return "retry_safe" end
        if disk == expected .. batch then
            self.c.append_recoveries = self.c.append_recoveries + 1
            return "applied"
        end
    end
    -- Ambiguous: abandon this part and re-emit its uncommitted records into a recovery part.
    self.c.append_recoveries = self.c.append_recoveries + 1
    self.capture = self.capture == "failed" and "failed" or "incomplete"
    self:indexPart({ part = p.n, first_seq = p.seqs[1], last_seq = p.seqs[p.committed],
        count = p.committed, state = "abandoned_ambiguous_append", path = p.path })
    local old, sealing, final = p, p.sealing, p.final
    local q = self:openPart(t, { recovery_of = old.n, duplicate_uncertain = true })
    if not q then return "abandoned" end
    q.firstSeq = old.seqs[old.committed + 1] or self.drainSeq
    q.headerLine = self:header(q)
    for i = old.committed + 1, old.count do self:appendLine(q, old.seqs[i], old.lines[i]) end
    q.sealing, q.final = sealing, final
    return "rotated"
end

function Stream:seal(t)
    local p = self.part
    p.sealing = true
    if not self:writePart(t, true) then return false end
    if p ~= self.part then return false end -- rotated to a recovery part: seal that one on the next pump
    self:indexPart({ part = p.n, first_seq = p.seqs[1], last_seq = p.lastSeq, count = p.count,
        record_bytes = p.bytes, checksum = p.ck and string.format("%08x", p.ck) or nil, state = "sealed",
        final = p.final or false, path = p.path, oversized = p.extra and p.extra.oversized or nil })
    self.part = nil
    return true
end

function Stream:consume(seq)
    local slot = self.slots[seq]
    self.slots[seq] = nil
    self.qRecords, self.qBytes = self.qRecords - 1, self.qBytes - slot.bytes
    self.drainSeq = seq + 1
end

-- Drain the contiguous terminal prefix into parts, then write if due. Records never leave memory unacknowledged:
-- a part that cannot be sealed stops the drain, and the bounded queue absorbs (then refuses) new observations.
function Stream:pump(t, force)
    if self.state == "complete" or self.state == "abandoned" then return end
    local head = self.slots[self.drainSeq]
    if head and t - head.t > self.c.max_age_ms then self.c.max_age_ms = t - head.t end
    if self.state == "finishing" and t - self.finishAt > CFG.FINISH_GIVEUP_MS then
        return self:abandon(t, "finalization did not complete within FINISH_GIVEUP_MS")
    end
    if self.failing and t < self.retryAt then return end
    if self.part and self.part.sealing and not self:seal(t) then return end
    local C = CFG.PART_TARGET_BYTES
    while true do
        local seq = self.drainSeq
        local slot = self.slots[seq]
        if slot == nil or slot.line == nil then break end
        local line = slot.line
        if line == false then
            self:consume(seq) -- emergency: nothing encodable; trailer/reader see the seq gap and counters
        else
            local len = #line + 1
            local p = self.part
            if len > C then
                if p and p.count > 0 and not self:seal(t) then break end
                p = self:freshPart(t, { oversized = true, record_bytes = #line })
                if not p then break end
                self.c.oversized_parts = self.c.oversized_parts + 1
                self:appendLine(p, seq, line)
                self:consume(seq)
                if not self:seal(t) then break end
            else
                if p and p.count > 0 and p.bytes + len > C then
                    if not self:seal(t) then break end
                    p = nil
                end
                p = p or self.part or self:openPart(t)
                if not p then break end
                self:appendLine(p, seq, line)
                self:consume(seq)
            end
        end
    end
    self:updateDegrade(t)
    self:report(t)
    local p = self.part
    if p and p.dirty and not p.sealing and (force or t - self.lastWrite >= CFG.FLUSH_MS) then self:writePart(t, false) end
    if self.state == "finishing" then self:tryComplete(t) end
end

-- Persistent records of gaps, write recovery and degradation, once there is room again.
function Stream:report(t)
    if math.max(self.qRecords / CFG.Q_MAX_RECORDS, self.qBytes / CFG.Q_MAX_BYTES) > CFG.Q_LOW_WATER then return end
    if self.pendingLoss then
        local L = self.pendingLoss
        self.pendingLoss = nil
        if not self:emit("required", "capture_gap", L, t) then self.pendingLoss = L end
    end
    if self.pendingRecovery then
        local f = self.pendingRecovery
        self.pendingRecovery = nil
        self:emit("required", "write_recovered", f, t)
    end
    if self.pendingDegradeReport then
        self.pendingDegradeReport = nil
        self:emit("required", "degradation", { intervals = self.degradeLog, suppressed_total = self.c.suppressed_optional }, t)
    end
end

function Stream:finish(t, reason)
    if self.state ~= "open" then return end
    self.state, self.finishAt, self.endReason = "finishing", t, reason
    self.endSeq = self.nextSeq - 1
end

function Stream:pending() return self.drainSeq < self.nextSeq end

function Stream:tryComplete(t)
    if self:pending() then
        if t - self.finishAt <= CFG.FINISH_TIMEOUT_MS then return end
        for seq = self.drainSeq, self.nextSeq - 1 do
            local slot = self.slots[seq]
            if slot and slot.line == nil then
                self.c.abandoned_reservations = self.c.abandoned_reservations + 1
                self.capture = self.capture == "failed" and "failed" or "incomplete"
                self:failSlot(seq, slot.t, slot.obs, slot.kind, "reservation_abandoned", "pending at finalization timeout")
            end
        end
        return -- drained on the next pump
    end
    if self.pendingLoss or self.pendingRecovery or self.pendingDegradeReport then return end
    local p = self.part or self:openPart(t)
    if not p then return end
    p.final, p.sealing = true, true
    if not self:seal(t) then return end
    self.state = "complete"
    self.manifest = self:writeManifest(t)
    self.slots = {}
end

function Stream:writeManifest(t)
    local m = { kind = "manifest", schema_version = SCHEMA, recorder_version = VERSION,
        source_content_sha256 = rt.source_content_sha256,
        session_id = rt.session_id, context = CTX, stream_id = self.name, generation = rt.generation.id,
        state = "complete", capture = self.capture, end_reason = self.endReason, last_seq = self.nextSeq - 1,
        parts = self.parts, parts_total = self.partN, parts_index_dropped = self.partsDropped,
        counters = self.c, written_t = t,
        note = "convenience index; readers must reconstruct from numbered parts and never trust this over them" }
    local ok, s = pcall(encode, m)
    if not ok then return "encode_error" end
    local okw = writeCall("SaveFile", self.prefix .. "-manifest.json", s .. "\n")
    if not okw then warn(self.name .. ": manifest not written; the sealed parts remain authoritative") end
    return okw and "written" or "write_failed"
end

function Stream:abandon(t, why)
    self.state = "abandoned"
    self.capture = "failed"
    warn(self.name .. ": abandoned (" .. why .. "); " .. tostring(self.nextSeq - 1) .. " seqs admitted, " ..
        tostring(#self.parts) .. " parts sealed; unacknowledged records are lost")
    self.slots, self.part = {}, nil
    self.qRecords, self.qBytes = 0, 0
end

function Stream:status()
    return { name = self.name, state = self.state, capture = self.capture, next_seq = self.nextSeq,
        drain_seq = self.drainSeq, q_records = self.qRecords, q_bytes = self.qBytes, parts = #self.parts,
        degraded = self.degraded and true or false, counters = self.c }
end

------------------------------------------------------------------------
-- Capture wrapper (DESIGN 3, 9 DR-02/DR-03)
------------------------------------------------------------------------

local function nextObs()
    rt.obs = rt.obs + 1
    return rt.obs
end

-- Admission before the seq exists; exactly one terminal state per seq; nested captures keep entry order.
local function capture(stream, class, kind, phase, t, obs, flags, builder, ...)
    if rt.depth >= CFG.MAX_NEST then
        stream:noteLoss(class, t, obs, kind, "nesting_limit")
        return nil
    end
    local seq = stream:admit(class, t, obs, kind)
    if not seq then return nil end
    rt.depth = rt.depth + 1
    local t0 = rt.prof and microsec()
    local ok, data = xpcall(builder, errh, ...)
    rt.depth = rt.depth - 1
    if ok then
        local okc, errc = pcall(stream.commit, stream, seq, t, obs, kind, phase, data, flags)
        if not okc and stream.slots[seq] and stream.slots[seq].line == nil then
            stream:failSlot(seq, t, obs, kind, "commit_error", errc)
        end
    else
        stream:failSlot(seq, t, obs, kind, "builder_error", data)
    end
    if t0 then
        local okp, dt = pcall(function() return microsec() - t0 end)
        if okp then
            local pr = rt.profile[kind] or { n = 0, total_us = 0, max_us = 0 }
            rt.profile[kind] = pr
            pr.n, pr.total_us = pr.n + 1, pr.total_us + dt
            if dt > pr.max_us then pr.max_us = dt end
        end
    end
    return ok and data or nil, seq
end
rt.capture = capture

local function pumpAll(force)
    local t = now()
    local keep = {}
    for _, s in ipairs(rt.streams) do
        local ok, err = pcall(s.pump, s, t, force)
        if not ok then warn(s.name .. ": pump error " .. tostring(err)) end
        if s.state ~= "complete" and s.state ~= "abandoned" then keep[#keep + 1] = s
        else rt.closed = (rt.closed or 0) + 1 end
    end
    rt.streams = keep
end
rt.pumpAll = pumpAll

local function anyDegraded()
    for _, s in ipairs(rt.streams) do if s.degraded then return true end end
    return false
end

------------------------------------------------------------------------
-- Capabilities, hooks, lifecycle
------------------------------------------------------------------------

rt.clock = { unit = "ms", domain = (Ext.Timer and Ext.Timer.MonotonicTime) and "Ext.Timer.MonotonicTime (steady_clock)"
    or "Ext.Utils.MonotonicTime", wall_clock_sync = "not asserted across contexts" }

local function present(f) local tf = type(f) return tf == "function" or tf == "table" or tf == "userdata" end

local function capabilities()
    local io = Ext.IO or {}
    local caps = { declaration_pin = DECLARATION_PIN,
        SaveFile = present(io.SaveFile), AppendFile = present(io.AppendFile), LoadFile = present(io.LoadFile),
        GenerateGuid = present(Ext.Utils and Ext.Utils.GenerateGuid), MicrosecTime = present(microsec),
        session_id_source = rt.session_id_source, collision_check = rt.collision_check,
        collision_retries = rt.collision_retries }
    if IS_SERVER then
        caps.Osiris_RegisterListener = present(Ext.Osiris and Ext.Osiris.RegisterListener)
        caps.Osiris_UnregisterListener = present(Ext.Osiris and Ext.Osiris.UnregisterListener)
        caps.Osiris_UnregisterListener_used = false
    else
        caps.UI_Defer = present(Ext.UI and Ext.UI.Defer)
        caps.UI_GetRoot = present(Ext.UI and Ext.UI.GetRoot)
    end
    caps.write_mode, caps.write_mode_reason = rt.writeMode, rt.writeModeReason
    return caps
end

do -- write mode: append only when requested, attested by a live test, present and passing a self-test
    rt.writeMode, rt.writeModeReason = "savefile", "default: SaveFile rewrites only the active part"
    if CFG.WRITE_MODE == "append" then
        if not CFG.APPEND_SEMANTICS_VERIFIED then
            rt.writeModeReason = "append requested but APPEND_SEMANTICS_VERIFIED is false (needs authorized live test)"
        elseif not (Ext.IO and present(Ext.IO.AppendFile) and present(Ext.IO.LoadFile)) then
            rt.writeModeReason = "append requested but Ext.IO.AppendFile/LoadFile unavailable"
        else
            local path = CFG.DIR .. rt.session_id .. "-" .. CTX .. "-appendprobe.txt"
            local ok1 = writeCall("SaveFile", path, "a\n")
            local ok2 = ok1 and writeCall("AppendFile", path, "b\n")
            local okL, back = pcall(function() return Ext.IO.LoadFile(path) end)
            if ok1 and ok2 and okL and back == "a\nb\n" then
                rt.writeMode, rt.writeModeReason = "append", "append self-test passed on this runtime: " .. path
            else
                rt.writeModeReason = "append self-test failed (" .. tostring(ok1) .. "," .. tostring(ok2) .. "," ..
                    tostring(okL and back == "a\nb\n") .. "); SaveFile fallback"
            end
        end
    end
end

local function versions()
    local okg, game = pcall(function() return Ext.Utils.GameVersion() end)
    local oks, se = pcall(function() return Ext.Utils.Version() end)
    return { game_raw = okg and game or nil, game_error = not okg and tostring(game) or nil,
        se_raw = oks and se or nil, se_status = oks and se ~= nil and "reported by Ext.Utils.Version" or "unavailable" }
end

rt.session = newStream("session", {})

local function lifecycle(kind, data)
    data = data or {}
    if #rt.lifecycleEvents < 64 then rt.lifecycleEvents[#rt.lifecycleEvents + 1] = { kind = kind, t = now() } end
    local okc = rt.session and rt.session:emit("required", kind, data)
    return okc
end
rt.lifecycle = lifecycle

-- Called by a later execution of this file in the same Lua state.
rt.reexecuted = function(identity, claimedSame)
    rt.reexecutions = rt.reexecutions + 1
    lifecycle(claimedSame and "reexecuted_same_generation" or "reexecution_unverified", { identity = identity,
        n = rt.reexecutions, source_identity = rt.source_identity,
        note = claimedSame and "same claimed source hash and config; running generation continues" or
            "source identity unknown: the executed file may differ; it was NOT activated, the running " ..
            "generation continues unchanged" })
    say("already active (generation " .. rt.generation.id .. "); re-execution ignored")
end
rt.refused = function(identity, reason)
    rt.refusals = rt.refusals + 1
    lifecycle("replacement_refused", { identity = identity, reason = reason, n = rt.refusals })
end

local function hookError(name, err)
    local h = rt.hookErrors[name] or { n = 0 }
    rt.hookErrors[name] = h
    h.n = h.n + 1
    if h.n <= 20 then
        warn(name .. ": " .. tostring(err))
        lifecycle("hook_error", { hook = name, error = tostring(err), n = h.n })
    end
end

-- Every callback is gated on its generation; a stopped generation's callbacks become no-ops, except that a
-- draining callback (Tick) keeps retrying pending/backoff/final writes until every stream is closed (IR-04).
local function gated(name, fn, drains)
    local gen = rt.generation
    return function(...)
        if not gen.active then
            if drains and #rt.streams > 0 then
                gen.drain_calls = (gen.drain_calls or 0) + 1
                local ok, err = pcall(pumpAll, false)
                if not ok then hookError(name, err) end
                return
            end
            gen.inactive_calls = gen.inactive_calls + 1
            return
        end
        local ok, err = xpcall(fn, errh, ...)
        if not ok then hookError(name, err) end
    end
end

local function subscribe(evname, fn, optional, drains)
    local okE, ev = pcall(function() return Ext.Events[evname] end)
    local ok, id = false, nil
    if okE and ev ~= nil then
        ok, id = pcall(function() return ev:Subscribe(gated("Ext.Events." .. evname, fn, drains)) end)
    end
    local registered = ok and id ~= nil
    rt.hooks["Ext.Events." .. evname] = { registered = registered, optional = optional or nil,
        error = not registered and (not okE and tostring(ev) or ev == nil and "event table missing" or not ok and tostring(id)
            or "Subscribe returned nil (MissingSubscribableEvent behaviour in pinned EventManager)") or nil }
    if registered then rt.generation.subs[#rt.generation.subs + 1] = { event = evname, id = id } end
    return registered
end

-- Console helpers: FightRecV2.status(), FightRecV2.stop().
rt.status = function()
    local out = { identity = rt.identity, generation = rt.generation.id, active = rt.generation.active, streams = {} }
    for _, s in ipairs(rt.streams) do out.streams[#out.streams + 1] = s:status() end
    return out
end

------------------------------------------------------------------------
-- Server: the fight
------------------------------------------------------------------------
if IS_SERVER then

-- Osiris calls return every result: GetPosition's x, y, z are three returns (baseline kept only the first).
local function osiAll(fn, ...)
    local r = table.pack(pcall(fn, ...))
    if not r[1] then return nil end
    return table.unpack(r, 2, r.n)
end
local function osi1(fn, ...)
    local ok, r = pcall(fn, ...)
    return ok and r or nil
end
rt.osiAll = osiAll

local function position(u)
    local r = table.pack(pcall(Osi.GetPosition, u))
    local x, y, z = r[2], r[3], r[4]
    local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
    if r[1] and num(x) and num(y) and num(z) then
        return { x = x, y = y, z = z, valid = true, src = "Osi.GetPosition", domain = "world" }
    end
    local reason = not r[1] and ("error: " .. tostring(x)) or
        string.format("GetPosition returned %d values (%s,%s,%s)", r.n - 1, type(x), type(y), type(z))
    return { valid = false, src = "Osi.GetPosition", reason = reason }
end
rt.position = position

local function uuid(s)
    if type(s) ~= "string" then return nil end
    local u = s:match("%x+%-%x+%-%x+%-%x+%-%x+$")
    if u == "00000000-0000-0000-0000-000000000000" then return nil end
    return u
end

local names = {}
local function name(u)
    if not u then return nil end
    if names[u] == nil then
        local n = osi1(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
        names[u] = type(n) == "string" and n or false
    end
    return names[u] or nil
end

local function who(x)
    local u = uuid(x)
    if not u then
        if x == nil or tostring(x):find("00000000-0000-0000-0000-000000000000", 1, true) then return nil end
        return tostring(x)
    end
    return { uuid = u, name = name(u) }
end

local function entityUuid(h)
    local ok, u = pcall(function() return h.Uuid.EntityUuid end)
    return ok and type(u) == "string" and u or nil
end

local statNames = {}
local function statName(id)
    if id == nil then return nil end
    id = tostring(id)
    if statNames[id] == nil then
        local n = osi1(function()
            local st = Ext.Stats.Get(id)
            return st and Ext.Loca.GetTranslatedString(st.DisplayName) or nil
        end)
        statNames[id] = type(n) == "string" and n or false
    end
    return statNames[id] or nil
end

local function party()
    local out = {}
    for _, row in ipairs(osi1(function() return Osi.DB_Players:Get(nil) end) or {}) do
        local u = uuid(row[1])
        if u then out[#out + 1] = u end
    end
    return out
end

-- party set + the combats it is in: cached 250 ms, and invalidated on combat/turn/death transitions
local scopeCache, scopeT = nil, -1e15
local function scope()
    local t = now()
    if not scopeCache or t - scopeT > 250 then
        local isParty, combats = {}, {}
        for _, u in ipairs(party()) do
            isParty[u] = true
            local c = osi1(Osi.CombatGetGuidFor, u)
            if type(c) == "string" then combats[c] = true end
        end
        scopeCache, scopeT = { party = isParty, combats = combats }, t
    end
    return scopeCache
end
local function invalidateScope() scopeCache = nil end

local function involvement(...)
    local s = scope()
    local fight = false
    for i = 1, select("#", ...) do
        local u = uuid((select(i, ...)))
        if u then
            if s.party[u] then return "party" end
            local c = osi1(Osi.CombatGetGuidFor, u)
            if c and s.combats[c] then fight = true end
        end
    end
    return fight and "fight" or nil
end

-- Owned keys for reflected tables (LV02). A Lua sequence (integer keys exactly 1..n) keeps integer keys, so the
-- JSON keeps a list as the baseline wrote it (historical hit.ConditionRolls, Damage.DamageRolls.<type>,
-- Result.RollsCount, DamageList); 2.0.0-dev.1/dev.2 stringified every key and turned them into {"1": ...}
-- objects. Any other key set is stringified (mixed keys cannot be encoded). A budget cut inside a sequence
-- appends "<omitted>" so it stays a list; elsewhere it sets _omitted. budget.cut marks the loss either way.
local function ownKeys(entries, omitted)
    local n, seq, seen = #entries, true, {}
    for _, kv in ipairs(entries) do
        local k = kv[1]
        if math.type(k) ~= "integer" or k < 1 or k > n or seen[k] then seq = false break end
        seen[k] = true
    end
    local out = {}
    if seq then
        for _, kv in ipairs(entries) do out[kv[1]] = kv[2] end
        if omitted then out[n + 1] = "<omitted>" end
    else
        for _, kv in ipairs(entries) do out[tostring(kv[1])] = kv[2] end
        if omitted then out._omitted = true end
    end
    return out
end

-- Bounded reflection of an engine value into owned data; cut/budget flags say what is missing.
local function reflect(x, depth, budget)
    budget.n = budget.n - 1
    if budget.n <= 0 then budget.cut = true return "<budget>" end
    local tx = type(x)
    if tx == "table" then
        local entries, omitted = {}, false
        for k, v in pairs(x) do
            if budget.n <= 0 then budget.cut = true omitted = true break end
            budget.n = budget.n - 1
            if depth > 0 then entries[#entries + 1] = { k, reflect(v, depth - 1, budget) }
            else entries[#entries + 1] = { k, scalar(v) } budget.depthCut = true end
        end
        return ownKeys(entries, omitted)
    end
    if tx ~= "userdata" then return x end
    if CFG.REFLECT_USE_SERIALIZE then -- C++ side work is NOT bounded by REFLECT_BUDGET (IR-07)
        local ok, t = pcall(function() return Ext.Types.Serialize(x) end)
        if ok and type(t) == "table" then budget.serialized = true return reflect(t, depth, budget) end
    end
    local okn, tn = pcall(function() return Ext.Types.GetObjectType(x) end)
    tn = okn and tn or nil
    if tn == "Entity" then return who(entityUuid(x)) or scalar(x) end
    local oki, ti = pcall(function() return Ext.Types.GetTypeInfo(tn) end)
    local kind = oki and ti and ti.Kind
    if kind == "Enumeration" or kind == "Bitmask" then
        local okl, label = pcall(function() return x.Label end)
        local okv, value = pcall(function() return x.Value end)
        if okl and label ~= nil then return { label = tostring(label), value = okv and scalar(value) or nil } end
        local okls, labels = pcall(function() return x.Labels end)
        if okls and labels ~= nil then return { labels = reflect(labels, 1, budget), value = okv and scalar(value) or nil } end
        return scalar(x)
    end
    local members = oki and ti and ti.Members
    if members then
        local out = { _type = tn }
        pcall(function()
            for k in pairs(members) do
                if budget.n <= 0 then budget.cut = true out._omitted = true break end
                budget.n = budget.n - 1
                local okv, v = pcall(function() return x[k] end)
                if okv then
                    if depth > 0 then out[tostring(k)] = reflect(v, depth - 1, budget)
                    else out[tostring(k)] = scalar(v) budget.depthCut = true end
                end
            end
        end)
        return out
    end
    local entries, omitted = {}, false
    local okp = pcall(function()
        for k, v in pairs(x) do
            if budget.n <= 0 then budget.cut = true omitted = true break end
            budget.n = budget.n - 1
            entries[#entries + 1] = { k, depth > 0 and reflect(v, depth - 1, budget) or scalar(v) }
        end
    end)
    if okp and (#entries > 0 or omitted) then return ownKeys(entries, omitted) end
    return scalar(x)
end
local function reflected(x, depth)
    if x == nil then return nil end
    local budget = { n = CFG.REFLECT_BUDGET }
    local v = reflect(x, depth, budget)
    if budget.cut or budget.depthCut then
        return { value = v, cut = budget.cut or nil, depth_cut = budget.depthCut or nil,
            serialize_unbudgeted = budget.serialized or nil }
    end
    return v
end
rt.reflect = reflected

local function dump(x, depth)
    local tx = type(x)
    if tx ~= "userdata" and tx ~= "table" then return x end
    local ok, s = pcall(Ext.Json.Stringify, x, { Beautify = false, StringifyInternalTypes = true,
        IterateUserdata = true, AvoidRecursion = true, MaxDepth = depth or 3 })
    if not ok then return { unavailable = true, error = tostring(s) } end
    if #s > CFG.DUMP_MAX then return { truncated = true, bytes = #s, json = s:sub(1, CFG.DUMP_MAX) } end
    local ok2, p = pcall(Ext.Json.Parse, s)
    return ok2 and p or s
end

local SLOTS = { "Helmet", "Breast", "Cloak", "Melee Main Weapon", "Melee Offhand Weapon", "Ranged Main Weapon",
    "Ranged Offhand Weapon", "Ring", "Ring2", "Amulet", "Boots", "Gloves", "Underwear", "MusicalInstrument" }
local COMPONENTS = { "Health", "EocLevel", "Classes", "Stats", "ActionResources", "Experience", "Resistances",
    "SpellBookPrepares" }

-- Status entries: id, instance (pinned Ext.Utils.HandleToInteger of the status entity key), turns
-- (Osi.GetStatusTurns per id; identical for duplicate instances of one id). Source/cause are not pinned: absent.
local STATUS_FIELDS = "id, instance=HandleToInteger(status entity), turns=Osi.GetStatusTurns(id); source/cause not captured"
-- Pinned LuaEntityProxy.inl Index: a mapped component name reads nil only when the entity lacks the raw component.
-- That absence is reported as such (component_absent), never as an empty list: whether it means "no statuses" is
-- not established by the pinned source (live finding LV01).
local STATUS_ABSENT = "StatusContainer component absent (eoc::status::ContainerComponent); not read as empty"
local function statusEntries(e, u, withTurns)
    local okC, sc = pcall(function() return e.StatusContainer end)
    if not okC then return nil, tostring(sc) end
    if sc == nil then return nil, STATUS_ABSENT, true end
    local list = {}
    local ok, err = pcall(function()
        for h, id in pairs(sc.Statuses) do
            local okI, inst = pcall(function() return Ext.Utils.HandleToInteger(h) end)
            list[#list + 1] = { id = tostring(id), instance = okI and math.type(inst) and inst or nil }
        end
    end)
    if not ok then return nil, tostring(err) end
    table.sort(list, function(a, b)
        if a.id ~= b.id then return a.id < b.id end
        return (a.instance or 0) < (b.instance or 0)
    end)
    if withTurns then
        for _, st in ipairs(list) do st.turns = osi1(Osi.GetStatusTurns, u, st.id) end
    end
    return list
end

-- Full metadata/gear snapshot: start/end only.
local function character(u)
    local e = osi1(Ext.Entity.Get, u)
    local out = { uuid = u, name = name(u), party = scope().party[u] or nil, st = now() }
    out.pos = position(u)
    out.hostile_to_party = (function()
        local p = party()[1]
        return p and osi1(Osi.IsEnemy, u, p) == 1 or nil
    end)()
    if not e then out.entity = "unavailable" return out end
    out.ac = osi1(function() return e.Resistances.AC end)
    for _, c in ipairs(COMPONENTS) do
        local ok, v = pcall(function() return e[c] end)
        if ok and v ~= nil then out[c] = dump(v, 4) end
    end
    local list, err, absent = statusEntries(e, u, true)
    for _, st in ipairs(list or {}) do st.name = statName(st.id) end
    out.statuses = list or { unavailable = err, component_absent = absent or nil }
    out.statuses_error = err
    local equipment = {}
    for _, slot in ipairs(SLOTS) do
        local item = uuid(osi1(Osi.GetEquippedItem, u, slot))
        if item then
            local stats = osi1(function() return Ext.Entity.Get(item).Data.StatsId end)
            equipment[#equipment + 1] = { slot = slot, uuid = item, name = name(item), stats = scalar(stats) }
        end
    end
    out.equipment = equipment
    return out
end

-- Small dynamic state of one actor (pinned Data.h Health, Status.h StatusContainer, ActionResources.h).
local function dyn(u)
    local out = { uuid = u, st = now(), pos = position(u) }
    local e = osi1(Ext.Entity.Get, u)
    if not e then out.entity = "unavailable" return out end
    local okH, h = pcall(function()
        local H = e.Health
        if H == nil then return { unavailable = "no Health component" } end
        return { hp = H.Hp, max = H.MaxHp, temp = H.TemporaryHp, temp_max = H.MaxTemporaryHp }
    end)
    out.hp = okH and h or { unavailable = tostring(h) }
    local list, err, absent = statusEntries(e, u, CFG.CHECKPOINT_STATUS_TURNS)
    out.statuses = list or { unavailable = err, component_absent = absent or nil }
    if CFG.CHECKPOINT_RESOURCES then
        local res, n, cut = {}, 0, false
        local okR, errR = pcall(function()
            for _, arr in pairs(e.ActionResources.Resources) do
                for _, r in pairs(arr) do
                    n = n + 1
                    if n > 64 then cut = true return end
                    res[n] = { id = scalar(r.ResourceUUID), level = r.Level, amount = r.Amount, max = r.MaxAmount }
                end
            end
        end)
        if okR then
            table.sort(res, function(a, b)
                if a.id ~= b.id then return tostring(a.id) < tostring(b.id) end
                return (tonumber(a.level) or 0) < (tonumber(b.level) or 0)
            end)
        end
        out.resources = okR and res or { unavailable = tostring(errR) }
        if cut then out.resources_cut = true end
    end
    return out
end
rt.dyn = dyn

local function participants(f)
    local seen, list = {}, {}
    local function addu(u) if u and not seen[u] then seen[u] = true list[#list + 1] = u end end
    for _, u in ipairs(party()) do addu(u) end
    for c in pairs(scope().combats) do
        for _, row in ipairs(osi1(function() return Osi.DB_Is_InCombat:Get(nil, c) end) or {}) do addu(uuid(row[1])) end
    end
    if f then
        local extra = {}
        for u in pairs(f.seen) do extra[#extra + 1] = u end
        table.sort(extra)
        for _, u in ipairs(extra) do addu(u) end
    end
    return list
end

local function snapshot(why, f)
    local begin_t, chars = now(), {}
    local list = participants(f)
    for _, u in ipairs(list) do chars[#chars + 1] = character(u) end
    return { why = why, characters = chars, begin_t = begin_t, end_t = now(), atomic = false,
        timing = "event_adjacent", note = "sequential scan; per-actor st is each sample's time" }
end

------------------------------------------------------------------------
-- Prehistory: observations outside combat, with their own identities (DESIGN 9 DR-03)
------------------------------------------------------------------------

rt.prep = { head = 1, tail = 0, items = {}, evicted = nil }
local function prepEvict(reason)
    local P = rt.prep
    local r = P.items[P.head]
    P.items[P.head], P.head = nil, P.head + 1
    local ev = P.evicted or { count = 0, reasons = {}, first_obs = r.obs, first_t = r.t }
    P.evicted = ev
    ev.count, ev.last_obs, ev.last_t = ev.count + 1, r.obs, r.t
    ev.reasons[reason] = (ev.reasons[reason] or 0) + 1
end
local function prepPush(rec)
    local P = rt.prep
    P.tail = P.tail + 1
    P.items[P.tail] = rec
    while P.tail - P.head + 1 > CFG.PREP_KEEP do prepEvict("count") end
end

------------------------------------------------------------------------
-- Fights
------------------------------------------------------------------------

rt.fightN = 0
local function markSeen(f, data)
    if type(data) ~= "table" then return end
    for _, v in pairs(data) do
        if type(v) == "table" and type(v.uuid) == "string" then
            f.seen[v.uuid] = true
            if not f.dirty[v.uuid] then f.dirty[v.uuid] = true f.dirtyN = f.dirtyN + 1 end
            f.dirtyFirst = f.dirtyFirst or now()
            f.dirtyLast = now()
        end
    end
end

local function startFight(combat, how)
    rt.fightN = rt.fightN + 1
    local t0 = now()
    local f = { combat = combat, n = rt.fightN, seen = {}, dirty = {}, dirtyN = 0, jobs = {}, lastPos = {}, lastSample = {},
        jobStats = { dirty_coalesced = 0, reconcile_skipped = 0, max_jobs = 0 },
        moveNext = 0, reconcileNext = t0 + CFG.RECONCILE_MS, group = 0, overlaps = {} }
    f.stream = newStream(string.format("fight%02d", f.n), { combat_id = combat, fight = f.n })
    rt.fight = f
    local S = f.stream
    capture(S, "required", "meta", "recorder", t0, nextObs(), nil, function()
        return { schema_version = SCHEMA, recorder_version = VERSION, source_content_sha256 = rt.source_content_sha256,
            source_identity = rt.source_identity,
            session_id = rt.session_id, generation = rt.generation.id, context = CTX, stream_id = S.name,
            fight = f.n, combat_id = combat, how = how, start_mode = how == "loaded_in_combat" and "mid_fight_attach" or "normal",
            epoch = epoch(), clock = rt.clock, versions = versions(), capabilities = capabilities(), hooks = rt.hooks,
            config = CFG, config_unknown_keys = CFG_UNKNOWN,
            level = osi1(function() return Osi.GetRegion(party()[1]) end),
            unknowns = { "loaded SE build is not verified against the declaration pin",
                "game rule settings are not captured here (intake manifest scope)",
                "participants are those observed, not proof of the engine population" } }
    end)
    -- prehistory: original observation ids/times kept, storage seq contiguous in this stream
    local P, cutoff = rt.prep, t0 - CFG.PREP_MS
    while P.head <= P.tail and P.items[P.head].t < cutoff do prepEvict("age") end
    capture(S, "required", "prehistory_window", "recorder", t0, nextObs(), nil, function()
        return { kept = P.tail - P.head + 1, keep_max = CFG.PREP_KEEP, window_ms = CFG.PREP_MS, evicted = P.evicted,
            oldest_obs = P.items[P.head] and P.items[P.head].obs or nil }
    end)
    for i = P.head, P.tail do
        local r = P.items[i]
        local seq = S:admit("required", t0, r.obs, r.kind) -- queued at storage time; r.t stays in the record
        if seq then S:commit(seq, r.t, r.obs, r.kind, r.phase, r.data, { prehistory = true, st = t0, err = r.err }) end
    end
    rt.prep = { head = 1, tail = 0, items = {}, evicted = nil }
    capture(S, "required", "snapshot", "combat_start", now(), nextObs(), nil, snapshot, "combat_start", f)
    for _, u in ipairs(participants(f)) do f.seen[u] = true end
    pumpAll(true)
    say("fight " .. f.n .. " started: " .. S.prefix)
end
rt.startFight = startFight

local function endFight(why)
    local f = rt.fight
    if not f then return end
    local S = f.stream
    capture(S, "required", "snapshot", why or "combat_end", now(), nextObs(), nil, snapshot, why or "combat_end", f)
    S:emit("required", "stream_stats", { counters = S.c, profile = CFG.PROFILE and rt.profile or nil,
        degraded_intervals = S.degradeLog, checkpoint_jobs = f.jobStats, movement_not_emitted = f.moveNotEmitted,
        parts_index_dropped = S.partsDropped })
    S:emit("required", "end", { why = why or "combat_end", epoch = epoch() })
    S:finish(now(), why or "combat_end")
    rt.fight = nil
    pumpAll(true)
    say("fight " .. f.n .. " ended (" .. S.state .. "): " .. S.prefix)
end
rt.endFight = endFight

local function maybeStart(combat, how)
    invalidateScope()
    if not scope().combats[combat] then return end
    local f = rt.fight
    if not f then return startFight(combat, how) end
    if f.combat ~= combat and not f.overlaps[combat] then
        f.overlaps[combat] = true
        f.stream:emit("required", "scope_transition", { what = "overlapping_party_combat", other_combat = combat,
            active_combat = f.combat, support = "unsupported: events of both combats share this stream" })
    end
end

-- Route one observation: the active fight's stream, or prehistory when the party is involved outside combat.
local function observe(kind, phase, inv, class, builder, ...)
    local t, obs = now(), nextObs()
    local f = rt.fight
    if f then
        local data = capture(f.stream, class, kind, phase, t, obs, nil, builder, ...)
        if data then markSeen(f, data) end
        return data
    elseif inv == "party" then
        local ok, data = xpcall(builder, errh, ...)
        local rec = { t = t, obs = obs, kind = kind, phase = phase, data = ok and data or nil, err = not ok and data or nil }
        if rt.fight then -- a fight started while this observation was being built
            local S = rt.fight.stream
            local seq = S:admit("required", t, obs, kind)
            if seq then S:commit(seq, t, obs, kind, phase, rec.data, { prehistory = true, prehistory_late = true, err = rec.err }) end
        else
            prepPush(rec)
        end
    end
end

local DYN_FIELDS = { "pos", "hp", "statuses", "resources", "resources_cut", "entity" }
local function same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if k ~= "st" and not same(v, b[k]) then return false end end
    for k in pairs(b) do if k ~= "st" and a[k] == nil then return false end end
    return true
end

-- Full anchor samples, or deltas: only fields changed since the actor's last COMMITTED sample (base_seq);
-- an omitted field means unchanged since that sample, {removed=true} means it disappeared.
local function sampleActors(f, actors, full)
    local samples, pending = {}, {}
    for i, u in ipairs(actors) do
        local s = dyn(u)
        if s.pos.valid then s.pos.st = s.st end
        pending[i] = s
        local last = not full and CFG.CHECKPOINT_DELTA and f.lastSample[u]
        if last then
            local d = { uuid = u, st = s.st, base_seq = last.seq }
            for _, k in ipairs(DYN_FIELDS) do
                if not same(s[k], last.sample[k]) then d[k] = s[k] == nil and { removed = true } or s[k] end
            end
            samples[i] = d
        else
            s.full = true
            samples[i] = s
        end
    end
    return samples, pending
end

-- A sample becomes a delta base only if its record was committed (not a terminal error, not refused).
local function checkpoint(f, class, why, timing, actors, full, extra)
    local S, t, pending = f.stream, now(), nil
    local _, seq = capture(S, class, "checkpoint", why, t, nextObs(), nil, function()
        local before = S.nextSeq - 1
        local samples
        samples, pending = sampleActors(f, actors, full)
        local d = { why = why, timing = timing, actors = samples, begin_t = t, end_t = now(), atomic = false,
            seq_watermark_begin = before, seq_watermark_end = S.nextSeq - 1, status_fields = STATUS_FIELDS }
        if extra then for k, v in pairs(extra) do d[k] = v end end
        return d
    end)
    if pending and seq and S.lastTerminalErr ~= seq then
        for i, u in ipairs(actors) do
            f.lastSample[u] = { seq = seq, sample = pending[i] }
            if pending[i].pos and pending[i].pos.valid then f.lastPos[u] = pending[i].pos end
        end
    end
end

local function checkpointNow(f, why, actors, class, full)
    if not f or #actors == 0 then return end
    checkpoint(f, class, why, "event_adjacent", actors, full)
end

local function listen(evname, arity, fn)
    local ok, ret = pcall(Ext.Osiris.RegisterListener, evname, arity, "after", gated(evname, fn))
    rt.hooks[evname] = { registered = ok, kind = "osiris", phase = "after", error = not ok and tostring(ret) or nil,
        handle = ok and scalar(ret) or nil }
    if ok then rt.generation.osiris = rt.generation.osiris + 1 end
end

-- Generic Osiris event (legacy names and fields): who-fields ("@x") name their characters.
local function on(evname, arity, fields, extra, after)
    listen(evname, arity, function(...)
        local args = table.pack(...)
        local ids, n = {}, 0
        for i, fl in ipairs(fields) do if fl:sub(1, 1) == "@" then n = n + 1 ids[n] = args[i] end end
        local inv = involvement(table.unpack(ids, 1, n))
        if not inv then return end
        local data = observe(evname, "after", inv, "required", function()
            local d = {}
            for i, fl in ipairs(fields) do
                if fl:sub(1, 1) == "@" then d[fl:sub(2)] = who(args[i])
                elseif fl ~= "_" then d[fl] = scalar(args[i]) end
            end
            if extra then extra(d, args) end
            return d
        end)
        if after and data and rt.fight then after(rt.fight, data, args) end
    end)
end

local function turnCheckpoint(f, data, args)
    invalidateScope()
    if CFG.CHECKPOINT_ON_TURN and data.char and data.char.uuid then
        checkpointNow(f, "turn_boundary", { data.char.uuid }, "required", true)
    end
end
local function actionCheckpoint(f, data)
    if not CFG.CHECKPOINT_ON_ACTION then return end
    local list = {}
    if type(data.caster) == "table" and data.caster.uuid then list[#list + 1] = data.caster.uuid end
    if type(data.target) == "table" and data.target.uuid and data.target.uuid ~= list[1] then list[#list + 1] = data.target.uuid end
    checkpointNow(f, "action", list, "optional")
end

-- Pinned ServerEvents.h/Hit.h fields of DealtDamage.Result (HitResult), copied inside the callback.
local HIT_SCALARS = { "TotalDamageDone", "DeathType", "DamageType", "CauseType", "ArmorAbsorption", "LifeSteal",
    "EffectFlags", "StoryActionId", "HitWith", "AttackRollAbility", "SaveAbility", "SpellAttackType", "SpellCastGuid",
    "SpellId", "StatusId", "SpellSchool", "AttackFlags", "SpellLevel", "SpellPowerLevel", "TotalHealDone",
    "OriginalDamageValue" }
local function copyField(obj, k, out, missing)
    local ok, v = pcall(function() return obj[k] end)
    if ok then out[k] = scalar(v) else missing[k] = tostring(v) end
end
local function copyResult(r)
    if r == nil then return { unavailable = "Result nil" } end
    local out, missing = { provenance = "DealtDamage.Result HitResult per " .. DECLARATION_PIN }, {}
    local okH, hit = pcall(function() return r.Hit end)
    if okH and hit ~= nil then
        local h = {}
        for _, k in ipairs(HIT_SCALARS) do copyField(hit, k, h, missing) end
        local okR, rolls = pcall(function()
            local list = {}
            for i, cr in pairs(hit.ConditionRolls) do
                if #list >= 8 then list.cut = true break end
                local c = {}
                for _, k in ipairs({ "RollType", "Difficulty", "Ability", "Skill", "SwappedSourceAndTarget", "RollUuid" }) do
                    copyField(cr, k, c, missing)
                end
                list[#list + 1] = c
            end
            return list
        end)
        h.ConditionRolls = okR and rolls or nil
        if not okR then missing.ConditionRolls = tostring(rolls) end
        out.Hit = h
    else
        missing.Hit = okH and "nil" or tostring(hit)
    end
    local okA, atk = pcall(function() return r.Attack end)
    if okA and atk ~= nil then
        local a = {}
        copyField(atk, "TotalDamageDone", a, missing)
        copyField(atk, "TotalHealDone", a, missing)
        local okL, list = pcall(function()
            local l = {}
            for _, dp in pairs(atk.DamageList) do
                if #l >= 16 then l.cut = true break end
                l[#l + 1] = { amount = scalar(dp.Amount), type = scalar(dp.DamageType) }
            end
            return l
        end)
        a.DamageList = okL and list or nil
        if not okL then missing.DamageList = tostring(list) end
        out.Attack = a
    else
        missing.Attack = okA and "nil" or tostring(atk)
    end
    copyField(r, "NumConditionRolls", out, missing)
    local okM, res = pcall(function()
        local m, n = {}, 0
        for k, v in pairs(r.Results) do
            n = n + 1
            if n > 32 then m._cut = true break end
            m[tostring(scalar(k))] = scalar(v)
        end
        return m
    end)
    out.Results = okM and res or nil
    if not okM then missing.Results = tostring(res) end
    if next(missing) then out.missing = missing end
    return out
end
rt.copyResult = copyResult

local registered = false
local function register()
    if registered then return end
    registered = true

    listen("CombatStarted", 1, function(c) maybeStart(c, "CombatStarted") end)
    listen("CombatRoundStarted", 2, function(c, round)
        maybeStart(c, "CombatRoundStarted")
        local f = rt.fight
        if f and f.combat == c then observe("CombatRoundStarted", "after", "fight", "required",
            function() return { round = scalar(round) } end) end
    end)
    listen("CombatEnded", 1, function(c)
        invalidateScope()
        local f = rt.fight
        if f and f.combat == c then
            endFight("combat_end")
            for other in pairs(scope().combats) do maybeStart(other, "continued_party_combat") break end
        end
    end)

    on("TurnStarted", 1, { "@char" }, nil, turnCheckpoint)
    on("TurnEnded", 1, { "@char" }, nil, turnCheckpoint)
    on("UsingSpellOnTarget", 6, { "@caster", "@target", "spell", "type", "element", "_" },
        function(d) d.name = statName(d.spell) end, actionCheckpoint)
    on("CastedSpell", 5, { "@caster", "spell", "type", "element", "_" }, function(d) d.name = statName(d.spell) end,
        actionCheckpoint)
    on("AttackedBy", 7, { "@target", "@source", "@via", "damage_type", "amount", "cause", "_" })
    on("RollResult", 6, { "event", "@roller", "@subject", "result", "active", "critical" })
    on("StatusApplied", 4, { "@target", "status", "@source", "_" }, function(d, a)
        d.name = statName(d.status)
        d.turns = osi1(Osi.GetStatusTurns, a[1], d.status)
    end)
    on("StatusRemoved", 4, { "@target", "status", "@source", "_" }, function(d) d.name = statName(d.status) end)
    on("HitpointsChanged", 2, { "@char", "pct" })
    on("DownedChanged", 2, { "@char", "downed" })
    on("Died", 1, { "@char" }, nil, function() invalidateScope() end)
    on("Equipped", 2, { "@item", "@char" })
    on("Unequipped", 2, { "@item", "@char" })
    on("UseFinished", 3, { "@char", "@item", "success" })

    local function field(e, k)
        local ok, v = pcall(function() return e[k] end)
        return ok and v or nil
    end
    local shapes = {}
    for _, evname in ipairs({ "BeforeDealDamage", "DealDamage", "DealtDamage" }) do
        subscribe(evname, function(e)
            -- Pinned ServerEvents.h: BeforeDealDamage has only Hit/Attack; attribute it via Hit.Inflicter, if any.
            local cu, tu, attribution
            if evname == "BeforeDealDamage" then
                local hit = field(e, "Hit")
                cu = hit and entityUuid(field(hit, "Inflicter"))
                attribution = cu and "Hit.Inflicter" or "unattributed"
            else
                cu, tu = entityUuid(field(e, "Caster")), entityUuid(field(e, "Target"))
                attribution = (cu or tu) and "Caster/Target" or "unattributed"
            end
            local inv = involvement(cu, tu)
            if (cu or tu) and not inv then return end
            if not inv and not rt.fight then return end
            observe(evname, "ext_event", inv, "required", function()
                local data = { caster = who(cu), target = who(tu), attribution = attribution,
                    scope = inv or "unattributed_global" }
                if evname ~= "BeforeDealDamage" then
                    data.spell = reflected(field(e, "SpellId"), 3)
                    data.story_action_id = scalar(field(e, "StoryActionId"))
                    data.originator = reflected(field(e, "Originator"), 2)
                end
                if CFG.DAMAGE_REFLECT then
                    data.hit = reflected(field(e, "Hit"), 8)
                    data.attack = reflected(field(e, "Attack"), 4)
                end
                if evname == "DealtDamage" then data.result = copyResult(field(e, "Result")) end
                if not shapes[evname] then
                    shapes[evname] = true
                    data.shape = reflected(e, 1)
                end
                return data
            end)
        end)
    end

    if CFG.EXPERIMENTAL_FUNCTORS then
        for _, evname in ipairs({ "ExecuteFunctor", "AfterExecuteFunctor" }) do
            subscribe(evname, function(e)
                if not rt.fight then return end
                observe(evname, "ext_event_experimental", "fight", "optional", function()
                    return { experimental = true, functor = reflected(field(e, "Functor"), 1),
                        params = reflected(field(e, "Params"), 2),
                        hit = evname == "AfterExecuteFunctor" and reflected(field(e, "Hit"), 3) or nil,
                        coverage = "diagnostic only; no miss/save completeness claim" }
                end)
            end, true)
        end
    end

    subscribe("GameStateChanged", function(e)
        local from, to = scalar(field(e, "FromState")), scalar(field(e, "ToState"))
        lifecycle("game_state_changed", { from = from, to = to })
        local f = rt.fight
        if f then
            f.stream:emit("required", "scope_transition", { what = "game_state_changed", from = from, to = to,
                note = "best-effort flush; the fight stream stays open" })
            pumpAll(true)
        end
    end, true)

    subscribe("Tick", function()
        local f = rt.fight
        if f then
            local t = now()
            local degraded = anyDegraded()
            if CFG.MOVEMENT_ENABLED and not degraded and t >= f.moveNext then
                f.moveNext = t + CFG.MOVE_POLL_MS
                local moved, suppressed = {}, 0
                for u in pairs(f.seen) do
                    local p = position(u)
                    local last = f.lastPos[u]
                    if p.valid then
                        local d = last and math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 + (p.z - last.z) ^ 2)
                        if not d or d > CFG.MOVE_MIN_M then
                            moved[#moved + 1] = { uuid = u, pos = p, dist = d, since_t = last and last.st }
                            p.st = t
                        else
                            suppressed = suppressed + 1
                        end
                    end
                end
                if #moved > 0 then
                    local _, seq = capture(f.stream, "optional", "movement", "poll", t, nextObs(), nil, function()
                        return { samples = moved, suppressed_below_threshold = suppressed, threshold_m = CFG.MOVE_MIN_M,
                            interval_ms = CFG.MOVE_POLL_MS, note = "sampled; no path/teleport/LOS claim" }
                    end)
                    if seq and f.stream.lastTerminalErr ~= seq then
                        for _, m in ipairs(moved) do f.lastPos[m.uuid] = m.pos end
                    else
                        f.moveNotEmitted = (f.moveNotEmitted or 0) + #moved
                    end
                end
            end
            if f.dirtyN > 0 and (t - f.dirtyLast >= CFG.DIRTY_QUIET_MS or t - f.dirtyFirst >= CFG.DIRTY_MAX_MS) then
                local list = {}
                for u in pairs(f.dirty) do list[#list + 1] = u end
                table.sort(list)
                local pending
                for _, j in ipairs(f.jobs) do if j.why == "dirty" then pending = j end end
                if pending then
                    local merged, have = {}, {}
                    for i = pending.i, #pending.actors do merged[#merged + 1] = pending.actors[i] have[pending.actors[i]] = true end
                    for _, u in ipairs(list) do if not have[u] then merged[#merged + 1] = u end end
                    pending.actors, pending.i, pending.merged = merged, 1, (pending.merged or 0) + 1
                    f.jobStats.dirty_coalesced = f.jobStats.dirty_coalesced + 1
                else
                    f.group = f.group + 1
                    f.jobs[#f.jobs + 1] = { why = "dirty", actors = list, i = 1, group = f.group, first_t = f.dirtyFirst }
                end
                f.dirty, f.dirtyN, f.dirtyFirst, f.dirtyLast = {}, 0, nil, nil
            end
            if CFG.RECONCILE_MS > 0 and t >= f.reconcileNext and not degraded then
                f.reconcileNext = t + CFG.RECONCILE_MS
                local busy = false
                for _, j in ipairs(f.jobs) do if j.why == "reconcile" then busy = true end end
                if busy then
                    f.jobStats.reconcile_skipped = f.jobStats.reconcile_skipped + 1
                else
                    f.group = f.group + 1
                    f.jobs[#f.jobs + 1] = { why = "reconcile", actors = participants(f), i = 1, group = f.group }
                end
            end
            if #f.jobs > f.jobStats.max_jobs then f.jobStats.max_jobs = #f.jobs end
            local job = f.jobs[1]
            if job then
                local chunk = {}
                for i = job.i, math.min(#job.actors, job.i + CFG.CHECKPOINT_MAX_ACTORS - 1) do chunk[#chunk + 1] = job.actors[i] end
                local from = job.i
                job.i = job.i + #chunk
                local last = job.i > #job.actors
                if last then table.remove(f.jobs, 1) end
                checkpoint(f, "optional", job.why, "deferred", chunk, false, { group = job.group, from_index = from,
                    total = #job.actors, last_chunk = last, marked_since_t = job.first_t, merged = job.merged })
            end
        end
        pumpAll(false)
    end, nil, true)
end

rt.stop = function(why)
    if rt.fight then endFight(why or "stopped") end
    rt.generation.active = false
    lifecycle("generation_stopped", { why = why or "console",
        note = "observation callbacks inert; Tick keeps draining until every stream is complete or abandoned" })
    rt.session:finish(now(), why or "stopped")
    pumpAll(true)
end

lifecycle("meta", { schema_version = SCHEMA, recorder_version = VERSION,
    source_content_sha256 = rt.source_content_sha256, source_identity = rt.source_identity,
    identity = IDENTITY, session_id = rt.session_id, generation = rt.generation.id, context = CTX, epoch = epoch(),
    clock = rt.clock, versions = versions(), config = CFG, config_unknown_keys = CFG_UNKNOWN })
FightRecV2 = rt
register()
lifecycle("hooks", { hooks = rt.hooks, capabilities = capabilities() })

if not rt.fight then
    for c in pairs(scope().combats) do
        if not rt.fight then startFight(c, "loaded_in_combat") else maybeStart(c, "loaded_in_combat") end
    end
end
pumpAll(true)
say("server ready (" .. rt.generation.id .. ", source " .. rt.source_content_sha256 .. ")")

------------------------------------------------------------------------
-- Client: the combat log panel (auxiliary; never authoritative)
------------------------------------------------------------------------
else

local UI = {}
rt.ui = UI
local function get(obj, k) local ok, v = pcall(function() return obj[k] end) return ok and v or nil end
local function typeName(obj) return get(obj, "Type") end
local function count(coll)
    if coll == nil then return 0 end
    local ok, n = pcall(function() return coll:GetProperty("Count") end)
    if ok and tonumber(n) then return tonumber(n) end
    ok, n = pcall(function() return coll.Count end)
    if ok and tonumber(n) then return tonumber(n) end
    ok, n = pcall(function() return #coll end)
    return ok and tonumber(n) or 0
end
local function at(coll, i)
    if UI.atBase == nil and count(coll) > 0 then
        local ok0, v0 = pcall(function() return coll:At(0) end)
        UI.atBase = (ok0 and v0 ~= nil) and 0 or 1
    end
    local ok, v = pcall(function() return coll:At(i - 1 + (UI.atBase or 1)) end)
    if ok and v ~= nil then return v end
    ok, v = pcall(function() return coll[i] end)
    return ok and v or nil
end
local function props(vm) local ok, p = pcall(function() return vm:GetAllProperties() end) return ok and type(p) == "table" and p or {} end
local function isCollection(tn) return type(tn) == "string" and tn:find("Collection") ~= nil end
local function isViewModel(tn)
    return type(tn) == "string" and (tn:find("::", 1, true) or tn:find("^ls%.") or tn:find("^gui%."))
        and not tn:find("^Noesis")
end
local SKIP = { CurrentPlayer = true, Data = true, Players = true, PlayerList = true, IsSeen = true }
local KNOWN = { "Entries", "TooltipEntries", "ParamTooltips", "CtxTransText", "ChildDepth", "Text", "Message", "Id" }
-- LV02: fixed-size scalar leaf view models copied even at the depth limit (scalar properties only, no recursion,
-- budget still charged). ls.VMDiceTypeSet {Amount, DiceType, Str, ExtraStr} was the most frequent depth-cut node
-- in the historical combat log raw (477 of 1281 cut nodes) and in the live first-attack hit entry, where it sits
-- under the deepest "Attack Roll: [1]" / "Damage Roll: [1] = [2]" tooltip params. A non-scalar member still cuts.
local LEAF_PAST_DEPTH = { ["ls.VMDiceTypeSet"] = true }

local vmdump
local function knownFields(obj, out, depth, budget)
    for _, k in ipairs(KNOWN) do
        if out[k] == nil then
            local v = get(obj, k)
            if v ~= nil then out[k] = vmdump(v, depth - 1, budget) end
        end
    end
end

-- A view model as owned plain data; budget.cut / budget.items record what the limits left out.
vmdump = function(obj, depth, budget)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return obj end
    budget.n = budget.n - 1
    local tn = typeName(obj) or "?"
    if type(tn) ~= "string" then tn = scalar(tn) end
    if budget.n <= 0 then budget.cut = true return { _type = tn, _cut = true } end
    if tn:find("Command") then return { _cmd = tn } end
    if isCollection(tn) or (tn == "?" and count(obj) > 0 and at(obj, 1) ~= nil) then
        local n, items = count(obj), {}
        if depth > 0 then
            for i = 1, math.min(n, 30) do
                if budget.n <= 0 then budget.cut = true break end
                items[i] = vmdump(at(obj, i), depth - 1, budget)
            end
        elseif n > 0 then budget.cut = true end
        if n > 30 then budget.items = (budget.items or 0) + (n - 30) end
        return { _type = tn, _count = n, _items = items }
    end
    if not isViewModel(tn) then
        local ok, s = pcall(function() return obj:ToString() end)
        local out = { _type = tn, _text = ok and type(s) == "string" and s ~= "" and s or nil }
        if depth > 0 then knownFields(obj, out, depth, budget) end
        return out
    end
    local out = { _type = tn }
    if depth <= 0 then
        if LEAF_PAST_DEPTH[tn] then
            local p, leaf = props(obj), true
            for _, v in pairs(p) do
                local tv = type(v)
                if tv == "userdata" or tv == "table" then leaf = false break end
            end
            if leaf and next(p) ~= nil then
                for k, v in pairs(p) do out[tostring(k)] = v end
                return out
            end
        end
        out._cut = true budget.cut = true return out
    end
    local any = false
    for k, v in pairs(props(obj)) do
        if budget.n <= 0 then budget.cut = true out._omitted = true break end
        if not SKIP[k] then out[tostring(k)] = vmdump(v, depth - 1, budget) any = true end
    end
    if not any then knownFields(obj, out, depth, budget) end
    return out
end
UI.vmdump = vmdump

local function isLogDC(tn) return type(tn) == "string" and tn:lower():find("combatlog") ~= nil end

local function children(el)
    local out = {}
    local n = tonumber(get(el, "VisualChildrenCount")) or 0
    if n == 0 then return out end
    if UI.childBase == nil then
        local ok0, c0 = pcall(function() return el:VisualChild(0) end)
        UI.childBase = (ok0 and c0 ~= nil) and 0 or 1
    end
    for i = UI.childBase, UI.childBase + n - 1 do
        local ok, c = pcall(function() return el:VisualChild(i) end)
        if ok and c ~= nil then out[#out + 1] = c end
    end
    return out
end

function UI.searchLog(root)
    local queue, routes, head, tail, seen, found = { root }, { {} }, 1, 1, 0, {}
    while queue[head] and seen < CFG.SEARCH_BUDGET and #found < 10 do
        local el, route = queue[head], routes[head]
        queue[head], routes[head] = nil, nil
        head, seen = head + 1, seen + 1
        local dc = get(el, "DataContext")
        local tn = dc and typeName(dc)
        if dc and (isLogDC(tn) or isLogDC(get(el, "Name"))) then
            found[#found + 1] = { el = el, dc = dc, dcType = tn, name = get(el, "Name"), type = typeName(el), route = route }
        else
            for i, c in ipairs(children(el)) do
                tail = tail + 1
                queue[tail] = c
                local r = { table.unpack(route) }
                r[#r + 1] = i
                routes[tail] = r
            end
        end
    end
    return found, seen, queue[head] ~= nil
end

function UI.walk(root, route)
    local el = root
    for _, i in ipairs(route) do
        local n = tonumber(get(el, "VisualChildrenCount")) or 0
        if i > n then return nil end
        local ok, c = pcall(function() return el:VisualChild((UI.childBase or 0) + i - 1) end)
        if not ok or c == nil then return nil end
        el = c
    end
    return el
end

local function entryGroups(dc)
    local d = get(dc, "Data")
    local cl = d and get(d, "CombatLog")
    return cl and get(cl, "EntryGroups"), d, cl
end

local L = { count = 0, lastSig = nil, next = 0, gen = 1, token = 0, inflight = nil, deferFails = 0,
    errors = 0, maxBacklog = 0, stale = 0, stalledEpisodes = 0, polls = 0 }
rt.log = L
L.stream = newStream("combatlog", {})

local function logRec(kind, phase, builder, ...)
    return capture(L.stream, "required", kind, phase, now(), nextObs(), nil, builder, ...)
end

function UI.locate()
    local root = get(Ext.UI, "GetRoot") and Ext.UI.GetRoot()
    if not root then return nil end
    if L.route then
        local el = UI.walk(root, L.route)
        local dc = el and get(el, "DataContext")
        if dc and isLogDC(typeName(dc)) then
            local eg = entryGroups(dc)
            if eg ~= nil then return "Data.CombatLog.EntryGroups", eg end
        end
        L.route = nil
        L.gen = L.gen + 1
        logRec("route_lost", "ui", function() return { generation = L.gen } end)
    end
    local t = now()
    if t < (L.nextTry or 0) then return nil end
    L.nextTry = t + 2000
    local matches, seen, budgetHit = UI.searchLog(root)
    local best, bestN, listed = nil, -1, {}
    for _, m in ipairs(matches) do
        local eg, d, cl = entryGroups(m.dc)
        local steps = { "Data=" .. tostring(d and typeName(d) or d ~= nil and type(d) or "nil"),
            "CombatLog=" .. tostring(cl and typeName(cl) or cl ~= nil and type(cl) or "nil"),
            "EntryGroups=" .. tostring(eg and typeName(eg) or eg ~= nil and type(eg) or "nil") }
        if eg ~= nil and count(eg) > bestN then best, bestN = { m = m, eg = eg }, count(eg) end
        listed[#listed + 1] = { panel = scalar(m.name), route = m.route, steps = steps, count = eg and count(eg) or nil }
    end
    L.tries = (L.tries or 0) + 1
    if L.tries <= 3 or best then
        logRec("locate", "ui", function()
            local panels = {}
            for i, m in ipairs(matches) do panels[i] = { element = scalar(m.name), type = scalar(m.type), dc = scalar(m.dcType) } end
            return { visited = seen, search_budget_exhausted = budgetHit or nil, panels = panels, candidates = listed,
                chosen = best and "Data.CombatLog.EntryGroups" or nil, generation = L.gen }
        end)
    end
    if not best then return nil end
    L.route = best.m.route
    return "Data.CombatLog.EntryGroups", best.eg
end

local function fp(coll, i)
    local g = at(coll, i)
    if g == nil then return "nil" end
    local es = get(g, "Entries")
    local e = es and at(es, 1)
    local ct = get(g, "CtxTransText")
    return tostring(e and typeName(e)) .. "|" .. tostring(e and get(e, "Timestamp")) .. "|" .. tostring(ct and get(ct, "Text"))
end

function UI.pollLog()
    local cname, coll = UI.locate()
    if not coll then return end
    local n = count(coll)
    local from = L.count + 1
    if L.lastSig and (n < L.count or fp(coll, L.count) ~= L.lastSig) then
        local rebuilt = n < L.count
        if rebuilt then L.gen = L.gen + 1 end
        from = rebuilt and 1 or L.count + 1
        local matches = 0
        for i = n, 1, -1 do
            if fp(coll, i) == L.lastSig then
                matches = matches + 1
                if matches == 1 then from = i + 1 end
            end
        end
        logRec("resync", "ui", function()
            return { count = n, from = from, generation = L.gen, rebuilt = rebuilt or nil,
                fingerprint_matches = matches, ambiguous_duplicate = matches > 1 or nil }
        end)
        if from > n and n > 0 then L.lastSig = fp(coll, n) end
    end
    local last = math.min(n, from + CFG.MAX_PER_POLL - 1)
    for i = from, last do
        local sig = fp(coll, i)
        logRec("entry", "ui", function()
            local budget = { n = CFG.ENTRY_BUDGET }
            local entry = vmdump(at(coll, i), CFG.ENTRY_DEPTH, budget)
            return { i = i, collection = cname, entry = entry, generation = L.gen, backlog = n - i,
                complete = not (budget.cut or budget.items) , items_omitted = budget.items,
                fingerprint_repeat = sig == L.lastSig or nil }
        end)
        L.lastSig = sig
    end
    L.count = math.max(last, from - 1)
    local backlog = n - L.count
    if backlog > L.maxBacklog then L.maxBacklog = backlog end
    L.backlog = backlog
end

local function deferredPoll(token)
    if not rt.generation.active then return end
    if not L.inflight or L.inflight.token ~= token then
        L.stale = L.stale + 1
        return
    end
    L.polls = L.polls + 1
    if L.inflight.stalled then
        local age = now() - L.inflight.at
        logRec("defer_recovered", "ui", function() return { age_ms = age, token = token } end)
    end
    local ok, err = pcall(UI.pollLog)
    if not ok then
        L.route, L.nextTry = nil, 0
        L.errors = L.errors + 1
        if L.errors <= 20 then
            warn("combat log: " .. tostring(err))
            logRec("error", "ui", function() return { error = tostring(err), n = L.errors } end)
        end
    end
    L.inflight = nil
    L.next = now() + CFG.LOG_POLL_MS -- after completion, never stacked
end
UI.deferredPoll = deferredPoll

local function markUnsupported(why)
    L.unsupported = why
    lifecycle("ui_capture_unsupported", { reason = why, note = "no direct Noesis access outside Ext.UI.Defer; server capture unaffected" })
    warn("combat log capture unsupported: " .. why)
end

local function clientTick()
    local t = now()
    if not L.unsupported then
        if L.inflight then
            local age = t - L.inflight.at
            if age > CFG.DEFER_STALL_MS and not L.inflight.reported then
                L.inflight.reported = true
                logRec("defer_stall", "ui", function() return { age_ms = age, token = L.inflight.token } end)
            end
            if age > 3 * CFG.DEFER_STALL_MS and not L.inflight.stalled then
                L.inflight.stalled = true
                L.stalledEpisodes = L.stalledEpisodes + 1
                logRec("defer_stalled", "ui", function()
                    return { age_ms = age, token = L.inflight.token, note = "accepted Defer callback has not run; " ..
                        "no cancellation API is verified, so no further poll is scheduled until it runs" }
                end)
            end
        elseif t >= L.next and not anyDegraded() then
            local D = Ext.UI and Ext.UI.Defer
            if not present(D) then
                markUnsupported("Ext.UI.Defer unavailable")
            else
                L.token = L.token + 1
                local token = L.token
                L.inflight = { token = token, at = t }
                local ok, err = pcall(D, function() deferredPoll(token) end)
                if ok then
                    L.deferFails = 0
                else
                    L.inflight = nil
                    L.deferFails = L.deferFails + 1
                    L.next = t + CFG.LOG_POLL_MS * (2 ^ math.min(L.deferFails, 5))
                    logRec("defer_error", "ui", function() return { error = tostring(err), n = L.deferFails } end)
                    if L.deferFails >= CFG.DEFER_FAIL_LIMIT then markUnsupported("Ext.UI.Defer failed " .. L.deferFails .. " times") end
                end
            end
        end
    end
    pumpAll(false)
end
UI.tick = clientTick

rt.stop = function(why)
    rt.generation.active = false
    L.stream:emit("required", "stream_stats", { counters = L.stream.c, polls = L.polls, stale = L.stale,
        stalled_episodes = L.stalledEpisodes, max_backlog = L.maxBacklog })
    L.stream:finish(now(), why or "stopped")
    lifecycle("generation_stopped", { why = why or "console",
        note = "observation callbacks inert; Tick keeps draining until every stream is complete or abandoned" })
    rt.session:finish(now(), why or "stopped")
    pumpAll(true)
end

lifecycle("meta", { schema_version = SCHEMA, recorder_version = VERSION,
    source_content_sha256 = rt.source_content_sha256, source_identity = rt.source_identity,
    identity = IDENTITY, session_id = rt.session_id, generation = rt.generation.id, context = CTX, epoch = epoch(),
    clock = rt.clock, versions = versions(), config = CFG, config_unknown_keys = CFG_UNKNOWN })
FightRecV2 = rt
subscribe("Tick", clientTick, nil, true)
lifecycle("hooks", { hooks = rt.hooks, capabilities = capabilities() })
if not present(Ext.UI and Ext.UI.Defer) then markUnsupported("Ext.UI.Defer unavailable") end
pumpAll(true)
say("client ready: combat log -> " .. L.stream.prefix)

end
