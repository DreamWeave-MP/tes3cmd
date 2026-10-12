--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Plugin lint checks and safe cleaning (jess-omwaddon's `lint`, tes3cmd's `lint` and `clean`).
`lint` reports findings for the checks asked for; `clean` removes the safe subset (duplicate
records, evil GMSTs, junk cells, duplicate cell parameters). Checks that compare with master files
find them through a master source (`masters.luau`).
]]

local Masters = require './masters'
local Numbers = require './numbers'
local bytes = require '@dream/bytes'
local intern = require '@dream/intern'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin
type Source = Masters.Source

export type Severity = 'error' | 'warning' | 'info'
--- A finding; `check` is the check's camelCase name, as jess's Luau API spells it.
export type Finding = { check: string, severity: Severity, message: string }

--- Every check, by label, in declaration order, with its severity and whether it needs masters.
local Checks: { { label: string, severity: Severity, masters: boolean } } = {
  { label = 'duplicate-records', severity = 'warning', masters = false },
  { label = 'evil-gmsts', severity = 'warning', masters = false },
  { label = 'cell-params', severity = 'warning', masters = false },
  { label = 'junk-cells', severity = 'warning', masters = false },
  { label = 'record-count', severity = 'warning', masters = false },
  { label = 'missing-author', severity = 'info', masters = false },
  { label = 'missing-description', severity = 'info', masters = false },
  { label = 'missing-master', severity = 'error', masters = true },
  { label = 'master-sync', severity = 'warning', masters = true },
  { label = 'missing-version', severity = 'info', masters = false },
  { label = 'overrides', severity = 'info', masters = true },
  { label = 'fogbug', severity = 'warning', masters = false },
  { label = 'fogsync', severity = 'warning', masters = false },
  { label = 'autocalc-spells', severity = 'info', masters = false },
  { label = 'bloodmoon-dependency', severity = 'error', masters = false },
  { label = 'cell-00', severity = 'warning', masters = false },
  { label = 'deprecated-lists', severity = 'warning', masters = false },
  { label = 'dialogue-teleports', severity = 'warning', masters = false },
  { label = 'duplicate-info', severity = 'warning', masters = false },
  { label = 'expansion-dependency', severity = 'error', masters = false },
  { label = 'getsoundplaying', severity = 'info', masters = false },
  { label = 'menumode', severity = 'info', masters = false },
  { label = 'modified-info', severity = 'warning', masters = true },
  { label = 'modified-info-id', severity = 'warning', masters = false },
  { label = 'no-bloodmoon-functions', severity = 'info', masters = false },
  { label = 'no-tribunal-functions', severity = 'info', masters = false },
  { label = 'scripted-doors', severity = 'info', masters = false },
}

local Recommended = {
  'junk-cells',
  'missing-version',
  'fogbug',
  'fogsync',
  'bloodmoon-dependency',
  'deprecated-lists',
  'dialogue-teleports',
  'expansion-dependency',
  'modified-info-id',
}

--- A label as scripts spell it (jess-omwaddon's `camel_case_name`), dropping every separator:
--- `evilGmsts`, `cell00`.
local function camelCase(label: string): string
  return (string.gsub(label, '[-_](.?)', string.upper))
end

local Severities: { [string]: Severity } = {}
local NeedsMasters: { [string]: boolean } = {}
--- Each check's camelCase name by its label, and its label by every spelling of it: a finding is
--- named, and a name read, without spelling the checks out again. An earlier check keeps a
--- spelling a later one shares.
local CamelNames: { [string]: string }, Labels: { [string]: string } = {}, {}
for _, check in Checks do
  local label = check.label
  local camel = camelCase(label)
  Severities[label] = check.severity
  NeedsMasters[label] = check.masters
  CamelNames[label] = camel
  Labels[label] = Labels[label] or label
  Labels[string.gsub(label, '-', '_')] = Labels[string.gsub(label, '-', '_')] or label
  Labels[camel] = Labels[camel] or label
end

--- The check's label (`duplicate-records`) for any of its spellings: label, `snake_case`, or camelCase.
local function parseCheck(name: string): string
  return Labels[name] or error(`unknown lint check '{name}'`, 0)
end

export type CheckSet = { [string]: boolean }

--- The checks a preset (`all` or `recommended`) names.
local function preset(name: string): CheckSet
  local set: CheckSet = {}
  if name == 'all' then
    for _, check in Checks do
      set[check.label] = true
    end
  elseif name == 'recommended' then
    for _, label in Recommended do
      set[label] = true
    end
  else
    error(`unknown preset '{name}': expected all or recommended`, 0)
  end

  return set
end

--- The checks named (any spelling), or the recommended ones when none are.
local function checks(names: { string }?): CheckSet
  if not names or #names == 0 then return preset 'recommended' end

  local set: CheckSet = {}
  for _, name in names do
    set[parseCheck(name)] = true
  end

  return set
end

local function finding(check: string, message: string): Finding
  return { check = CamelNames[check], severity = Severities[check], message = message }
end

local function display(plugin: Plugin, index: number): string
  return tes3.tags.display(plugin:code(index))
end

local function idOf(plugin: Plugin, index: number): string
  return tes3.records.id(plugin, index) or ''
end

--- Whether a description has a line that starts with `version` (ignoring case and indent).
local function hasVersion(description: string): boolean
  for line in string.gmatch(description .. '\n', '([^\n]*)\n') do
    line = string.gsub(line, '\r$', '')
    if string.sub(string.lower(string.match(line, '^%s*(.*)$') :: string), 1, 7) == 'version' then
      return true
    end
  end

  return false
end

local CellTag, GmstTag, SpelTag, ScptTag, InfoTag, DoorTag, Tes3Tag =
  tes3.tags.code 'CELL',
  tes3.tags.code 'GMST',
  tes3.tags.code 'SPEL',
  tes3.tags.code 'SCPT',
  tes3.tags.code 'INFO',
  tes3.tags.code 'DOOR',
  tes3.tags.code 'TES3'
local TextTag, SctxTag = tes3.tags.code 'TEXT', tes3.tags.code 'SCTX'
local DataTag, ScriTag, NameTag, Nam0Tag =
  tes3.tags.code 'DATA', tes3.tags.code 'SCRI', tes3.tags.code 'NAME', tes3.tags.code 'NAM0'

--[[ Evil GMSTs ]]

type Evil = { expansion: string, kind: string, value: string | number }

--- tes3cmd's Evil GMSTs (`%EVIL_TB`, `%EVIL_BM`), by lowercase id: the 11 Tribunal and 61
--- Bloodmoon GMSTs the Construction Set copies into plugins with the expansions' default values.
--- One of these is only evil while it still has that value.
local EvilGmsts: { [string]: Evil } = {}
do
  local function add(id: string, expansion: string, kind: string, value: string | number)
    EvilGmsts[id] = { expansion = expansion, kind = kind, value = value }
  end

  local tribunalStrings = {
    { 'scompanionshare', 'Companion Share' },
    { 'scompanionwarningbuttonone', 'Let the mercenary quit.' },
    { 'scompanionwarningbuttontwo', 'Return to Companion Share display.' },
    {
      'scompanionwarningmessage',
      'Your mercenary is poorer now than when he contracted with you.  Your mercenary will quit if you do not give him gold or goods to bring his Profit Value to a positive value.',
    },
    { 'sdeletenote', 'Delete Note?' },
    { 'seffectsummonfabricant', 'sEffectSummonFabricant' },
    { 'slevitatedisabled', 'Levitation magic does not work here.' },
    { 'smagicfabricantid', 'Fabricant' },
    { 'smaxsale', 'Max Sale' },
    { 'sprofitvalue', 'Profit Value' },
    { 'steleportdisabled', 'Teleportation magic does not work here.' },
  }

  for _, entry in tribunalStrings do
    add(entry[1], 'Tribunal', 'STRV', entry[2])
  end

  local bloodmoonFloats = {
    { 'fcombatdistancewerewolfmod', 0.3 },
    { 'ffleedistance', 3000 },
    { 'fwerewolfacrobatics', 150 },
    { 'fwerewolfagility', 150 },
    { 'fwerewolfalchemy', 1 },
    { 'fwerewolfalteration', 1 },
    { 'fwerewolfarmorer', 1 },
    { 'fwerewolfathletics', 150 },
    { 'fwerewolfaxe', 1 },
    { 'fwerewolfblock', 1 },
    { 'fwerewolfbluntweapon', 1 },
    { 'fwerewolfconjuration', 1 },
    { 'fwerewolfdestruction', 1 },
    { 'fwerewolfenchant', 1 },
    { 'fwerewolfendurance', 150 },
    { 'fwerewolffatigue', 400 },
    { 'fwerewolfhandtohand', 100 },
    { 'fwerewolfhealth', 2 },
    { 'fwerewolfheavyarmor', 1 },
    { 'fwerewolfillusion', 1 },
    { 'fwerewolfintellegence', 1 },
    { 'fwerewolflightarmor', 1 },
    { 'fwerewolflongblade', 1 },
    { 'fwerewolfluck', 1 },
    { 'fwerewolfmagicka', 100 },
    { 'fwerewolfmarksman', 1 },
    { 'fwerewolfmediumarmor', 1 },
    { 'fwerewolfmerchantile', 1 },
    { 'fwerewolfmysticism', 1 },
    { 'fwerewolfpersonality', 1 },
    { 'fwerewolfrestoration', 1 },
    { 'fwerewolfrunmult', 1.5 },
    { 'fwerewolfsecurity', 1 },
    { 'fwerewolfshortblade', 1 },
    { 'fwerewolfsilverweapondamagemult', 1.5 },
    { 'fwerewolfsneak', 1 },
    { 'fwerewolfspear', 1 },
    { 'fwerewolfspeechcraft', 1 },
    { 'fwerewolfspeed', 150 },
    { 'fwerewolfstrength', 150 },
    { 'fwerewolfunarmored', 100 },
    { 'fwerewolfwillpower', 1 },
  }

  for _, entry in bloodmoonFloats do
    add(entry[1] :: string, 'Bloodmoon', 'FLTV', string.pack('<f', entry[2] :: number))
  end

  local bloodmoonInts = {
    { 'iwerewolfbounty', 10000 },
    { 'iwerewolffightmod', 100 },
    { 'iwerewolffleemod', 100 },
    { 'iwerewolfleveltoattack', 20 },
  }

  for _, entry in bloodmoonInts do
    add(entry[1] :: string, 'Bloodmoon', 'INTV', string.pack('<i4', entry[2] :: number))
  end

  local bloodmoonStrings = {
    { 'seditnote', 'Edit Note' },
    { 'seffectsummoncreature01', 'sEffectSummonCreature01' },
    { 'seffectsummoncreature02', 'sEffectSummonCreature02' },
    { 'seffectsummoncreature03', 'sEffectSummonCreature03' },
    { 'seffectsummoncreature04', 'sEffectSummonCreature04' },
    { 'seffectsummoncreature05', 'sEffectSummonCreature05' },
    { 'smagiccreature01id', 'sMagicCreature01ID' },
    { 'smagiccreature02id', 'sMagicCreature02ID' },
    { 'smagiccreature03id', 'sMagicCreature03ID' },
    { 'smagiccreature04id', 'sMagicCreature04ID' },
    { 'smagiccreature05id', 'sMagicCreature05ID' },
    { 'swerewolfalarmmessage', 'You have been detected changing from a werewolf state.' },
    { 'swerewolfpopup', 'Werewolf' },
    { 'swerewolfrefusal', 'You cannot do this as a werewolf.' },
    { 'swerewolfrestmessage', 'You cannot rest in werewolf form.' },
  }

  for _, entry in bloodmoonStrings do
    add(entry[1], 'Bloodmoon', 'STRV', entry[2])
  end
end

--- The expansion a GMST is an evil copy of, matching the id ignoring case and the value exactly
--- (a string with its trailing NULs ignored), as tes3cmd does; nil otherwise.
local function evilGmst(plugin: Plugin, index: number, id: string): string?
  if plugin:code(index) ~= GmstTag then return nil end

  local evil = EvilGmsts[string.lower(id)]
  if not evil then return nil end

  local source, at, size = plugin:findSubrecord(index, tes3.tags.code(evil.kind))
  if not source then return nil end

  local payload = buffer.readstring(source :: buffer, at, size)
  if evil.kind == 'STRV' then payload = string.gsub(payload, '%z+$', '') end

  return if payload == evil.value then evil.expansion else nil
end

--[[ Cells ]]

--- A CELL with nothing but its name, data, and reference count, so no references either.
local function isJunkCell(plugin: Plugin, index: number): boolean
  if plugin:code(index) ~= CellTag then return false end

  local source, start, finish = plugin:span(index)
  local position = start + 16
  while position < finish do
    local code = buffer.readu32(source, position)
    if code ~= NameTag and code ~= DataTag and code ~= Nam0Tag then return false end

    position += 8 + buffer.readu32(source, position + 4)
  end

  return true
end

--- Appends each repeated header subrecord (NAME and NAM0 aside) of CELL `index` to `out`:
--- `{ record, subrecord }`, 0-based.
local function cellDuplicates(plugin: Plugin, index: number, out: { { number } })
  local header = plugin:cellHeaderSubrecords(index) :: number
  local source, start = plugin:span(index)
  local seen: { [string]: boolean } = {}
  local position = start + 16
  for subrecord = 0, header - 1 do
    local code, size = buffer.readu32(source, position), buffer.readu32(source, position + 4)
    if code ~= NameTag and code ~= Nam0Tag then
      local key = buffer.readstring(source, position, 8 + size)
      if seen[key] then
        table.insert(out, { index, subrecord })
      else
        seen[key] = true
      end
    end

    position += 8 + size
  end
end

--- Each repeated CELL header subrecord (NAME and NAM0 aside): `{ record, subrecord }`, 0-based.
local function duplicateCellParams(plugin: Plugin): { { number } }
  local out = {}
  for index = 0, plugin:count() - 1 do
    if plugin:code(index) == CellTag then cellDuplicates(plugin, index, out) end
  end

  return out
end

--[[ Masters ]]

--- A master's path and size, if the source finds it.
local function masterFile(name: string, masters: Source): (string?, number)
  local path = masters.locate(name)
  if not path then return nil, 0 end

  local size = Masters.size(masters, path)
  if not size then error(`failed to read master '{name}': no such file`, 0) end

  return path, size
end

--- A master's place among the masters that were opened, times this, and a record's place in it,
--- are one number: a record's place is below 2^32, as its offset in the file is.
local MasterStride = 4294967296

--- Every record of the plugin's masters that can be found, by type (a tag as a number) and then
--- id: which of `plugins` it's in and where, as one number (a later master's copy wins). Nothing
--- is made for a record but that number, and no key is built to look one up. Masters are read in
--- the plugin's code page, as its ids are.
export type MasterRecords = { plugins: { Plugin }, places: { [number]: { [string]: number } } }

local function masterRecords(plugin: Plugin, masters: Source): MasterRecords
  local records: MasterRecords = { plugins = {}, places = {} }
  local places = records.places
  for _, master in plugin:masters() do
    local path = masters.locate(master.name)
    if not path then continue end

    local contents = Masters.read(masters, path)
    if not contents then error(`failed to read master '{master.name}': no such file`, 0) end

    -- tes3.open throws on a master that doesn't frame; that's the error to report.
    local ok, opened = pcall(
      function(): tes3.Plugin return tes3.open(contents, { encoding = plugin.encoding }) end
    )
    if not ok then error(`failed to read master '{master.name}': {opened}`, 0) end

    local other = opened :: Plugin
    table.insert(records.plugins, other)
    local base = #records.plugins * MasterStride
    for index = 0, other:count() - 1 do
      local id = tes3.records.id(other, index)
      if not id then continue end

      local code = other:code(index)
      local ofType = places[code]
      if not ofType then
        ofType = {}
        places[code] = ofType
      end

      ofType[id] = base + index
    end
  end

  return records
end

--- Where the masters have a record of type `code` called `id`: the master and the record's place
--- in it, or nil.
local function masterCopy(records: MasterRecords, code: number, id: string?): (Plugin?, number)
  local ofType = if id then records.places[code] else nil
  local place = ofType and ofType[id :: string]
  if not place then return nil, 0 end

  return records.plugins[place // MasterStride], place % MasterStride
end

--- Whether record `index` of `plugin` is byte for byte record `otherIndex` of `master`.
local function sameAsMaster(
  plugin: Plugin,
  index: number,
  master: Plugin,
  otherIndex: number
): boolean
  local source, start, finish = plugin:span(index)
  local other, otherStart, otherFinish = master:span(otherIndex)
  local length = finish - start
  if otherFinish - otherStart ~= length then return false end

  return bytes.compare(source, start, other, otherStart, length) == 0
end

--- An INFO's string fields joined by line breaks, as jess-omwaddon's `string_values` gives
--- them: every one, or with `textOnly` only the response text. Walks the subrecords in place.
local function infoText(plugin: Plugin, index: number, textOnly: boolean): string
  local source, start, finish = plugin:span(index)
  local first: string? = nil
  local values: { string }? = nil
  local position = start + 16
  while position < finish do
    local code, size = buffer.readu32(source, position), buffer.readu32(source, position + 4)
    -- An INFO's response text is its NAME (and a TEXT, if one is there).
    local wanted = if textOnly
      then code == NameTag or code == TextTag
      else tes3.records.fieldName(InfoTag, code) ~= nil
    if wanted then
      local value = tes3.text.decode(source, position + 8, size, plugin.encoding)
      if not first then
        first = value
      else
        values = values or { first :: string }
        table.insert(values :: { string }, value)
      end
    end

    position += 8 + size
  end

  if values then return table.concat(values, '\n') end

  return first or ''
end

--- Where `decode` would cut the text of `size` bytes at `at`: a final NUL dropped, then at the
--- first NUL. Its length.
local function cutLength(source: buffer, at: number, size: number): number
  local finish = at + size
  if size > 0 and buffer.readu8(source, finish - 1) == 0 then
    finish -= 1
  end

  local nul = bytes.find(source, '\0', at)
  return if nul and nul < finish then nul - at else finish - at
end

--- An INFO's response text as a token of `pool` (ASCII case ignored, every other byte exact, so
--- equal tokens are texts equal ignoring ASCII case once decoded), or nil when it's empty. The text
--- is interned from the record's bytes; only an INFO with several text fields makes a string.
local function infoTextToken(plugin: Plugin, index: number, pool: dream_intern_Pool): number?
  local source, start, finish = plugin:span(index)
  local firstAt, firstLength, parts = -1, 0, nil :: { string }?
  local position = start + 16
  while position < finish do
    local code, size = buffer.readu32(source, position), buffer.readu32(source, position + 4)
    if code == NameTag or code == TextTag then
      local length = cutLength(source, position + 8, size)
      if firstAt < 0 then
        firstAt, firstLength = position + 8, length
      else
        parts = parts or { buffer.readstring(source, firstAt, firstLength) }
        table.insert(parts :: { string }, buffer.readstring(source, position + 8, length))
      end
    end

    position += 8 + size
  end

  if parts then return pool:intern(table.concat(parts, '\n')) end

  if firstAt < 0 or firstLength == 0 then return nil end

  return pool:intern(source, firstAt, firstLength)
end

--[[ Lint ]]

--- The order lint reports in, jess-omwaddon's: each entry a check, or a group of checks that
--- report together (`header`, `expansions`, `masters`).
local Units = {
  'record-count',
  'header',
  'duplicate-records',
  'evil-gmsts',
  'cell-params',
  'junk-cells',
  'fogbug',
  'fogsync',
  'autocalc-spells',
  'cell-00',
  'deprecated-lists',
  'dialogue-teleports',
  'duplicate-info',
  'getsoundplaying',
  'menumode',
  'modified-info-id',
  'scripted-doors',
  'expansions',
  'masters',
  'overrides',
  'modified-info',
}

--- The checks that look at one record at a time: a slice of the records is linted for them on
--- its own (`lintSlice`), and the slices' findings joined in order are the plugin's.
local PerRecord: { [string]: boolean } = {
  ['evil-gmsts'] = true,
  ['cell-params'] = true,
  ['junk-cells'] = true,
  fogbug = true,
  fogsync = true,
  ['autocalc-spells'] = true,
  ['cell-00'] = true,
  ['deprecated-lists'] = true,
  ['dialogue-teleports'] = true,
  getsoundplaying = true,
  menumode = true,
  ['scripted-doors'] = true,
}

--- Findings by unit (see `Units`).
export type Parts = { [string]: { Finding } }

local function add(parts: Parts, unit: string, check: string, message: string)
  local list = parts[unit]
  if not list then
    list = {}
    parts[unit] = list
  end

  table.insert(list, finding(check, message))
end

--- Byte ranges to match, one per record: its buffer (false for none), offset, and length.
type Ranges = { sources: { buffer | false }, offsets: { number }, lengths: { number } }

--- Which of `ranges` `regex` matches: those in `base` in one native call, any other one (a record
--- an edit rebuilt) by itself.
local function matchRanges(regex: dream_bytes_Regex, base: buffer, ranges: Ranges): { boolean }
  local sources, offsets, lengths = ranges.sources, ranges.offsets, ranges.lengths
  local hits: { boolean }, slots: { number } = {}, {}
  local spans = buffer.create(#sources * 8)
  local used = 0
  for rangeIndex, source in sources do
    hits[rangeIndex] = false
    if not source then continue end

    if source ~= base then
      hits[rangeIndex] = regex:isMatch(source, offsets[rangeIndex], lengths[rangeIndex])
      continue
    end

    buffer.writeu32(spans, used * 8, offsets[rangeIndex])
    buffer.writeu32(spans, used * 8 + 4, offsets[rangeIndex] + lengths[rangeIndex])
    used += 1
    slots[used] = rangeIndex
  end

  if used == 0 then return hits end

  local flags = regex:matchSpans(base, spans, used)
  for slot = 1, used do
    if buffer.readu8(flags, slot - 1) == 1 then hits[slots[slot]] = true end
  end

  return hits
end

--- Each record's whole bytes.
local function recordRanges(plugin: Plugin, indices: { number }): Ranges
  local sources: { buffer | false }, offsets: { number }, lengths: { number } = {}, {}, {}
  for rangeIndex, index in indices do
    local source, start, finish = plugin:span(index)
    sources[rangeIndex], offsets[rangeIndex], lengths[rangeIndex] = source, start, finish - start
  end

  return { sources = sources, offsets = offsets, lengths = lengths }
end

--- Each script's text where it lies: its SCTX payload up to its first NUL, the bytes decoding
--- keeps (a final NUL dropped, then cut at the first), or false for a script with no SCTX.
local function scriptRanges(plugin: Plugin, indices: { number }): Ranges
  local sources: { buffer | false }, offsets: { number }, lengths: { number } = {}, {}, {}
  for rangeIndex, index in indices do
    local source, at, size = plugin:findSubrecord(index, SctxTag)
    if not source then
      sources[rangeIndex], offsets[rangeIndex], lengths[rangeIndex] = false, 0, 0
      continue
    end

    local nul = bytes.find(source, '\0', at)
    sources[rangeIndex], offsets[rangeIndex] = source, at
    lengths[rangeIndex] = if nul and nul < at + size then nul - at else size
  end

  return { sources = sources, offsets = offsets, lengths = lengths }
end

--- Whether any of `ranges` matches.
local function anyMatch(regex: dream_bytes_Regex, base: buffer, ranges: Ranges): boolean
  for _, hit in matchRanges(regex, base, ranges) do
    if hit then return true end
  end

  return false
end

--[[
Patterns run over record bytes in place, never decoding a record to look at it. jess-omwaddon
matches its patterns on decoded text (Unicode case folding and word boundaries); each such check
here has the same pattern in ASCII mode run first over the raw bytes, and decodes only the records
it finds. That never misses: every code page a plugin is read in maps each byte to one character
and ASCII to itself, none of them has a character that folds to an ASCII letter (U+017F, U+212A),
and an ASCII word boundary is found wherever a Unicode one is next to an ASCII letter. Words found
with `string.lower` and a plain search (autocalc, menumode, the expansion functions) match the raw bytes
exactly in ASCII mode.
]]

local DeprecatedLists = [[(?i)\b(additem|removeitem)\b.*\b(leveled|levi|levc)]]
local GetSoundPlaying = [[(?i)\bgetsoundplaying\b]]
local Patterns = table.freeze {
  deprecatedLists = bytes.regex(DeprecatedLists),
  deprecatedListsBytes = bytes.regex(DeprecatedLists, { unicode = false }),
  getSoundPlaying = bytes.regex(GetSoundPlaying),
  getSoundPlayingBytes = bytes.regex(GetSoundPlaying, { unicode = false }),
  teleports = bytes.regex [[(?i)\b(position|positioncell)\b]],
  -- Next to a subrecord header in the raw record, a word boundary may not be one: none is asked.
  teleportsBytes = bytes.regex([[(?i)position]], { unicode = false }),
  autocalc = bytes.regex([[(?i)autocalc]], { unicode = false }),
  menuMode = bytes.regex([[(?i)menumode]], { unicode = false }),
  bloodmoon = bytes.regex([[(?i)togglecollisiongrid|getsoundplaying]], { unicode = false }),
  tribunal = bytes.regex([[(?i)startscript|modregion]], { unicode = false }),
}

--- Records by type, in order, for records `first` to `last` (0-based, inclusive).
local function recordsByCode(plugin: Plugin, first: number, last: number): { [number]: { number } }
  local byCode: { [number]: { number } } = {}
  for index = first, last do
    local code = plugin:code(index)
    local list = byCode[code]
    if not list then
      list = {}
      byCode[code] = list
    end

    table.insert(list, index)
  end

  return byCode
end

--- Runs the per-record checks in `has` over the records `byCode` lists, into `parts`.
local function recordChecks(
  plugin: Plugin,
  has: CheckSet,
  byCode: { [number]: { number } },
  parts: Parts
)
  local function indicesOf(code: number): { number } return byCode[code] or {} end

  local base = plugin.source
  if has['evil-gmsts'] then
    for _, index in indicesOf(GmstTag) do
      local id = tes3.records.id(plugin, index)
      local expansion = if id then evilGmst(plugin, index, id) else nil
      if expansion then
        add(
          parts,
          'evil-gmsts',
          'evil-gmsts',
          `GMST {id} at record {index} has {expansion}'s default value`
        )
      end
    end
  end

  -- The cell checks, in one pass over the cells.
  if has['cell-params'] or has['junk-cells'] or has.fogbug or has.fogsync or has['cell-00'] then
    local duplicates: { { number } } = {}
    local scratch = buffer.create(8)
    for _, index in indicesOf(CellTag) do
      if has['cell-params'] then cellDuplicates(plugin, index, duplicates) end

      if has['junk-cells'] and isJunkCell(plugin, index) then
        add(parts, 'junk-cells', 'junk-cells', `CELL {idOf(plugin, index)} at record {index}`)
      end

      if has.fogbug or has.fogsync then
        local ambient = tes3.records.cellAmbientFogDensity(plugin, index)
        if has.fogbug and tes3.records.cellIsInterior(plugin, index) and ambient == 0 then
          add(
            parts,
            'fogbug',
            'fogbug',
            `CELL {idOf(plugin, index)} at record {index} has zero fog density`
          )
        end

        local data = if has.fogsync and ambient
          then tes3.records.cellDataFogDensity(plugin, index)
          else nil
        if ambient and data then
          -- Compared bit for bit, as the Rust check compares `to_bits`.
          buffer.writef32(scratch, 0, ambient)
          buffer.writef32(scratch, 4, data)
          if buffer.readu32(scratch, 0) ~= buffer.readu32(scratch, 4) then
            add(
              parts,
              'fogsync',
              'fogsync',
              `CELL {idOf(plugin, index)} at record {index} DATA fog {Numbers.floatText(data)} differs from AMBI fog {Numbers.floatText(
                ambient
              )}`
            )
          end
        end
      end

      if has['cell-00'] and tes3.records.cellIsExterior(plugin, index) then
        local source, start, finish = plugin:span(index)
        local position = start + 16
        while position < finish do
          local code, size = buffer.readu32(source, position), buffer.readu32(source, position + 4)
          if
            code == DataTag
            and size >= 12
            and buffer.readu32(source, position + 12) == 0
            and buffer.readu32(source, position + 16) == 0
          then
            add(parts, 'cell-00', 'cell-00', `CELL {idOf(plugin, index)} at record {index}`)
          end

          position += 8 + size
        end
      end
    end

    for _, entry in duplicates do
      local tag = plugin:subrecords(entry[1])[entry[2] + 1].tag
      add(parts, 'cell-params', 'cell-params', `duplicate {tag} in CELL record {entry[1]}`)
    end
  end

  if has['autocalc-spells'] then
    local spells = indicesOf(SpelTag)
    for rangeIndex, hit in matchRanges(Patterns.autocalc, base, recordRanges(plugin, spells)) do
      if hit then
        add(
          parts,
          'autocalc-spells',
          'autocalc-spells',
          `SPEL {idOf(plugin, spells[rangeIndex])} at record {spells[rangeIndex]}`
        )
      end
    end
  end

  local scripts = indicesOf(ScptTag)
  local texts = if has['deprecated-lists']
      or has.getsoundplaying
      or has.menumode
    then scriptRanges(plugin, scripts)
    else nil

  local function scriptRegex(check: string, exact: dream_bytes_Regex, superset: dream_bytes_Regex)
    for rangeIndex, hit in matchRanges(superset, base, texts :: Ranges) do
      if not hit then continue end

      local index = scripts[rangeIndex]
      if exact:isMatch(tes3.records.scriptText(plugin, index) :: string) then
        add(parts, check, check, `SCPT {idOf(plugin, index)} at record {index}`)
      end
    end
  end

  if has['deprecated-lists'] then
    scriptRegex('deprecated-lists', Patterns.deprecatedLists, Patterns.deprecatedListsBytes)
  end

  if has['dialogue-teleports'] then
    local infos = indicesOf(InfoTag)
    for rangeIndex, hit in
      matchRanges(Patterns.teleportsBytes, base, recordRanges(plugin, infos))
    do
      if not hit then continue end

      local index = infos[rangeIndex]
      if Patterns.teleports:isMatch(infoText(plugin, index, false)) then
        add(
          parts,
          'dialogue-teleports',
          'dialogue-teleports',
          `INFO {idOf(plugin, index)} at record {index}`
        )
      end
    end
  end

  if has.getsoundplaying then
    scriptRegex('getsoundplaying', Patterns.getSoundPlaying, Patterns.getSoundPlayingBytes)
  end

  if has.menumode then
    local ranges = texts :: Ranges
    for rangeIndex, hit in matchRanges(Patterns.menuMode, base, ranges) do
      if ranges.sources[rangeIndex] and not hit then
        add(
          parts,
          'menumode',
          'menumode',
          `SCPT {idOf(plugin, scripts[rangeIndex])} at record {scripts[rangeIndex]}`
        )
      end
    end
  end

  if has['scripted-doors'] then
    for _, index in indicesOf(DoorTag) do
      if plugin:findSubrecord(index, ScriTag) then
        add(
          parts,
          'scripted-doors',
          'scripted-doors',
          `DOOR {idOf(plugin, index)} at record {index}`
        )
      end
    end
  end
end

--- The per-record checks' findings (see `PerRecord`) for records `first` to `last` (0-based,
--- inclusive), by check: what `lint` joins, slice by slice, when the slices are linted apart.
local function lintSlice(plugin: Plugin, set: CheckSet?, first: number, last: number): Parts
  local parts: Parts = {}
  recordChecks(plugin, set or preset 'recommended', recordsByCode(plugin, first, last), parts)
  return parts
end

--- The findings of the checks in `set` (default: recommended) on `plugin`; masters resolve through
--- `masters` (default: none). When the per-record checks were linted apart (`lintSlice`), `slices`
--- gives their findings, in record order and covering every record; it's called after every other
--- check ran.
local function lint(
  plugin: Plugin,
  set: CheckSet?,
  masters: Source?,
  slices: (() -> { Parts })?
): { Finding }
  local has = set or preset 'recommended'
  local source = masters or Masters.none()
  local count = plugin:count()
  local parts: Parts = {}
  -- Most checks look at one record type: each type's records, in order, listed once.
  local byCode = recordsByCode(plugin, 0, count - 1)
  local function indicesOf(code: number): { number } return byCode[code] or {} end

  -- Ids compared ignoring ASCII case are tokens, interned from the record bytes once.
  local nocase: dream_intern_Pool = intern.new 'ascii-nocase'
  local tokens: { number | false } = {}
  local function tokenAt(index: number): number?
    local cached = tokens[index + 1]
    if cached ~= nil then return cached or nil end

    local idSource, at, length = tes3.records.idSpan(plugin, index)
    if not idSource then
      tokens[index + 1] = false
      return nil
    end

    local token = nocase:intern(idSource, at, length)
    tokens[index + 1] = token
    return token
  end

  -- Most checks look records up by id, so each id is read once.
  local ids: { string | false } = {}
  local function idAt(index: number): string?
    local cached = ids[index + 1]
    if cached ~= nil then return cached or nil end

    local id = tes3.records.id(plugin, index)
    ids[index + 1] = id or false
    return id
  end

  if has['record-count'] then
    local header = plugin:header()
    local actual = count - #indicesOf(Tes3Tag)
    if header.recordCount ~= actual then
      add(
        parts,
        'record-count',
        'record-count',
        `HEDR has {header.recordCount}, actual is {actual}`
      )
    end
  end

  if has['missing-author'] or has['missing-description'] or has['missing-version'] then
    local header = plugin:header()
    if has['missing-author'] and header.author == '' then
      add(parts, 'header', 'missing-author', 'TES3 author is empty')
    end

    if has['missing-description'] and header.description == '' then
      add(parts, 'header', 'missing-description', 'TES3 description is empty')
    end

    if has['missing-version'] and not hasVersion(header.description) then
      add(parts, 'header', 'missing-version', 'TES3 description has no Version line')
    end
  end

  if has['duplicate-records'] then
    -- jess-omwaddon keys `TAG:id` lowercased, so tags that differ only in case share ids.
    local seen: { [string]: { [number]: number } } = {}
    local ofCode: { [number]: { [number]: number } } = {}
    for index = 0, count - 1 do
      local token = tokenAt(index)
      if not token then continue end

      local code = plugin:code(index)
      local ofType = ofCode[code]
      if not ofType then
        local lower = string.lower(tes3.tags.display(code))
        ofType = seen[lower] or {}
        seen[lower], ofCode[code] = ofType, ofType
      end

      local first = ofType[token]
      ofType[token] = index
      if first then
        add(
          parts,
          'duplicate-records',
          'duplicate-records',
          `{display(plugin, index)} {idAt(index)} at record {index} duplicates record {first}`
        )
      end
    end
  end

  if has['duplicate-info'] then
    local seen: { [number]: number } = {}
    for _, index in indicesOf(InfoTag) do
      local token = tokenAt(index)
      if not token then continue end

      local first = seen[token]
      seen[token] = index
      if first then
        add(
          parts,
          'duplicate-info',
          'duplicate-info',
          `INFO {idAt(index)} at record {index} duplicates record {first}`
        )
      end
    end
  end

  if has['modified-info-id'] then
    local texts: dream_intern_Pool = intern.new 'ascii-nocase'
    local byText: { [number]: number } = {}
    for _, index in indicesOf(InfoTag) do
      local token = tokenAt(index)
      if not token then continue end

      local text = infoTextToken(plugin, index, texts)
      if not text then continue end

      local before = byText[text]
      byText[text] = index
      if before and tokenAt(before) ~= token then
        add(
          parts,
          'modified-info-id',
          'modified-info-id',
          `INFO {idAt(index)} at record {index} duplicates text from {idAt(before)}`
        )
      end
    end
  end

  if
    has['bloodmoon-dependency']
    or has['expansion-dependency']
    or has['no-bloodmoon-functions']
    or has['no-tribunal-functions']
  then
    local bloodmoonMaster, tribunalMaster = false, false
    for _, master in plugin:masters() do
      local lower = string.lower(master.name)
      if lower == 'bloodmoon.esm' then bloodmoonMaster = true end

      if lower == 'tribunal.esm' then tribunalMaster = true end
    end

    local texts = scriptRanges(plugin, indicesOf(ScptTag))
    local usesBloodmoon = anyMatch(Patterns.bloodmoon, plugin.source, texts)
    local usesTribunal = anyMatch(Patterns.tribunal, plugin.source, texts)
    if has['bloodmoon-dependency'] and usesBloodmoon and not bloodmoonMaster then
      add(
        parts,
        'expansions',
        'bloodmoon-dependency',
        'Bloodmoon function use without Bloodmoon.esm master'
      )
    end

    if
      has['expansion-dependency']
      and (usesBloodmoon or usesTribunal)
      and not bloodmoonMaster
      and not tribunalMaster
    then
      add(
        parts,
        'expansions',
        'expansion-dependency',
        'expansion function use without expansion master'
      )
    end

    if has['no-bloodmoon-functions'] and bloodmoonMaster and not usesBloodmoon then
      add(
        parts,
        'expansions',
        'no-bloodmoon-functions',
        'Bloodmoon.esm is listed but no Bloodmoon functions were detected'
      )
    end

    if has['no-tribunal-functions'] and tribunalMaster and not usesTribunal then
      add(
        parts,
        'expansions',
        'no-tribunal-functions',
        'Tribunal.esm is listed but no Tribunal functions were detected'
      )
    end
  end

  if has['missing-master'] or has['master-sync'] then
    for _, master in plugin:masters() do
      local path, size = masterFile(master.name, source)
      if path and has['master-sync'] and master.size ~= size then
        add(
          parts,
          'masters',
          'master-sync',
          `{master.name} DATA has {master.size}, actual is {size} ({path})`
        )
      elseif not path and has['missing-master'] then
        add(parts, 'masters', 'missing-master', master.name)
      end
    end
  end

  local found: MasterRecords? = nil
  local function mastersOf(): MasterRecords
    found = found or masterRecords(plugin, source)
    return found :: MasterRecords
  end

  if has.overrides and next(mastersOf().places) then
    local records = mastersOf()
    for index = 0, count - 1 do
      local code = plugin:code(index)
      if code == Tes3Tag then continue end

      local id = idAt(index)
      if masterCopy(records, code, id) then
        add(parts, 'overrides', 'overrides', `{display(plugin, index)} {id} at record {index}`)
      end
    end
  end

  if has['modified-info'] and next(mastersOf().places) then
    local records = mastersOf()
    for _, index in indicesOf(InfoTag) do
      local id = idAt(index)
      local master, otherIndex = masterCopy(records, InfoTag, id)
      if master and not sameAsMaster(plugin, index, master, otherIndex) then
        add(parts, 'modified-info', 'modified-info', `INFO {id} at record {index}`)
      end
    end
  end

  -- The per-record checks last, so slices linted elsewhere had the whole-plugin checks' time.
  if slices then
    for _, slice in slices() do
      for unit, findings in slice do
        if not PerRecord[unit] then continue end

        local list = parts[unit]
        if not list then
          list = {}
          parts[unit] = list
        end

        table.move(findings, 1, #findings, #list + 1, list)
      end
    end
  else
    recordChecks(plugin, has, byCode, parts)
  end

  local out: { Finding } = {}
  for _, unit in Units do
    local findings = parts[unit]
    if findings then table.move(findings, 1, #findings, #out + 1, out) end
  end

  return out
end

--[[ Clean ]]

export type CleanChecks = {
  duplicateRecords: boolean?,
  evilGmsts: boolean?,
  junkCells: boolean?,
  cellParams: boolean?,
}

export type CleanReport = {
  removedRecords: number,
  removedSubrecords: number,
  --- The positions the removed records had before cleaning, ascending (0-based).
  removedRecordIndices: { number },
  --- Whether the header's record count was set to match.
  recordCountUpdated: boolean,
}

--- The record types a duplicate of a master's copy is removed from.
local CleanableTags = {
  'ACTI',
  'ALCH',
  'APPA',
  'ARMO',
  'BODY',
  'BOOK',
  'BSGN',
  'CELL',
  'CLAS',
  'CLOT',
  'CONT',
  'CREA',
  'DOOR',
  'ENCH',
  'FACT',
  'GLOB',
  'GMST',
  'INFO',
  'INGR',
  'LAND',
  'LEVC',
  'LEVI',
  'LIGH',
  'LOCK',
  'MGEF',
  'MISC',
  'NPC_',
  'PGRD',
  'PROB',
  'RACE',
  'REGN',
  'REPA',
  'SCPT',
  'SKIL',
  'SNDG',
  'SOUN',
  'SPEL',
  'SSCR',
  'STAT',
  'WEAP',
}

local Cleanable: { [number]: boolean } = {}
for _, tag in CleanableTags do
  Cleanable[tes3.tags.code(tag)] = true
end

--- Removes the safe dirt `which` sets to true (with none, every kind not set to false), and sets the header's
--- record count to match when records went, unless `recordCount` is `'keep'`.
local function clean(
  plugin: Plugin,
  which: CleanChecks?,
  masters: Source?,
  recordCount: ('update' | 'keep')?
): CleanReport
  local want: CleanChecks = which or {}
  if not (want.duplicateRecords or want.evilGmsts or want.junkCells or want.cellParams) then
    want = {
      duplicateRecords = want.duplicateRecords ~= false,
      evilGmsts = want.evilGmsts ~= false,
      junkCells = want.junkCells ~= false,
      cellParams = want.cellParams ~= false,
    }
  end

  local count = plugin:count()
  local remove: { [number]: boolean } = {}
  if want.duplicateRecords then
    local seen: { [string]: boolean } = {}
    for index = 0, count - 1 do
      local id = tes3.records.id(plugin, index)
      if not id then continue end

      local key = string.lower(`{display(plugin, index)}:{id}`)
      if seen[key] then
        remove[index] = true
      else
        seen[key] = true
      end
    end

    local records = masterRecords(plugin, masters or Masters.none())
    for index = 0, count - 1 do
      local code = plugin:code(index)
      if code == Tes3Tag or not Cleanable[code] then continue end

      local master, otherIndex = masterCopy(records, code, tes3.records.id(plugin, index))
      if master and sameAsMaster(plugin, index, master, otherIndex) then remove[index] = true end
    end
  end

  if want.evilGmsts then
    for index = 0, count - 1 do
      if plugin:code(index) ~= GmstTag then continue end

      local id = tes3.records.id(plugin, index)
      if id and evilGmst(plugin, index, id) then remove[index] = true end
    end
  end

  if want.junkCells then
    for index = 0, count - 1 do
      if isJunkCell(plugin, index) then remove[index] = true end
    end
  end

  local indices = {}
  for index in remove do
    table.insert(indices, index)
  end

  table.sort(indices)
  if #indices > 0 then plugin:retain(function(index) return not remove[index] end) end

  local removedSubrecords = 0
  if want.cellParams then
    local deletions = duplicateCellParams(plugin)
    removedSubrecords = #deletions
    for position = #deletions, 1, -1 do
      plugin:deleteSubrecord(deletions[position][1], deletions[position][2])
    end
  end

  local updated = plugin:applyRecordCount(recordCount or 'update', #indices > 0)
  return {
    removedRecords = #indices,
    removedSubrecords = removedSubrecords,
    removedRecordIndices = indices,
    recordCountUpdated = updated,
  }
end

--[[ Validate ]]

--- What `validate` ran (camelCase, like `recordContents`) and found.
export type Validation = { checks: { string }, diagnostics: { tes3.Diagnostic } }

--- Checks `plugin` against `profile` (jess-omwaddon's `validate`): its framing and tags, and for
--- `omwaddon` also that every record OpenMW loads reads the way its loaders read it, since one
--- that doesn't stops the file loading.
local function validate(plugin: Plugin, profile: tes3.Profile): Validation
  local names = table.clone(tes3.checks(profile))
  local diagnostics = plugin:validateProfile(profile)
  if profile == 'omwaddon' then
    table.insert(names, 'record_contents')
    for index = 0, plugin:count() - 1 do
      if not tes3.typeName(plugin:tag(index)) then continue end

      -- A record that doesn't decode is the finding; its error is the message.
      local ok, problem = pcall(plugin.decode, plugin, index)
      if ok then continue end

      local id = tes3.records.fieldId(plugin, index)
      local named = if id and id ~= '' then ` {id}` else ''
      table.insert(diagnostics, {
        offset = (plugin:range(index)),
        message = `{display(plugin, index)}{named} doesn't read the way OpenMW reads it: {problem}`,
      })
    end

    -- Stable, as Rust's `sort_by_key` is: ties keep their order.
    local order: { [tes3.Diagnostic]: number } = {}
    for position, diagnostic in diagnostics do
      order[diagnostic] = position
    end

    table.sort(diagnostics, function(left: tes3.Diagnostic, right: tes3.Diagnostic)
      if left.offset ~= right.offset then return left.offset < right.offset end

      return order[left] < order[right]
    end)
  end

  for position, name in names do
    names[position] = tes3.text.camelCase(name)
  end

  return { checks = names, diagnostics = diagnostics }
end

--[[ Header ]]

export type MasterSizeChange = { name: string, oldSize: number, newSize: number, path: string }

--- Sets every master's recorded size to its file's size.
local function syncMasters(plugin: Plugin, masters: Source): { MasterSizeChange }
  local changes = {}
  for _, master in plugin:masters() do
    local path, size = masterFile(master.name, masters)
    if not path then error(`failed to resolve TES3 master '{master.name}'`, 0) end

    if plugin:setMasterSize(master.name, size) then
      table.insert(
        changes,
        { name = master.name, oldSize = master.size, newSize = size, path = path }
      )
    end
  end

  return changes
end

export type HeaderUpdate = {
  author: string?,
  description: string?,
  fileType: tes3.FileType?,
  --- Set each master's recorded size to its file's size.
  syncMasters: boolean?,
  --- Set the record count to the number of records.
  recordCount: boolean?,
}

--- Applies `update` to the TES3 header; whether anything changed, and the masters synced.
local function updateHeader(
  plugin: Plugin,
  update: HeaderUpdate,
  masters: Source?
): (boolean, { MasterSizeChange })
  local changed = false
  if update.author then changed = plugin:setAuthor(update.author) or changed end

  if update.description then changed = plugin:setDescription(update.description) or changed end

  if update.fileType then changed = plugin:setFileType(update.fileType) or changed end

  local synced = {}
  if update.syncMasters then
    synced = syncMasters(plugin, masters or Masters.none())
    changed = changed or #synced > 0
  end

  if update.recordCount then changed = plugin:updateRecordCount() or changed end

  return changed, synced
end

return table.freeze {
  Checks = Checks,
  camelCase = camelCase,
  checks = checks,
  clean = clean,
  hasVersion = hasVersion,
  lint = lint,
  lintSlice = lintSlice,
  parseCheck = parseCheck,
  preset = preset,
  syncMasters = syncMasters,
  updateHeader = updateHeader,
  validate = validate,
}
