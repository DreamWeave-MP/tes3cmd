--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A dump's records as text: the list under `records`, or the page of it a result holds, in YAML as
the original's own writer wrote it (lists of plain values on one line, text with line breaks as a
literal block, floats in the shortest spelling that reads back) and in JSON as serde_json did.

A dump is the one document that is as big as the plugin it describes, so its text is written
straight from the result's tables into one growing buffer. Nothing is built in between: no tree of
ordered maps, no list of pieces to join at the end. What a page costs to print is then its text,
and the small strings made on the way are garbage as soon as they are written.

A `Shape` says how a table of the result is written: its fields in order, under the names a
report gives them. A readable record value has no shape of its own: `@tes3`'s values are plain
tables with camelCase names and no order, so their fields are named as the original named them
and put in a fixed order, the identifying ones first.
]]

local Numbers = require './numbers'
local serialize = require '@jess/data/value'

type Value = serialize.Value

--- A field of a shaped table: where it is in the table, what a report calls it, the shape of its
--- value when that is a table, and its key as JSON writes it, with its colon, for an object's
--- first field and (after a comma) for one that follows another.
type Field = { key: string, name: string, shape: Shape?, json: string, jsonNext: string }

--- How a table is written: `fields` in order (the ones without a value left out), or a list
--- whose items have the shape `each`, or with neither a readable record value.
export type Shape = { fields: { Field }?, each: Shape? }

local function field(name: string, shape: Shape?): Field
  return { key = name, name = name, shape = shape, json = `"{name}":`, jsonNext = `,"{name}":` }
end

local Readable: Shape = table.freeze {}

local Range: Shape = { fields = { field 'start', field 'end' } }

local Subrecords: Shape = {
  each = {
    fields = {
      field 'index',
      field 'type',
      field 'size',
      field('range', Range),
      field 'field',
      field 'value',
    },
  },
}

--- A record's byte layout, with the CELL references instance filters selected.
local Layout: Shape = {
  fields = {
    field 'index',
    field 'type',
    field 'id',
    field 'flags',
    field 'size',
    field('range', Range),
    field('subrecords', Subrecords),
    field('references', { each = { fields = { field 'index', field('subrecords', Subrecords) } } }),
  },
}

--- A record in a listing.
local Listed: Shape = { fields = { field 'record', field 'type', field 'id' } }

--[[ Names and order ]]

--- A name as a report spells it: `recordCount` is `record_count` (jess-omwaddon's `snake_case`).
local function snake(name: string): string
  local head, rest = string.sub(name, 1, 1), string.sub(name, 2)
  return head .. string.gsub(rest, '%u', function(upper: string): string return '_' .. string.lower(upper) end)
end

--- The fields a record's value starts with, in order: what it is, then why it couldn't be read.
--- The rest follow by name.
local Leading: { [string]: number } =
  { record = 1, type = 2, flags = 3, id = 4, name = 5, undecoded = 6 }

local function before(left: string, right: string): boolean
  local first, second = Leading[left], Leading[right]
  if first or second then return (first or math.huge) < (second or math.huge) end

  return left < right
end

--- A readable value's field names, in the order they are written.
local function sortedKeys(members: { [unknown]: unknown }): { string }
  local names = {}
  for name in members do
    table.insert(names, tostring(name))
  end

  table.sort(names, before)
  return names
end

--- Whether a table is written as a list: a shaped list, or a readable value that is one.
local function isList(members: { [unknown]: unknown }, shape: Shape): boolean
  if shape.each then return true end

  return not shape.fields and (members[1] ~= nil or next(members) == nil)
end

--- How many fields a table that isn't a list may have, and for a readable value their names.
local function fieldsOf(members: { [unknown]: unknown }, shape: Shape): (number, { string }?)
  local fields = shape.fields
  if fields then return #fields, nil end

  local keys = sortedKeys(members)
  return #keys, keys
end

--- A name a document spells a field's key by, kept for the next record with the same field. Only
--- so many are kept: Lua data in a plugin can name its fields anything.
local MaxSpelled = 4096

type Spelling = { count: number, names: { [string]: string } }

local function spelled(spelling: Spelling, key: string, spell: (key: string) -> string): string
  local known = spelling.names[key]
  if known then return known end

  local name = spell(key)
  if spelling.count < MaxSpelled then
    spelling.count += 1
    spelling.names[key] = name
  end

  return name
end

--[[ The buffer ]]

--- Text being written: the bytes so far, in a buffer that grows by doubling.
type Writer = { bytes: buffer, length: number }

local function writer(): Writer return { bytes = buffer.create(65536), length = 0 } end

local function reserve(out: Writer, more: number)
  local capacity = buffer.len(out.bytes)
  if out.length + more <= capacity then return end

  local grown = buffer.create(math.max(capacity * 2, out.length + more))
  buffer.copy(grown, 0, out.bytes, 0, out.length)
  out.bytes = grown
end

local function put(out: Writer, text: string)
  local length = #text
  reserve(out, length)
  buffer.writestring(out.bytes, out.length, text)
  out.length += length
end

--- One character, by its code: a document's punctuation is written a byte at a time, where a
--- string of one would be a call out for each.
local function putByte(out: Writer, byte: number)
  reserve(out, 1)
  buffer.writeu8(out.bytes, out.length, byte)
  out.length += 1
end

--- A whole number below 2^53 in decimal, written digit by digit: a byte layout is mostly these,
--- and each would otherwise be a string of its own.
local function putInteger(out: Writer, value: number)
  reserve(out, 20)
  local bytes, at = out.bytes, out.length
  local magnitude = value
  if value < 0 or (value == 0 and 1 / value < 0) then
    buffer.writeu8(bytes, at, 45)
    at += 1
    magnitude = -value
  end

  local digits, scale = 1, 10
  while magnitude >= scale do
    digits += 1
    scale *= 10
  end

  for position = at + digits - 1, at, -1 do
    buffer.writeu8(bytes, position, 48 + magnitude % 10)
    magnitude //= 10
  end

  out.length = at + digits
end

local function finish(out: Writer): string return buffer.readstring(out.bytes, 0, out.length) end

--- Whether a number is written as an integer: a whole one below 2^53, as serde took it.
local function isInteger(value: number): boolean
  return value == math.floor(value) and math.abs(value) < 2 ^ 53
end

--[[ YAML ]]

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
local function yamlKey(key: string): string
  local name = snake(key)
  local number = if string.match(name, '^[+-]?[%d.]+[eE]?[+-]?%d*$') then tonumber(name) else nil
  if number and number == number and math.abs(number) ~= math.huge then return name end

  return quote(name)
end

local YamlKeys: Spelling = { count = 0, names = {} }

local function yamlFloat(value: number): string
  if value ~= value then return '.nan' end

  if value == math.huge then return '.inf' end

  if value == -math.huge then return '-.inf' end

  return Numbers.floatText(value)
end

local function hasBreak(value: unknown): boolean
  return type(value) == 'string' and string.find(value, '\n', 1, true) ~= nil
end

--- A plain value, or a list of them, on one line.
local function inline(value: unknown): string
  if type(value) == 'string' then return quote(value) end

  if type(value) == 'number' then
    return if isInteger(value) then string.format('%.0f', value) else yamlFloat(value)
  end

  if type(value) ~= 'table' then return tostring(value) end

  local parts = {}
  for _, item in value :: { unknown } do
    table.insert(parts, inline(item))
  end

  return `[{table.concat(parts, ', ')}]`
end

--- Whether a list goes on one line: plain values only, and all numbers or narrow enough.
local function isInlineSequence(items: { unknown }): boolean
  local numbers = true
  for _, item in items do
    if type(item) == 'table' or hasBreak(item) then return false end

    numbers = numbers and type(item) == 'number'
  end

  if numbers then return true end

  local width = 0
  for _, item in items do
    width += #inline(item) + 2
  end

  return width <= MaxInlineWidth
end

local Pads: { [number]: string } = {}

local function pad(indent: number): string
  local known = Pads[indent]
  if known then return known end

  local spaces = string.rep(' ', indent)
  Pads[indent] = spaces
  return spaces
end

--- Text with line breaks as a literal block, CRLF line endings shown as LF. Text with other
--- control characters can't be a block, and is quoted.
local function putBlockScalar(out: Writer, given: string, indent: number)
  local text = string.gsub(given, '\r\n', '\n')
  if string.find(text, '[%z\1-\8\11-\31\127]') or string.find(text, '\194[\128-\159]') then
    put(out, quote(text))
    put(out, '\n')
    return
  end

  local body = string.gsub(text, '\n+$', '')
  local trailing = #text - #body
  put(out, '|')
  if string.sub(body, 1, 1) == ' ' then put(out, '2') end

  put(out, if trailing == 0 then '-\n' elseif trailing == 1 then '\n' else '+\n')
  local spaces = pad(indent)
  for _, line in string.split(body, '\n') do
    if line ~= '' then
      put(out, spaces)
      put(out, line)
    end

    put(out, '\n')
  end

  put(out, string.rep('\n', math.max(trailing - 1, 0)))
end

local putSequenceItem: (out: Writer, value: unknown, shape: Shape, indent: number) -> ()

--- A value after its key or its `- `: a plain one and its line's end.
local function putScalarLine(out: Writer, value: unknown)
  if type(value) == 'number' and isInteger(value) then
    putInteger(out, value)
  else
    put(out, inline(value))
  end

  put(out, '\n')
end

--- A table's fields, one to a line at `indent`. With `first`, the first line is already begun.
local function putMapping(
  out: Writer,
  members: { [unknown]: unknown },
  shape: Shape,
  indent: number,
  first: boolean
)
  local spaces = pad(indent)
  local count, keys = fieldsOf(members, shape)
  local fields = shape.fields
  local begun = first
  for position = 1, count do
    local key = if keys then keys[position] else (fields :: { Field })[position].key
    local value = members[key]
    if value == nil then continue end

    if not begun then put(out, spaces) end

    begun = false
    put(out, if keys then spelled(YamlKeys, key, yamlKey) else key)
    put(out, ':')
    local inner: Shape = if keys then Readable else (fields :: { Field })[position].shape or Readable
    if type(value) ~= 'table' then
      put(out, ' ')
      if hasBreak(value) then
        putBlockScalar(out, value :: string, indent + 2)
      else
        putScalarLine(out, value)
      end

      continue
    end

    local nested = value :: { [unknown]: unknown }
    if not isList(nested, inner) then
      put(out, '\n')
      putMapping(out, nested, inner, indent + 2, false)
    elseif isInlineSequence(nested :: { unknown }) then
      put(out, ' ')
      put(out, inline(nested))
      put(out, '\n')
    else
      put(out, '\n')
      for _, item in nested :: { unknown } do
        putSequenceItem(out, item, inner.each or Readable, indent)
      end
    end
  end
end

putSequenceItem = function(out: Writer, value: unknown, shape: Shape, indent: number)
  put(out, pad(indent))
  if type(value) ~= 'table' then
    put(out, '- ')
    if hasBreak(value) then
      putBlockScalar(out, value :: string, indent + 2)
    else
      putScalarLine(out, value)
    end

    return
  end

  local members = value :: { [unknown]: unknown }
  if not isList(members, shape) then
    put(out, '- ')
    putMapping(out, members, shape, indent + 2, true)
  elseif isInlineSequence(members :: { unknown }) then
    put(out, '- ')
    put(out, inline(members))
    put(out, '\n')
  else
    put(out, '-\n')
    for _, item in members :: { unknown } do
      putSequenceItem(out, item, shape.each or Readable, indent + 2)
    end
  end
end

--[[ JSON ]]

--- What JSON writes after a backslash for each byte it escapes: a letter for the ones with a
--- short form, `u` for the other control characters (then `00` and the byte in hex), and 0 for a
--- byte that is written as it is. This is serde_json's table, and `@jess/data/value`'s.
local JsonEscapes = buffer.create(256)
for byte = 0, 31 do
  buffer.writeu8(JsonEscapes, byte, 117)
end

for byte, letter in { [8] = 'b', [9] = 't', [10] = 'n', [12] = 'f', [13] = 'r', [34] = '"', [92] = '\\' } do
  buffer.writeu8(JsonEscapes, byte, string.byte(letter))
end

local HexDigits = buffer.fromstring '0123456789abcdef'

--- Text being escaped is read from here, since its escapes are written where it was put.
local escaping = buffer.create(256)

--- Text as a JSON string, between its quotes from `at`, with the escapes its bytes need.
local function putJsonEscaped(out: Writer, text: string, at: number)
  local length = #text
  if buffer.len(escaping) < length then escaping = buffer.create(length * 2) end

  buffer.writestring(escaping, 0, text)
  out.length = at
  -- Six bytes at most for each one, and the quotes.
  reserve(out, length * 6 + 2)
  local source, bytes = escaping, out.bytes
  buffer.writeu8(bytes, at, 34)
  local position = at + 1
  for offset = 0, length - 1 do
    local byte = buffer.readu8(source, offset)
    local escape = buffer.readu8(JsonEscapes, byte)
    if escape == 0 then
      buffer.writeu8(bytes, position, byte)
      position += 1
      continue
    end

    buffer.writeu8(bytes, position, 92)
    buffer.writeu8(bytes, position + 1, escape)
    position += 2
    if escape ~= 117 then continue end

    buffer.writeu16(bytes, position, 0x3030)
    buffer.writeu8(bytes, position + 2, buffer.readu8(HexDigits, byte // 16))
    buffer.writeu8(bytes, position + 3, buffer.readu8(HexDigits, byte % 16))
    position += 4
  end

  buffer.writeu8(bytes, position, 34)
  out.length = position + 1
end

--- Text as a JSON string. It is written as it is, and looked through where it was written for
--- a byte to escape: most text has none, and then nothing more is made of it.
local function putJsonString(out: Writer, text: string)
  local length = #text
  reserve(out, length + 2)
  local bytes, at = out.bytes, out.length
  local finish = at + 1 + length
  buffer.writeu8(bytes, at, 34)
  buffer.writestring(bytes, at + 1, text)
  for position = at + 1, finish - 1 do
    if buffer.readu8(JsonEscapes, buffer.readu8(bytes, position)) ~= 0 then
      putJsonEscaped(out, text, at)
      return
    end
  end

  buffer.writeu8(bytes, finish, 34)
  out.length = finish + 1
end

local function jsonKey(key: string): string return serialize.encode(snake(key), 'json') .. ':' end

local function jsonNextKey(key: string): string return ',' .. jsonKey(key) end

--- A readable value's keys as JSON spells them: an object's first, and one after another.
local JsonKeys: Spelling = { count = 0, names = {} }
local JsonNextKeys: Spelling = { count = 0, names = {} }

local function putJson(out: Writer, value: unknown, shape: Shape)
  if type(value) == 'string' then
    putJsonString(out, value)
    return
  end

  if type(value) == 'number' then
    if isInteger(value) then
      putInteger(out, value)
    elseif value ~= value or math.abs(value) == math.huge then
      put(out, 'null')
    else
      put(out, serialize.shortest(value, true))
    end

    return
  end

  if type(value) ~= 'table' then
    put(out, tostring(value))
    return
  end

  local members = value :: { [unknown]: unknown }
  if isList(members, shape) then
    local each = shape.each or Readable
    putByte(out, 91)
    for position, item in members :: { unknown } do
      if position > 1 then putByte(out, 44) end

      putJson(out, item, each)
    end

    putByte(out, 93)
    return
  end

  local fields = shape.fields
  local begun = false
  putByte(out, 123)
  if fields then
    for _, shaped in fields do
      local item = members[shaped.key]
      if item == nil then continue end

      put(out, if begun then shaped.jsonNext else shaped.json)
      begun = true
      putJson(out, item, shaped.shape or Readable)
    end
  else
    for _, key in sortedKeys(members) do
      local item = members[key]
      if item == nil then continue end

      put(out, if begun then spelled(JsonNextKeys, key, jsonNextKey) else spelled(JsonKeys, key, jsonKey))
      begun = true
      putJson(out, item, Readable)
    end
  end

  putByte(out, 125)
end

--[[ TOML ]]

--- A value as `@jess/data/value` takes one, its fields in the order they are written. A TOML
--- document is tables after values, so it is written from the whole of it at once.
local function tree(value: unknown, shape: Shape): Value
  if type(value) ~= 'table' then return value end

  local members = value :: { [unknown]: unknown }
  if isList(members, shape) then
    local items = table.create(#members)
    for position, item in members :: { unknown } do
      items[position] = tree(item, shape.each or Readable)
    end

    return serialize.array(items)
  end

  local count, keys = fieldsOf(members, shape)
  local fields = shape.fields
  local out = serialize.map()
  for position = 1, count do
    local key = if keys then keys[position] else (fields :: { Field })[position].key
    local item = members[key]
    if item == nil then continue end

    local inner: Shape = if keys then Readable else (fields :: { Field })[position].shape or Readable
    serialize.set(out, if keys then snake(key) else key, tree(item, inner))
  end

  return out
end

--[[ The list ]]

--- The document that is `items` under `records`, each written by `shape`, or a part of it: a page
--- that goes on from one already printed (`continued`) doesn't open the list, and one with pages
--- to follow (`more`) doesn't close it, so a dump's pages printed one after another are the
--- document. TOML has no list to leave open, so it is whole or nothing.
local function records(
  items: { unknown },
  shape: Shape,
  format: 'yaml' | 'json' | 'toml',
  continued: boolean?,
  more: boolean
): string
  if format == 'toml' then
    if continued or more then error('a TOML document can\'t be printed in pages', 0) end

    local document = serialize.map()
    serialize.set(document, 'records', tree(items, { each = shape }))
    return serialize.encode(document, 'toml')
  end

  local out = writer()
  if format == 'json' then
    if not continued then put(out, '{"records":[') end

    for position, item in items do
      if continued or position > 1 then put(out, ',') end

      putJson(out, item, shape)
    end

    if not more then put(out, ']}\n') end

    return finish(out)
  end

  if not continued and #items == 0 and not more then return 'records: []\n' end

  if not continued then put(out, 'records:\n') end

  for _, item in items do
    putSequenceItem(out, item, shape, 0)
  end

  return finish(out)
end

return table.freeze {
  Layout = Layout,
  Listed = Listed,
  Readable = Readable,
  records = records,
  snake = snake,
}
