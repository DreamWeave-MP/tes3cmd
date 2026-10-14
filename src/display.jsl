--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Readable dumps and byte layouts (what `jess plugin dump` prints, and `--raw`): every selected
record's readable value (`@tes3`'s `display`), or where it and its subrecords sit in the
plugin's bytes.
]]

local Select = require './select'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin

local display = tes3.display.display

--- The readable values of every record `selector` selects (all of them without one).
local function dump(plugin: Plugin, selector: Select.Selector?): { { [string]: unknown } }
  if not selector then
    return [for index in range(0, plugin:count() - 1) => display(plugin, index)]
  end

  local out = {}
  for index = 0, plugin:count() - 1 do
    local picked = Select.selection(selector, plugin, index)
    if picked then table.insert(out, display(plugin, index, picked.references)) end
  end

  return out
end

--[[ Layout ]]

export type SubrecordLayout = {
  index: number,
  type: string,
  size: number,
  range: { start: number, ['end']: number },
  field: string?,
  value: string?,
}

export type RecordLayout = {
  index: number,
  type: string,
  id: string?,
  flags: number,
  size: number,
  range: { start: number, ['end']: number },
  subrecords: { SubrecordLayout }?,
}

--- One CELL reference: its position among the cell's references (0-based), and its subrecords.
export type ReferenceLayout = { index: number, subrecords: { SubrecordLayout } }

--- Record `index`'s typed string fields by subrecord position (0-based).
local function fieldsBySubrecord(plugin: Plugin, index: number): { [number]: tes3.StringField }
  local fields: { [number]: tes3.StringField } = {}
  for _, field in tes3.records.stringFields(plugin, index) do
    fields[field.subrecord] = field
  end

  return fields
end

--- Where an edited record's subrecords are said to sit: it has no place in the original bytes,
--- so they sit at its end there, empty. Nil for a record as it was read.
local function movedTo(plugin: Plugin, index: number): number?
  if not plugin:isDirty(index) then return nil end

  local _, finish = plugin:range(index)
  return finish
end

--- Where the subrecord at `position` (0-based) of a record sits: at `moved`, empty, when the
--- record was edited (see `movedTo`), and where it was read otherwise.
local function subrecordLayout(
  position: number,
  sub: tes3.Subrecord,
  field: tes3.StringField?,
  moved: number?
): SubrecordLayout
  return {
    index = position,
    type = tes3.tags.display(sub.code),
    size = sub.size,
    range = if moved
      then { start = moved, ['end'] = moved }
      else { start = sub.start, ['end'] = sub.finish },
    field = field and field.name,
    value = field and field.value,
  }
end

--- Where record `index` and (with `subrecords`) its subrecords that pass the selector's
--- subrecord filters sit in the plugin's bytes; `fields` adds their typed string fields.
local function layout(
  plugin: Plugin,
  index: number,
  selector: Select.Selector,
  options: { subrecords: boolean?, fields: boolean? }?
): RecordLayout
  local start, finish = plugin:range(index)
  local id = tes3.records.fieldId(plugin, index) or tes3.records.id(plugin, index)
  local out: RecordLayout = {
    index = index,
    type = tes3.tags.display(plugin:code(index)),
    id = if id and id ~= '' then id else nil,
    flags = plugin:flags(index),
    size = plugin:size(index),
    range = { start = start, ['end'] = finish },
  }

  if not options or not options.subrecords then return out end

  local fields = if options.fields then fieldsBySubrecord(plugin, index) else {}
  local moved = movedTo(plugin, index)
  local subs = plugin:subrecords(index)
  -- A record without subrecords asks nothing of the selector.
  local filtered = #subs > 0 and Select.hasSubrecordFilters(selector)
  local list = [
    for ordinal, sub in enumerate(subs)
    if not filtered or Select.matchesSubrecord(selector, plugin, index, sub)
    => subrecordLayout(ordinal - 1, sub, fields[ordinal - 1], moved)
  ]

  if #list > 0 then out.subrecords = list end

  return out
end

--- The CELL references of record `index` that pass the selector's instance filters, each with
--- every subrecord it is made of; `fields` adds their typed string fields. None for another
--- record.
local function references(
  plugin: Plugin,
  index: number,
  selector: Select.Selector,
  fields: boolean?
): { ReferenceLayout }
  local groups = plugin:cellGroups(index)
  if not groups then return {} end

  local named = if fields then fieldsBySubrecord(plugin, index) else {}
  local subs = plugin:subrecords(index)
  local moved = movedTo(plugin, index)
  local out = {}
  for _, reference in Select.matchingCellReferences(selector, plugin, index) do
    local group = groups.references[reference + 1]
    table.insert(out, {
      index = reference,
      subrecords = [
        for position in range(group[1], group[2])
        => subrecordLayout(position, subs[position + 1], named[position], moved)
      ],
    })
  end

  return out
end

return table.freeze { dump = dump, layout = layout, references = references }
