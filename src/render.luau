--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A command's result as the document `jess plugin` printed for it: one YAML, JSON, or TOML document,
its fields in the order and under the snake_case names the original gave them. Data in, text out.

Reports go through `@vfs/serialize`, which writes the three formats the way serde wrote them.
Record dumps are a list under `records`, and in YAML each record is written the way the original's
own writer wrote it: lists of plain values on one line, text with line breaks as a literal block,
floats in the shortest spelling that reads back.
]]

local Arguments = require './arguments'
local Commands = require './commands'
local Display = require './display'
local Lint = require './lint'
local Numbers = require './numbers'
local serialize = require '@vfs/serialize'

type Value = serialize.Value
type Map = serialize.Map
type Format = Arguments.Format

--- How to print a result: the format, and for a dump in pages whether this page goes on from
--- one already printed.
export type Options = { format: Format?, continued: boolean? }

--[[ Values ]]

--- A name as a report spells it: `recordCount` is `record_count` (jess-omwaddon's `snake_case`).
local function snake(name: string): string
  local head, rest = string.sub(name, 1, 1), string.sub(name, 2)
  return head .. string.gsub(rest, '%u', function(upper: string): string return '_' .. string.lower(upper) end)
end

--- A struct: `{ name, value }` pairs in order. A pair without a value is left out, and
--- `serialize.None` is one that is there and empty (`null`).
local function struct(fields: { { unknown } }): Map
  local out = serialize.map()
  for _, field in fields do
    if field[2] ~= nil then serialize.set(out, field[1] :: string, field[2]) end
  end

  return out
end

local function array<Item>(items: { Item }, each: ((item: Item) -> Value)?): Value
  local out = table.create(#items)
  for position, item in items do
    out[position] = if each then each(item) else item
  end

  return serialize.array(out)
end

--- A map of counts, its keys in order.
local function counts(values: { [string]: number }): Map
  local keys = {}
  for key in values do
    table.insert(keys, key)
  end

  table.sort(keys)
  local out = serialize.map()
  for _, key in keys do
    serialize.set(out, key, values[key])
  end

  return out
end

local function written(file: Commands.Written?): Value
  if not file then return serialize.None end

  return struct { { 'path', file.path }, { 'backup', file.backup } }
end

--- `dry_run: true`, which a report only has for a dry run.
local function dry(dryRun: boolean?): boolean? return if dryRun then true else nil end

local function key(record: Commands.Key): Value
  return struct { { 'type', record.type }, { 'id', record.id } }
end

local function range(span: { start: number, ['end']: number }): Value
  return struct { { 'start', span.start }, { 'end', span['end'] } }
end

local function subrecord(sub: Display.SubrecordLayout): Value
  return struct {
    { 'index', sub.index },
    { 'type', sub.type },
    { 'size', sub.size },
    { 'range', range(sub.range) },
    { 'field', sub.field },
    { 'value', sub.value },
  }
end

local function layout(record: Commands.Layout): Value
  local references = record.references
  return struct {
    { 'index', record.index },
    { 'type', record.type },
    { 'id', record.id },
    { 'flags', record.flags },
    { 'size', record.size },
    { 'range', range(record.range) },
    { 'subrecords', record.subrecords and array(record.subrecords, subrecord) },
    {
      'references',
      references and array(references, function(reference): Value
        return struct {
          { 'index', reference.index },
          { 'subrecords', array(reference.subrecords, subrecord) },
        }
      end),
    },
  }
end

--- The fields a record's value starts with, in order: what it is, then why it couldn't be read.
--- The rest follow by name.
local Leading: { [string]: number } =
  { record = 1, type = 2, flags = 3, id = 4, name = 5, undecoded = 6 }

--- A readable record value, or a part of one, as a document value. `@tes3`'s values are plain
--- tables with camelCase names and no order of their own: here a table's fields are named as the
--- original named them and put in a fixed order, the identifying ones first.
local function readable(value: unknown): Value
  if type(value) ~= 'table' then return value end

  local members = value :: { [unknown]: unknown }
  if members[1] ~= nil or next(members) == nil then return array(members :: { unknown }, readable) end

  local names = {}
  for name in members do
    table.insert(names, tostring(name))
  end

  table.sort(names, function(left: string, right: string): boolean
    local first, second = Leading[left], Leading[right]
    if first or second then return (first or math.huge) < (second or math.huge) end

    return left < right
  end)

  local out = serialize.map()
  for _, name in names do
    serialize.set(out, snake(name), readable(members[name]))
  end

  return out
end

--[[ A record list in YAML ]]

--- Words a YAML reader may take for something other than text when they aren't quoted.
local Reserved: { [string]: boolean } = {}
for _, word in
  { 'true', 'false', 'null', 'yes', 'no', 'on', 'off', 'y', 'n', 'nan', 'inf', '~', '=', '<<' }
do
  Reserved[word] = true
end

--- Lists of plain values wider than this are written one item to a line.
local MaxInlineWidth = 100

local function isPlainSafe(text: string): boolean
  return string.match(text, '^%a[%w _./\\-]*$') ~= nil
    and string.sub(text, -1) ~= ' '
    and not Reserved[string.lower(text)]
end

--- Text as a YAML scalar on one line: plain when nothing could misread it, quoted otherwise.
local function quote(text: string): string
  if isPlainSafe(text) then return text end

  if Reserved[string.lower(text)] then return `'{text}'` end

  local quoted = string.gsub(serialize.encode(text, 'yaml'), '\n$', '')
  local first = string.sub(quoted, 1, 1)
  -- A plain scalar is only safe in a block; flow indicators would break a list on one line.
  if first ~= '\'' and first ~= '"' and string.find(text, '[,%[%]{}]') then
    return `'{(string.gsub(text, '\'', '\'\''))}'`
  end

  return quoted
end

--- Keys are text; one that is a number reads better without quotes.
local function keyText(name: string): string
  local number = if string.match(name, '^[+-]?[%d.]+[eE]?[+-]?%d*$') then tonumber(name) else nil
  if number and number == number and math.abs(number) ~= math.huge then return name end

  return quote(name)
end

local function numberText(value: Value): string
  local number = if type(value) == 'number' then value else (value :: { value: number }).value
  if serialize.kindOf(value) == 'int' then return string.format('%.0f', number) end

  if number ~= number then return '.nan' end

  if number == math.huge then return '.inf' end

  if number == -math.huge then return '-.inf' end

  return Numbers.floatText(number)
end

local function inline(value: Value): string
  local kind = serialize.kindOf(value)
  if kind == 'null' or kind == 'none' then return 'null' end

  if kind == 'boolean' then return tostring(value) end

  if kind == 'int' or kind == 'float' then return numberText(value) end

  if kind == 'string' then return quote(value :: string) end

  local parts = {}
  if kind == 'array' then
    for _, item in value :: { Value } do
      table.insert(parts, inline(item))
    end

    return `[{table.concat(parts, ', ')}]`
  end

  local map = value :: Map
  for _, name in map.keys do
    table.insert(parts, `{keyText(name)}: {inline(map.values[name])}`)
  end

  return `\{{table.concat(parts, ', ')}}`
end

local function hasBreak(value: Value): boolean
  return type(value) == 'string' and string.find(value, '\n', 1, true) ~= nil
end

--- Whether a list goes on one line: plain values only, and all numbers or narrow enough.
local function isInlineSequence(items: { Value }): boolean
  local numbers, width = true, 0
  for _, item in items do
    local kind = serialize.kindOf(item)
    if kind == 'array' or kind == 'map' or hasBreak(item) then return false end

    numbers = numbers and (kind == 'int' or kind == 'float')
    width += #inline(item) + 2
  end

  return numbers or width <= MaxInlineWidth
end

--- Text with line breaks as a literal block, CRLF line endings shown as LF. Text with other
--- control characters can't be a block, and is quoted.
local function writeBlockScalar(out: { string }, given: string, indent: number)
  local text = string.gsub(given, '\r\n', '\n')
  if string.find(text, '[%z\1-\8\11-\31\127]') or string.find(text, '\194[\128-\159]') then
    table.insert(out, quote(text) .. '\n')
    return
  end

  local body = string.gsub(text, '\n+$', '')
  local trailing = #text - #body
  local chomp = if trailing == 0 then '-' elseif trailing == 1 then '' else '+'
  local indicator = if string.sub(body, 1, 1) == ' ' then '2' else ''
  table.insert(out, `|{indicator}{chomp}\n`)
  local pad = string.rep(' ', indent)
  for _, line in string.split(body, '\n') do
    table.insert(out, if line == '' then '\n' else `{pad}{line}\n`)
  end

  table.insert(out, string.rep('\n', math.max(trailing - 1, 0)))
end

local writeSequenceItem: (out: { string }, value: Value, indent: number) -> ()

local function writeMapping(out: { string }, map: Map, indent: number)
  local pad = string.rep(' ', indent)
  for _, name in map.keys do
    local value = map.values[name]
    local kind = serialize.kindOf(value)
    table.insert(out, `{pad}{keyText(name)}:`)
    if kind == 'map' and #(value :: Map).keys > 0 then
      table.insert(out, '\n')
      writeMapping(out, value :: Map, indent + 2)
    elseif kind == 'array' and not isInlineSequence(value :: { Value }) then
      table.insert(out, '\n')
      for _, item in value :: { Value } do
        writeSequenceItem(out, item, indent)
      end
    elseif hasBreak(value) then
      table.insert(out, ' ')
      writeBlockScalar(out, value :: string, indent + 2)
    else
      table.insert(out, ` {inline(value)}\n`)
    end
  end
end

writeSequenceItem = function(out: { string }, value: Value, indent: number)
  local pad = string.rep(' ', indent)
  local kind = serialize.kindOf(value)
  if kind == 'map' and #(value :: Map).keys > 0 then
    local body = {}
    writeMapping(body, value :: Map, indent + 2)
    table.insert(out, `{pad}- {string.sub(table.concat(body), indent + 3)}`)
  elseif kind == 'array' and not isInlineSequence(value :: { Value }) then
    table.insert(out, `{pad}-\n`)
    for _, item in value :: { Value } do
      writeSequenceItem(out, item, indent + 2)
    end
  elseif hasBreak(value) then
    table.insert(out, `{pad}- `)
    writeBlockScalar(out, value :: string, indent + 2)
  else
    table.insert(out, `{pad}- {inline(value)}\n`)
  end
end

--- A document that is one list of records under `records`, or a part of one: a page that goes
--- on from one already printed (`continued`) doesn't open the list, and one with pages to follow
--- (`more`) doesn't close it, so a dump's pages printed one after another are the document. TOML
--- has no list to leave open, so it is whole or nothing.
local function records(items: { Value }, format: Format, continued: boolean?, more: boolean): string
  if format == 'toml' then
    if continued or more then error('a TOML document can\'t be printed in pages', 0) end

    return serialize.encode(struct { { 'records', serialize.array(items) } }, format)
  end

  local out = {}
  if format == 'json' then
    if not continued then table.insert(out, '{"records":[') end

    for position, item in items do
      if continued or position > 1 then table.insert(out, ',') end

      table.insert(out, serialize.encode(item, 'json'))
    end

    if not more then table.insert(out, ']}\n') end

    return table.concat(out)
  end

  if not continued and #items == 0 and not more then return 'records: []\n' end

  if not continued then table.insert(out, 'records:\n') end

  for _, item in items do
    writeSequenceItem(out, item, 0)
  end

  return table.concat(out)
end

--[[ Documents ]]

local function document(fields: { { unknown } }, format: Format): string
  local text = serialize.encode(struct(fields), format)
  return if format == 'json' then text .. '\n' else text
end

--- A lint check as reports name it: `evil_gmsts`, `cell_00`.
local function checkSymbol(name: string): string
  return (string.gsub(Lint.parseCheck(name), '-', '_'))
end

local function snakeNames(names: { string }): Value
  return array(names, function(name: string): Value return snake(name) end)
end

local function dumped(result: Commands.DumpResult, format: Format, continued: boolean?): string
  if result.mode == 'extract' then
    return document({
      { 'input', result.path },
      { 'path', result.path },
      { 'bytes', result.bytes },
      { 'dry_run', dry(result.dryRun) },
      { 'written', written(result.written) },
    }, format)
  end

  local items = {}
  if result.mode == 'records' then
    for _, record in result.records or {} do
      table.insert(items, readable(record))
    end
  elseif result.mode == 'list' then
    for _, listed in result.listed or {} do
      table.insert(
        items,
        struct { { 'record', listed.record }, { 'type', listed.type }, { 'id', listed.id } }
      )
    end
  else
    for _, record in result.layouts or {} do
      table.insert(items, layout(record))
    end
  end

  return records(items, format, continued, result.next ~= nil)
end

local function stats(result: Commands.StatsResult, format: Format): string
  return document({
    { 'files', result.files },
    { 'records', result.records },
    { 'record_types', counts(result.recordTypes) },
    { 'subrecord_types', counts(result.subrecordTypes) },
    { 'list_subrecords', counts(result.listSubrecords) },
  }, format)
end

local function header(result: Commands.HeaderResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'author', result.author },
    { 'description', result.description },
    { 'record_count', result.recordCount },
    {
      'masters_updated',
      array(result.mastersUpdated, function(master): Value
        return struct {
          { 'name', master.name },
          { 'old_size', master.oldSize },
          { 'new_size', master.newSize },
          { 'path', master.path },
        }
      end),
    },
    { 'dry_run', dry(result.dryRun) },
    { 'written', written(result.written) },
  }, format)
end

local function diff(result: Commands.DiffResult, format: Format): string
  return document({
    { 'left_only', array(result.leftOnly, key) },
    { 'right_only', array(result.rightOnly, key) },
    { 'equal', result.equal and array(result.equal, key) },
    {
      'changed',
      array(result.changed, function(record): Value
        return struct {
          { 'type', record.type },
          { 'id', record.id },
          { 'raw_changed', record.rawChanged },
          {
            'fields',
            array(record.fields, function(change): Value
              return struct {
                { 'field', change.field },
                { 'left', change.left },
                { 'right', change.right },
              }
            end),
          },
        }
      end),
    },
  }, format)
end

local function common(result: Commands.CommonResult, format: Format): string
  return document({
    { 'left', result.left },
    { 'right', result.right },
    { 'records', array(result.records, key) },
  }, format)
end

local function compare(result: Commands.CompareResult, format: Format): string
  return document({
    { 'left', result.left },
    { 'right', result.right },
    { 'identical', result.identical },
    { 'left_bytes', result.leftBytes },
    { 'right_bytes', result.rightBytes },
    { 'first_difference', result.firstDifference or serialize.None },
  }, format)
end

local function overdial(result: Commands.OverdialResult, format: Format): string
  return document({
    {
      'overlaps',
      array(result.overlaps, function(overlap): Value
        return struct {
          { 'earlier_plugin', overlap.earlierPlugin },
          { 'later_plugin', overlap.laterPlugin },
          { 'outer_topic', overlap.outerTopic },
          { 'inner_topic', overlap.innerTopic },
        }
      end),
    },
  }, format)
end

local function lint(result: Commands.LintResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'checks', array(result.checks, checkSymbol) },
    {
      'summary',
      struct {
        { 'errors', result.summary.errors },
        { 'warnings', result.summary.warnings },
        { 'info', result.summary.info },
      },
    },
    {
      'findings',
      array(result.findings, function(finding): Value
        return struct {
          { 'check', checkSymbol(finding.check) },
          { 'severity', finding.severity },
          { 'message', finding.message },
        }
      end),
    },
  }, format)
end

local function validate(result: Commands.ValidateResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'checks', snakeNames(result.checks) },
    { 'valid', result.valid },
    {
      'diagnostics',
      array(result.diagnostics, function(diagnostic): Value
        return struct { { 'offset', diagnostic.offset }, { 'message', diagnostic.message } }
      end),
    },
  }, format)
end

local function clean(result: Commands.CleanResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'cleanups', snakeNames(result.cleanups) },
    { 'removed_records', result.removedRecords },
    { 'removed_subrecords', result.removedSubrecords },
    { 'record_count_updated', result.recordCountUpdated },
    { 'dry_run', dry(result.dryRun) },
    { 'written', written(result.written) },
  }, format)
end

local function deleted(result: Commands.DeleteResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'deleted', result.deleted },
    { 'unit', result.unit },
    { 'record_count_updated', result.recordCountUpdated },
    { 'dry_run', dry(result.dryRun) },
    { 'written', written(result.written) },
  }, format)
end

local function modify(result: Commands.ModifyResult, format: Format): string
  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'fields', result.fields },
    { 'records', result.records },
    { 'dry_run', dry(result.dryRun) },
    { 'written', written(result.written) },
  }, format)
end

--- A conversion a file stood in the way of printed no document, only why.
local function converted(result: Commands.ConvertResult, format: Format): string
  if result.blocked then return '' end

  return document({
    { 'input', result.path },
    { 'path', result.path },
    { 'file_type', result.fileType },
    { 'output', result.output },
    { 'dry_run', dry(result.dryRun) },
    { 'written', written(result.written) },
  }, format)
end

local function tested(result: Commands.TestCodecResult, format: Format): string
  return document({
    {
      'results',
      array(result.results, function(file): Value
        local record = file.record
        return struct {
          { 'input', file.path },
          { 'path', file.path },
          { 'ok', file.ok },
          { 'error', file.error or serialize.None },
          { 'first_difference', file.firstDifference },
          {
            'record',
            record
              and struct { { 'index', record.index }, { 'type', record.type }, { 'id', record.id } },
          },
        }
      end),
    },
  }, format)
end

--- The result as the document the command prints, in `options.format`: YAML unless it says
--- otherwise, and JSON for a byte layout. Nothing for a result that prints no document. A page
--- of a dump is the part of the document it is: `options.continued` says it isn't the first.
local function render(result: Commands.Result, options: Options?): string
  local format: Format = options and options.format or 'yaml'
  if result.command == 'dump' then
    local layouts = result.mode == 'layout' and not (options and options.format)
    return dumped(result, if layouts then 'json' else format, options and options.continued)
  end

  if result.command == 'stats' then return stats(result, format) end

  if result.command == 'header' then return header(result, format) end

  if result.command == 'diff' then return diff(result, format) end

  if result.command == 'common' then return common(result, format) end

  if result.command == 'compare' then return compare(result, format) end

  if result.command == 'overdial' then return overdial(result, format) end

  if result.command == 'lint' then return lint(result, format) end

  if result.command == 'validate' then return validate(result, format) end

  if result.command == 'clean' then return clean(result, format) end

  if result.command == 'delete' then return deleted(result, format) end

  if result.command == 'modify' then return modify(result, format) end

  if result.command == 'testCodec' then return tested(result, format) end

  return converted(result, format)
end

return table.freeze { render = render, snake = snake }
