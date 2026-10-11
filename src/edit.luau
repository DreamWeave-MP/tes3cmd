--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Plugin edits built on raw records (jess-omwaddon's `edit`, tes3cmd's `delete` and `modify`):
deleting, rewriting, or extracting what a selector matches.
]]

local Select = require './select'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin
type Selector = Select.Selector

export type Deleted = {
  records: number,
  --- The positions the deleted records had before the deletion, ascending (0-based).
  recordIndices: { number },
  subrecords: number,
  references: number,
  --- Whether the header's record count was set to match.
  recordCountUpdated: boolean,
}

local Tes3Tag = tes3.tags.code 'TES3'
local CellTag = tes3.tags.code 'CELL'

--- Deletes what `selector` matches. With subrecord or instance filters, only the matching
--- subrecords (or CELL references) of matching records go; otherwise every matching record but
--- the TES3 header does, and the header's record count is set to match unless `recordCount` is
--- `'keep'`.
local function deleteMatching(
  plugin: Plugin,
  selector: Selector,
  recordCount: ('update' | 'keep')?
): Deleted
  local deleted: Deleted =
    { records = 0, recordIndices = {}, subrecords = 0, references = 0, recordCountUpdated = false }
  if Select.hasSubrecordFilters(selector) or Select.hasInstanceFilters(selector) then
    for index = 0, plugin:count() - 1 do
      if not Select.matchesRecord(selector, plugin, index) then continue end

      if Select.hasInstanceFilters(selector) and plugin:code(index) == CellTag then
        local references = Select.matchingCellReferences(selector, plugin, index)
        deleted.references += plugin:deleteCellReferences(index, references)
      elseif Select.hasSubrecordFilters(selector) then
        local subs = {}
        for ordinal, sub in plugin:subrecords(index) do
          if Select.matchesSubrecord(selector, plugin, index, sub) then
            table.insert(subs, ordinal - 1)
          end
        end

        for position = #subs, 1, -1 do
          plugin:deleteSubrecord(index, subs[position])
        end

        deleted.subrecords += #subs
      end
    end

    return deleted
  end

  local remove: { [number]: boolean } = {}
  for index = 0, plugin:count() - 1 do
    if plugin:code(index) ~= Tes3Tag and Select.matchesRecord(selector, plugin, index) then
      remove[index] = true
      table.insert(deleted.recordIndices, index)
    end
  end

  if #deleted.recordIndices > 0 then plugin:retain(function(index) return not remove[index] end) end

  deleted.records = #deleted.recordIndices
  deleted.recordCountUpdated = plugin:applyRecordCount(recordCount or 'update', deleted.records > 0)
  return deleted
end

--[[ Replacing text ]]

export type Replacement = { regex: Regex, replacement: string, global: boolean }

--- A `/pattern/replacement/` expression: any first character is the delimiter; the pattern is a
--- case-insensitive regex, and the replacement expands `$1` and `${name}`. `global` replaces
--- every match, not just the first.
local function parseReplacement(expression: string, global: boolean): Replacement
  if expression == '' then error('replacement expression is empty', 0) end

  local function invalid(problem: string): never
    return error(`invalid replacement expression '{expression}': {problem}`, 0)
  end

  local delimiter = utf8.char(utf8.codepoint(expression, 1))
  local width = #delimiter
  local second = string.find(expression, delimiter, width + 1, true)
  if not second then return invalid 'missing second delimiter' end

  local third = string.find(expression, delimiter, second + width, true)
  if not third then return invalid 'missing final delimiter' end

  if third + width - 1 ~= #expression then return invalid 'trailing text after final delimiter' end

  local pattern = string.sub(expression, width + 1, second - 1)
  -- jess.regex.new throws on a pattern that isn't a regex.
  local ok, regex = pcall(function(): Regex return jess.regex.new(`(?i){pattern}`) end)
  if not ok then error(`invalid replacement regex '{pattern}': {regex}`, 0) end

  return {
    regex = regex :: Regex,
    replacement = string.sub(expression, second + width, third - 1),
    global = global,
  }
end

local function apply(replacement: Replacement, value: string): string
  if replacement.global then
    return (replacement.regex:replaceAll(value, replacement.replacement))
  end

  return (replacement.regex:replace(value, replacement.replacement))
end

export type ModifyReport = { records: number, fields: number }

--- Applies `replacement` to the typed string fields `selector` matches: fields of matching
--- records that pass the subrecord filters. Instance filters can't select fields.
local function replaceMatching(
  plugin: Plugin,
  selector: Selector,
  replacement: Replacement
): ModifyReport
  if Select.hasInstanceFilters(selector) then
    error('instance filters can\'t select fields to modify', 0)
  end

  -- Without subrecord filters every field of a selected record is selected (`true`).
  local filtered = Select.hasSubrecordFilters(selector)
  local selected: { [number]: { [number]: boolean } | true } = {}
  for index = 0, plugin:count() - 1 do
    if not Select.matchesRecord(selector, plugin, index) then continue end

    if not filtered then
      selected[index] = true
      continue
    end

    local fields: { [number]: boolean } = {}
    for ordinal, sub in plugin:subrecords(index) do
      if Select.matchesSubrecord(selector, plugin, index, sub) then fields[ordinal - 1] = true end
    end

    selected[index] = fields
  end

  local report: ModifyReport = { records = 0, fields = 0 }
  local encoding = plugin.encoding
  for index = 0, plugin:count() - 1 do
    local fields = selected[index]
    if not fields then continue end

    local changes = {}
    for _, field in tes3.records.stringFields(plugin, index) do
      if fields ~= true and not fields[field.subrecord] then continue end

      local changed = apply(replacement, field.value)
      if changed == field.value then continue end

      local missing = tes3.text.unencodable(changed, encoding)
      if missing then
        local id = tes3.records.id(plugin, index)
        local named = if id then ` '{id}'` else ''
        error(
          `failed to modify plugin: {tes3.tags.display(plugin:code(index))}{named} {field.tag}: {tes3.text.describe(
            missing
          )} can't be written in {tes3.text.name(encoding)}, the plugin's encoding`,
          0
        )
      end

      table.insert(changes, { subrecord = field.subrecord, value = changed })
    end

    plugin:replaceStrings(index, changes)
    report.fields += #changes

    if #changes > 0 then
      report.records += 1
    end
  end

  return report
end

--- The raw bytes of every record `selector` selects but TES3, picked as `select.selection` picks
--- them: with instance filters a CELL keeps only the references they select. With
--- `includeHeader`, a plugin: the original header first, its record count updated.
local function extractMatching(plugin: Plugin, selector: Selector, includeHeader: boolean): buffer
  -- Each picked record's bytes, copied once into the result.
  local spans: { number } = {}
  local length = 0
  local function take(index: number)
    local _, start, finish = plugin:span(index)
    table.insert(spans, index)
    length += finish - start
  end

  if includeHeader then
    if plugin:count() == 0 then error('empty plugin', 0) end

    if plugin:code(0) ~= Tes3Tag then error('first record is not TES3', 0) end

    take(0)
  end

  local trims: { { position: number, dropped: { number } } } = {}
  local position = if includeHeader then 1 else 0
  for index = 0, plugin:count() - 1 do
    if plugin:code(index) == Tes3Tag then continue end

    local picked = Select.selection(selector, plugin, index)
    if not picked then continue end

    local references = picked.references
    if references then
      local groups = plugin:cellGroups(index)
      local count = if groups then #groups.references else 0
      local kept: { [number]: boolean } = {}
      for _, ref in references do
        kept[ref] = true
      end

      local dropped = {}
      for ref = 0, count - 1 do
        if not kept[ref] then table.insert(dropped, ref) end
      end

      if #dropped > 0 then table.insert(trims, { position = position, dropped = dropped }) end
    end

    take(index)
    position += 1
  end

  local bytes = buffer.create(length)
  local at = 0
  for _, index in spans do
    local source, start, finish = plugin:span(index)
    buffer.copy(bytes, at, source, start, finish - start)
    at += finish - start
  end

  if not includeHeader and #trims == 0 then return bytes end

  local extracted = tes3.open(bytes, { encoding = plugin.encoding })
  for _, trim in trims do
    extracted:deleteCellReferences(trim.position, trim.dropped)
  end

  if includeHeader then extracted:updateRecordCount() end

  return extracted:save()
end

return table.freeze {
  apply = apply,
  deleteMatching = deleteMatching,
  extractMatching = extractMatching,
  parseReplacement = parseReplacement,
  replaceMatching = replaceMatching,
}
