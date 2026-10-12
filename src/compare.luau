--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Comparing plugins (jess-omwaddon's `compare`, tes3cmd's `common`, `diff`, and `overdial`): byte
comparisons, records in common, record-level diffs with typed field changes, overlapping dialogue
topics, and the records a load order overrides.
]]

local bytes = require '@dream/bytes'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin

export type Key = { type: string, id: string }

--- Whether two records are the same bytes, read where they are: nothing is copied to compare.
local function sameRecord(left: Plugin, leftIndex: number, right: Plugin, rightIndex: number): boolean
  local leftSource, leftStart, leftFinish = left:span(leftIndex)
  local rightSource, rightStart, rightFinish = right:span(rightIndex)
  local length = leftFinish - leftStart
  return length == rightFinish - rightStart
    and bytes.compare(leftSource, leftStart, rightSource, rightStart, length) == 0
end

export type ByteComparison = {
  identical: boolean,
  leftBytes: number,
  rightBytes: number,
  --- The first offset where they differ: the shorter one's length when one is a prefix.
  firstDifference: number?,
}

--- Where two runs of bytes first differ, counted from their starts: the shorter one's length when
--- it is how the other starts, and nil when they are the same bytes. Nothing is copied.
local function firstMismatch(
  left: buffer,
  leftStart: number,
  leftLength: number,
  right: buffer,
  rightStart: number,
  rightLength: number
): number?
  local common = math.min(leftLength, rightLength)
  if common == 0 or bytes.compare(left, leftStart, right, rightStart, common) == 0 then
    return if leftLength ~= rightLength then common else nil
  end

  -- The first byte that differs is in `low` up to `high`. A comparison stops at it, so halving
  -- to it reads the bytes before it twice over at most.
  local low, high = 0, common
  while high - low > 1 do
    local middle = low + (high - low) // 2
    if bytes.compare(left, leftStart + low, right, rightStart + low, middle - low) == 0 then
      low = middle
    else
      high = middle
    end
  end

  return low
end

--- Whether two byte strings are the same, and where they first differ.
local function compareBytes(left: buffer, right: buffer): ByteComparison
  local leftLength, rightLength = buffer.len(left), buffer.len(right)
  local first = firstMismatch(left, 0, leftLength, right, 0, rightLength)
  return {
    identical = first == nil,
    leftBytes = leftLength,
    rightBytes = rightLength,
    firstDifference = first,
  }
end

--- A record's key as one string, its type as displayed and its id with a NUL between. No type is
--- displayed with a NUL and nothing sorts before one, so these strings sort as their types and
--- then their ids do, with no comparator to call.
local function keyOf(tag: string, id: string): string return tag .. '\0' .. id end

--- The key such a string is.
local function keyFrom(text: string): Key
  local split = string.find(text, '\0', 1, true) :: number
  return { type = string.sub(text, 1, split - 1), id = string.sub(text, split + 1) }
end

--- The records both plugins have, by type and id, without their TES3 headers; sorted.
local function common(left: Plugin, right: Plugin): { Key }
  -- Only whether the left plugin has a record is asked of it, so its keys are never listed.
  local inLeft: { [string]: boolean } = {}
  for index = 0, left:count() - 1 do
    local id = tes3.records.id(left, index)
    if id then inLeft[keyOf(tes3.tags.display(left:code(index)), id)] = true end
  end

  return [
    for key in tes3.records.objectKeys(right)
    if key.type ~= 'TES3' and inLeft[keyOf(key.type, key.id)]
    => key
  ]
end

--- Where every identified record is, by key (the last copy of a repeated key), skipping
--- `ignored`, and for a key the plugin has more than once where its first copy is. A record's
--- bytes stay where the plugin has them.
local function objectMap(
  plugin: Plugin,
  ignored: { [string]: boolean }
): ({ [string]: number }, { [string]: number })
  local positions: { [string]: number }, firsts: { [string]: number } = {}, {}
  for index = 0, plugin:count() - 1 do
    local tag = tes3.tags.display(plugin:code(index))
    if ignored[tag] then continue end

    local id = tes3.records.id(plugin, index)
    if not id then continue end

    local key = keyOf(tag, id)
    local earlier = positions[key]
    if earlier and not firsts[key] then firsts[key] = earlier end

    positions[key] = index
  end

  return positions, firsts
end

export type FieldChange = { field: string, left: string, right: string }
export type ChangedRecord =
  { type: string, id: string, rawChanged: boolean, fields: { FieldChange } }
export type DiffReport = {
  leftOnly: { Key },
  rightOnly: { Key },
  equal: { Key }?,
  changed: { ChangedRecord },
}

--- Record `index`'s typed string fields as `name[subrecord]` to value: none without a record, or
--- for one of a type jess has no name for.
local function fieldMap(plugin: Plugin, index: number?): { [string]: string }
  local fields: { [string]: string } = {}
  if not index or not tes3.typeName(plugin:tag(index)) then return fields end

  for _, field in tes3.records.stringFields(plugin, index) do
    fields[`{field.name}[{field.subrecord}]`] = field.value
  end

  return fields
end

--- The typed string fields that differ between a record of each plugin; fields on only one side
--- aren't reported. Sorted by field.
local function changesBetween(
  left: Plugin,
  leftIndex: number?,
  right: Plugin,
  rightIndex: number?
): { FieldChange }
  local leftFields, rightFields = fieldMap(left, leftIndex), fieldMap(right, rightIndex)
  local names = {}
  for name, value in leftFields do
    if rightFields[name] ~= nil and rightFields[name] ~= value then table.insert(names, name) end
  end

  table.sort(names)
  return [for name in names => { field = name, left = leftFields[name], right = rightFields[name] }]
end

--- The typed string fields that differ between `key`'s record in each plugin: the first one of
--- its type and id that each has. Sorted by field.
local function fieldChanges(left: Plugin, right: Plugin, key: Key): { FieldChange }
  local leftIndex = tes3.records.find(left, key.type, key.id)
  return changesBetween(left, leftIndex, right, tes3.records.find(right, key.type, key.id))
end

--- Two plugins' identified records compared by type, id, and bytes, skipping the `ignore` types
--- (tags or type names); `equal` also lists the identical ones.
local function diff(left: Plugin, right: Plugin, ignore: { string }?, equal: boolean?): DiffReport
  local ignored: { [string]: boolean } = {}
  for _, value in ignore or {} do
    local tag = string.lower(value) == 'npc' and 'NPC_'
      or tes3.tagNamed(value)
      or string.upper(value)
    ignored[tag] = true
  end

  local leftPositions, leftFirsts = objectMap(left, ignored)
  local rightPositions, rightFirsts = objectMap(right, ignored)
  local leftOnly: { string }, rightOnly: { string } = {}, {}
  local same: { string }, changed: { string } = {}, {}
  for key, index in leftPositions do
    local other = rightPositions[key]
    if other == nil then
      table.insert(leftOnly, key)
    elseif not sameRecord(left, index, right, other) then
      table.insert(changed, key)
    elseif equal then
      table.insert(same, key)
    end
  end

  for key in rightPositions do
    if leftPositions[key] == nil then table.insert(rightOnly, key) end
  end

  table.sort(leftOnly)
  table.sort(rightOnly)
  table.sort(same)
  table.sort(changed)
  local report: DiffReport = {
    leftOnly = [for text in leftOnly => keyFrom(text)],
    rightOnly = [for text in rightOnly => keyFrom(text)],
    changed = {},
  }

  for _, text in changed do
    local key = keyFrom(text)
    -- A changed record's fields are those of the first copy of it each plugin has. A tag that
    -- isn't text is displayed in more than its four bytes, and no record is looked up by that:
    -- `fieldChanges` refuses it, as it does when asked for such a key.
    local fields = if #key.type == 4
      then changesBetween(
        left,
        leftFirsts[text] or leftPositions[text],
        right,
        rightFirsts[text] or rightPositions[text]
      )
      else fieldChanges(left, right, key)
    table.insert(report.changed, { type = key.type, id = key.id, rawChanged = true, fields = fields })
  end

  if equal then report.equal = [for text in same => keyFrom(text)] end

  return report
end

export type TopicOverlap = {
  earlierPlugin: string,
  laterPlugin: string,
  outerTopic: string,
  innerTopic: string,
}

--- Topics in one plugin that contain a different topic from a later plugin, ignoring case. With
--- `single`, only the first plugin's topics are compared with the rest. `plugins` is a list of
--- `{ name, topics }`.
local function overlaps(
  plugins: { { name: string, topics: { string } } },
  single: boolean?
): { TopicOverlap }
  local out = {}
  local earlier = if single then math.min(#plugins, 1) else #plugins
  -- Every plugin's topics in lower case, made once: each is compared with every topic of every
  -- other plugin.
  local lowered = [for plugin in plugins => [for topic in plugin.topics => string.lower(topic)]]
  for leftIndex = 1, earlier do
    for rightIndex = leftIndex + 1, #plugins do
      local left, right = plugins[leftIndex], plugins[rightIndex]
      local leftLowers, rightLowers = lowered[leftIndex], lowered[rightIndex]
      for leftAt, leftTopic in left.topics do
        local leftLower = leftLowers[leftAt]
        local leftLength = #leftLower
        for rightAt, rightTopic in right.topics do
          local rightLower = rightLowers[rightAt]
          -- A topic is only in a longer one: one as long is the same topic or another.
          local rightLength = #rightLower
          if leftLength == rightLength then continue end

          local outer, inner
          if leftLength > rightLength then
            if not string.find(leftLower, rightLower, 1, true) then continue end

            outer, inner = leftTopic, rightTopic
          elseif not single and string.find(rightLower, leftLower, 1, true) then
            outer, inner = rightTopic, leftTopic
          else
            continue
          end

          table.insert(out, {
            earlierPlugin = left.name,
            laterPlugin = right.name,
            outerTopic = outer,
            innerTopic = inner,
          })
        end
      end
    end
  end

  return out
end

export type Override = {
  type: string,
  id: string,
  --- Every plugin that defines the record, by position (1-based), first to last.
  plugins: { number },
  --- Copies byte for byte the same as an earlier plugin's.
  identical: { { plugin: number, sameAs: number } },
  --- Plugins whose changes the last copy throws away.
  overridden: { number },
}

--- The records several of `plugins` (a load order, first to last) define that are worth a look:
--- copies unchanged from an earlier plugin, and plugins whose changes a later copy drops. Records
--- match by type and id ignoring ASCII case; records without an id, TES3 headers, and the
--- `ignore` types are skipped. A plugin defining a record twice counts once, with its last copy.
local function overrides(plugins: { Plugin }, ignore: { string }?): { Override }
  local ignored: { [string]: boolean } = {}
  for _, value in ignore or {} do
    ignored[string.lower(value) == 'npc' and 'NPC_' or tes3.tagNamed(value) or string.upper(value)] =
      true
  end

  -- A copy is where a record is, in which plugin: its bytes are compared there, not copied out.
  type Copy = { plugin: number, index: number }
  local function same(left: Copy, right: Copy): boolean
    return sameRecord(plugins[left.plugin], left.index, plugins[right.plugin], right.index)
  end

  local slots: { [string]: number } = {}
  local records: { { key: Key, copies: { Copy } } } = {}
  for position, plugin in plugins do
    for index = 0, plugin:count() - 1 do
      local tag = tes3.tags.display(plugin:code(index))
      if tag == 'TES3' or ignored[tag] then continue end

      local id = tes3.records.id(plugin, index)
      if not id then continue end

      local lookup = tag .. '\0' .. string.lower(id)
      local slot = slots[lookup]
      if not slot then
        table.insert(
          records,
          { key = { type = tag, id = id }, copies = { { plugin = position, index = index } } }
        )
        slots[lookup] = #records
        continue
      end

      local copies = records[slot].copies
      local last = copies[#copies]
      if last.plugin == position then
        last.index = index
      else
        table.insert(copies, { plugin = position, index = index })
      end
    end
  end

  local out = {}
  for _, record in records do
    local copies = record.copies
    if #copies < 2 then continue end

    local identical = {}
    for index, copy in copies do
      for earlier = 1, index - 1 do
        if same(copies[earlier], copy) then
          table.insert(identical, { plugin = copy.plugin, sameAs = copies[earlier].plugin })
          break
        end
      end
    end

    local winner = copies[#copies]
    local overridden = {}
    for index = 2, #copies - 1 do
      local copy = copies[index]
      if same(copy, winner) then continue end

      local new = true
      for earlier = 1, index - 1 do
        if same(copies[earlier], copy) then
          new = false
          break
        end
      end

      if new then table.insert(overridden, copies[index].plugin) end
    end

    if #identical > 0 or #overridden > 0 then
      table.insert(out, {
        type = record.key.type,
        id = record.key.id,
        plugins = [for copy in copies => copy.plugin],
        identical = identical,
        overridden = overridden,
      })
    end
  end

  return out
end

export type RecordDifference = {
  --- The record's position (0-based), its tag, and its id when it has one.
  index: number,
  type: string,
  id: string?,
  --- Where in `left`'s bytes the difference is: the first byte that differs.
  offset: number,
}

--- The first record, in file order, that two plugins don't share byte for byte: where a plugin
--- and what it was saved as part ways. Records of the `ignore` types (tags or type names) are left
--- out of both sides. The record is `left`'s, or `right`'s when `left` has run out, and then the
--- offset is where `left`'s bytes end. Nil when every record is the same.
local function firstDifference(left: Plugin, right: Plugin, ignore: { string }?): RecordDifference?
  local ignored: { [number]: boolean } = {}
  for _, value in ignore or {} do
    local tag = string.lower(value) == 'npc' and 'NPC_'
      or tes3.tagNamed(value)
      or string.upper(value)
    ignored[tes3.tags.code(tag)] = true
  end

  local function nextKept(plugin: Plugin, from: number): number?
    for index = from, plugin:count() - 1 do
      if not ignored[plugin:code(index)] then return index end
    end

    return nil
  end

  local function difference(plugin: Plugin, index: number, offset: number): RecordDifference
    local id = tes3.records.id(plugin, index)
    return {
      index = index,
      type = tes3.tags.display(plugin:code(index)),
      id = if id and id ~= '' then id else nil,
      offset = offset,
    }
  end

  local leftIndex, rightIndex = nextKept(left, 0), nextKept(right, 0)
  local leftEnd = 0
  while leftIndex and rightIndex do
    local start, finish = left:range(leftIndex)
    local leftSource, leftStart, leftFinish = left:span(leftIndex)
    local rightSource, rightStart, rightFinish = right:span(rightIndex)
    local first = firstMismatch(
      leftSource,
      leftStart,
      leftFinish - leftStart,
      rightSource,
      rightStart,
      rightFinish - rightStart
    )
    if first then return difference(left, leftIndex, start + first) end

    leftEnd = finish
    leftIndex, rightIndex = nextKept(left, leftIndex + 1), nextKept(right, rightIndex + 1)
  end

  if leftIndex then return difference(left, leftIndex, (left:range(leftIndex))) end

  if rightIndex then return difference(right, rightIndex, leftEnd) end

  return nil
end

return table.freeze {
  common = common,
  compareBytes = compareBytes,
  diff = diff,
  fieldChanges = fieldChanges,
  firstDifference = firstDifference,
  overlaps = overlaps,
  overrides = overrides,
}
