--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
@tes3cmd/commands: what each `tes3cmd` command does, as a function of one request to one result.

  dump(request)       records as readable values, a listing, their byte layout, or extracted
  stats(request)      record and subrecord counts over plugins
  header(request)     the TES3 header, shown or changed
  diff(request)       what changed between two plugins, record by record
  common(request)     the records two plugins both have
  compare(request)    whether two files are byte for byte the same
  overdial(request)   dialogue topics that contain other topics
  lint(request)       content problems
  validate(request)   the file's format against a profile
  clean(request)      safe dirt removed
  delete(request)     selected records, subrecords, or references removed
  modify(request)     text replaced in the selected records' string fields
  esm(request)        a plugin converted to a master
  esp(request)        a master converted to a plugin
  testCodec(request)  whether files read and write back byte for byte

A request is plain data: paths, a selector spec, options. A result is plain data too, tagged with
its `command`: everything the command learned, the file it wrote, and the backup it kept. Nothing
here reads an argument list, the environment, or standard input, prints, or lays text out for a
terminal; a front end with no terminal gets all of it from the result.

Plugins are named by path. What a command found is in its result: findings, a file among several
that didn't round-trip, an output that is in the way. A request that can't be carried out at all
raises: a file that isn't there or doesn't parse, a pattern that isn't a regex, an output that is
the input.

Every command that writes takes `output` (where to write instead of over the input), `backup`
(false to replace a file without copying it to `.bak`, `.bak1`, ... first), and `dryRun` (do the
work in memory and say what would change, writing nothing). Its result says what was `written`:
nothing for a dry run, or when nothing changed. Masters are found as paths, then beside the plugin.

A dump can be asked for in pages (`from`, `limit`, and the result's `next`), which is how a front
end shows a master's records without holding them all. The plugin a paged dump read is kept until
its last page, or until the file changes; nothing else here outlives its call.
]]

local Compare = require './compare'
local Display = require './display'
local Edit = require './edit'
local Files = require './files'
local Lint = require './lint'
local Masters = require './masters'
local Select = require './select'
local Stats = require './stats'
local fs = require '@dream/fs'
local saves = require '@tes3-saves'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin

export type Encoding = 'win1250' | 'win1251' | 'win1252'
export type SelectorSpec = Select.Spec
export type Written = Files.Written
export type Key = Compare.Key

--- The largest file `@tes3` opens: a plugin's offsets are 32 bits wide.
local MaxPluginLength = 4294967295

--[[ Files ]]

--- Refuses a path nothing is at: a plugin is named by its path, never looked up.
local function mustExist(path: string)
  if jess.fs.exists(path) then return end

  error(`'{path}' doesn't exist; tes3cmd takes plugins by their path`, 0)
end

--- The file's bytes, or why they can't be had. A file too big to be a plugin is refused before
--- any of it is read.
local function load(path: string): (buffer?, string?)
  local size = jess.fs.size(path)
  if size and size > MaxPluginLength then
    return nil, `failed to read '{path}': plugin is 4 GiB or larger at offset 0`
  end

  local bytes, problem = fs.readFile(path)
  if not bytes then return nil, `failed to read '{path}': {problem}` end

  return bytes, nil
end

local function read(path: string): buffer
  mustExist(path)
  local bytes, problem = load(path)
  if not bytes then error(problem, 0) end

  return bytes
end

--- The plugin at `path`, its text read in `encoding`.
local function open(path: string, encoding: Encoding?, profile: tes3.Profile?): Plugin
  local bytes = read(path)
  -- tes3.open raises on bytes that don't frame as records; the error names the file with why.
  local parsed, plugin = pcall(
    function(): Plugin return tes3.open(bytes, { encoding = encoding, profile = profile }) end
  )
  if not parsed then error(`failed to parse '{path}': {plugin}`, 0) end

  return plugin :: Plugin
end

--- What every command that writes takes.
type Writing = { output: string?, backup: boolean?, dryRun: boolean? }

--- Writes an edited plugin to the request's output, or over `path`, unless it's a dry run.
local function write(path: string, plugin: Plugin, request: Writing): Written?
  if request.dryRun then return nil end

  return Files.writeUpdate(path, request.output, plugin:save(), request.backup)
end

local function masters(path: string): Masters.Source return Masters.beside(Masters.paths(), path) end

--- Whether a selector spec selects everything: nothing in it is set.
local function selectsEverything(spec: SelectorSpec?): boolean
  if not spec then return true end

  for _, value in spec :: { [string]: unknown } do
    if type(value) == 'table' and next(value :: { unknown }) == nil then continue end

    if value then return false end
  end

  return true
end

--[[ dump ]]

export type DumpRequest = {
  path: string,
  encoding: Encoding?,
  --- Which records; all of them without any.
  selectors: SelectorSpec?,
  --- Only each record's number, type, and id; with `raw`, each record's layout without its
  --- subrecords.
  list: boolean?,
  --- Each record's byte layout instead of its values.
  raw: boolean?,
  --- Write the selected records, byte for byte, to this file instead of describing them.
  rawOutput: string?,
  --- With `rawOutput`, start the file with the input's TES3 header, its record count updated.
  header: boolean?,
  --- With `rawOutput`, false replaces a file already there without backing it up.
  backup: boolean?,
  --- With `rawOutput`, say what would be written and write nothing.
  dryRun: boolean?,
  --- A dump in pages, for a plugin too big to hold all at once as values: the selected records
  --- from record `from` (0-based; the result's `next`) on, until there are `limit` of them or
  --- the next would take their bytes in the file past `byteLimit`. A page holds at least one
  --- record, so one bigger than `byteLimit` is a page of its own.
  from: number?,
  limit: number?,
  byteLimit: number?,
}

export type Listed = { record: number, type: string, id: string? }

--- A record's byte layout, with its CELL references when instance filters select them.
export type Layout = Display.RecordLayout & { references: { Display.ReferenceLayout }? }

export type DumpResult = {
  command: 'dump',
  path: string,
  --- What was asked for, and so which of the fields below is set: `records` (readable values),
  --- `list` (`listed`), `layout` (`layouts`), or `extract` (`bytes`, `output`, `written`).
  mode: 'records' | 'list' | 'layout' | 'extract',
  records: { { [string]: unknown } }?,
  listed: { Listed }?,
  layouts: { Layout }?,
  --- The size of the extracted file.
  bytes: number?,
  output: string?,
  dryRun: boolean?,
  written: Written?,
  --- For a dump in pages: the record to look from for the next page. Nil once the plugin has
  --- been looked through, as it has for a dump that isn't in pages.
  next: number?,
}

local CellTag = tes3.tags.code 'CELL'

--- The plugin a dump in pages last read, kept for its next page: each page would otherwise read
--- and frame the whole file again. It is that plugin only while the file is the same size and
--- was last written at the same moment, and is let go with the last page.
type Paged = {
  path: string,
  encoding: Encoding?,
  size: number,
  modified: number?,
  plugin: Plugin,
}

local paged: Paged? = nil

local function openPaged(path: string, encoding: Encoding?): Plugin
  mustExist(path)
  local stat = jess.fs.stat(path)
  local size, modified = if stat then stat.size else -1, stat and stat.modified
  local kept = paged
  if
    kept
    and kept.path == path
    and kept.encoding == encoding
    and kept.size == size
    and kept.modified == modified
  then
    return kept.plugin
  end

  local plugin = open(path, encoding)
  paged = { path = path, encoding = encoding, size = size, modified = modified, plugin = plugin }
  return plugin
end

--- A page of a dump: what `build` makes of the records `pick` picks, from the request's `from`
--- on, and the record to go on from when the page ended before the plugin did. `pick` says
--- whether a record is selected, and with what, before anything is made of it: a record that
--- would take the page past its bytes is left for the next page unbuilt.
local function page<Picked, Item>(
  plugin: Plugin,
  request: DumpRequest,
  pick: (index: number) -> Picked?,
  build: (index: number, picked: Picked) -> Item
): ({ Item }, number?)
  local limit, byteLimit = request.limit, request.byteLimit
  local items: { Item } = {}
  local count = plugin:count()
  local bytes = 0
  for index = math.max(request.from or 0, 0), count - 1 do
    local picked = pick(index)
    if not picked then continue end

    local start, finish = plugin:range(index)
    local size = finish - start
    if byteLimit and #items > 0 and bytes + size > byteLimit then return items, index end

    table.insert(items, build(index, picked))
    bytes += size
    if limit and #items >= limit and index + 1 < count then return items, index + 1 end
  end

  return items, nil
end

local function dump(request: DumpRequest): DumpResult
  local path = request.path
  local output = request.rawOutput
  local limit, byteLimit = request.limit, request.byteLimit
  if (limit and limit < 1) or (byteLimit and byteLimit < 1) then
    error('a page of a dump holds at least one record', 0)
  end

  local plugin = if (limit or byteLimit) and not output
    then openPaged(path, request.encoding)
    else open(path, request.encoding)
  local selector = Select.new(request.selectors)

  if output then
    local bytes = Edit.extractMatching(plugin, selector, request.header == true)
    local written: Written? = nil
    if not request.dryRun then
      written = jess.fs.write(output, bytes, { backup = request.backup ~= false })
    end

    return {
      command = 'dump',
      path = path,
      mode = 'extract',
      bytes = buffer.len(bytes),
      output = output,
      dryRun = request.dryRun == true,
      written = written,
    }
  end

  if request.raw then
    local instances = not request.list and Select.hasInstanceFilters(selector)
    local layouts, more = page(
      plugin,
      request,
      function(index: number): boolean? return Select.matchesRecord(selector, plugin, index) or nil end,
      function(index: number): Layout
        local layout: Layout =
          Display.layout(plugin, index, selector, { subrecords = not request.list, fields = true })
        if instances and plugin:code(index) == CellTag then
          layout.references = Display.references(plugin, index, selector, true)
        end

        return layout
      end
    )

    if not more then paged = nil end

    return { command = 'dump', path = path, mode = 'layout', layouts = layouts, next = more }
  end

  if request.list then
    local listed, more = page(
      plugin,
      request,
      function(index: number): Select.Selection? return Select.selection(selector, plugin, index) end,
      function(index: number): Listed
        local id = tes3.records.id(plugin, index)
        return {
          record = index,
          type = tes3.tags.display(plugin:code(index)),
          id = if id and id ~= '' then id else nil,
        }
      end
    )

    if not more then paged = nil end

    return { command = 'dump', path = path, mode = 'list', listed = listed, next = more }
  end

  local records, more = page(
    plugin,
    request,
    function(index: number): Select.Selection? return Select.selection(selector, plugin, index) end,
    function(index: number, picked: Select.Selection): { [string]: unknown }
      return tes3.display.display(plugin, index, picked.references)
    end
  )

  if not more then paged = nil end

  return { command = 'dump', path = path, mode = 'records', records = records, next = more }
end

--[[ stats ]]

export type StatsRequest = { paths: { string } }

export type StatsResult = {
  command: 'stats',
  --- The plugins counted, in the order given.
  paths: { string },
  files: number,
  records: number,
  --- Records by tag.
  recordTypes: { [string]: number },
  --- Subrecords by `RECORD.SUBRECORD`.
  subrecordTypes: { [string]: number },
  --- Records by `RECORD.SUBRECORD`, for subrecords that repeat within one record.
  listSubrecords: { [string]: number },
}

local function stats(request: StatsRequest): StatsResult
  if #request.paths == 0 then error('stats requires at least one plugin', 0) end

  for _, path in request.paths do
    mustExist(path)
  end

  local counted = Stats.new()
  for _, path in request.paths do
    Stats.add(counted, open(path))
  end

  return {
    command = 'stats',
    paths = request.paths,
    files = counted.plugins,
    records = counted.records,
    recordTypes = counted.recordTypes,
    subrecordTypes = counted.subrecordTypes,
    listSubrecords = counted.listSubrecords,
  }
end

--[[ header ]]

export type HeaderRequest = {
  path: string,
  encoding: Encoding?,
  --- The new author; one starting with `+` is added to the author there is.
  author: string?,
  --- The new description; `+` adds, and `\n` and `\r` in it are line breaks.
  description: string?,
  --- Set the record count to the number of records.
  updateRecordCount: boolean?,
  --- Set each master's recorded size to its file's size.
  updateMasters: boolean?,
  output: string?,
  backup: boolean?,
  dryRun: boolean?,
}

export type HeaderResult = {
  command: 'header',
  path: string,
  --- The header as it is now: after the changes, written or (for a dry run) not.
  author: string,
  description: string,
  recordCount: number,
  --- The masters whose recorded size changed.
  mastersUpdated: { Lint.MasterSizeChange },
  dryRun: boolean,
  written: Written?,
}

local function header(request: HeaderRequest): HeaderResult
  local path = request.path
  local changes = request.author ~= nil
    or request.description ~= nil
    or request.updateRecordCount == true
    or request.updateMasters == true
  if not changes and request.output then
    error('an output was named with no change to the header to write there', 0)
  end

  mustExist(path)
  Files.checkOutput(path, request.output)
  local plugin = open(path, request.encoding)
  local changed, synced = Lint.updateHeader(plugin, {
    author = request.author,
    description = request.description,
    syncMasters = request.updateMasters,
    recordCount = request.updateRecordCount,
  }, masters(path))
  local written = if changed then write(path, plugin, request) else nil
  local now = plugin:header()
  return {
    command = 'header',
    path = path,
    author = now.author,
    description = now.description,
    recordCount = now.recordCount,
    mastersUpdated = synced,
    dryRun = request.dryRun == true,
    written = written,
  }
end

--[[ diff, common, compare, overdial ]]

export type DiffRequest = {
  left: string,
  right: string,
  encoding: Encoding?,
  --- Also list the records both plugins have unchanged.
  equal: boolean?,
  --- Record types to leave out: tags or type names.
  ignoreTypes: { string }?,
}

export type DiffResult = {
  command: 'diff',
  left: string,
  right: string,
  leftOnly: { Key },
  rightOnly: { Key },
  equal: { Key }?,
  changed: { Compare.ChangedRecord },
}

local function diff(request: DiffRequest): DiffResult
  mustExist(request.left)
  mustExist(request.right)
  local left = open(request.left, request.encoding)
  local right = open(request.right, request.encoding)
  local ignored = {}
  for _, value in request.ignoreTypes or {} do
    table.insert(ignored, Select.parseType(value))
  end

  local report = Compare.diff(left, right, ignored, request.equal)
  return {
    command = 'diff',
    left = request.left,
    right = request.right,
    leftOnly = report.leftOnly,
    rightOnly = report.rightOnly,
    equal = report.equal,
    changed = report.changed,
  }
end

export type CommonRequest = { left: string, right: string, encoding: Encoding? }

export type CommonResult = { command: 'common', left: string, right: string, records: { Key } }

local function common(request: CommonRequest): CommonResult
  mustExist(request.left)
  mustExist(request.right)
  local left = open(request.left, request.encoding)
  local right = open(request.right, request.encoding)
  return {
    command = 'common',
    left = request.left,
    right = request.right,
    records = Compare.common(left, right),
  }
end

export type CompareRequest = { left: string, right: string }

export type CompareResult = {
  command: 'compare',
  left: string,
  right: string,
  identical: boolean,
  leftBytes: number,
  rightBytes: number,
  --- The first offset where they differ: the shorter file's length when one starts the other.
  firstDifference: number?,
}

local function compare(request: CompareRequest): CompareResult
  mustExist(request.left)
  mustExist(request.right)
  local compared = Compare.compareBytes(read(request.left), read(request.right))
  return {
    command = 'compare',
    left = request.left,
    right = request.right,
    identical = compared.identical,
    leftBytes = compared.leftBytes,
    rightBytes = compared.rightBytes,
    firstDifference = compared.firstDifference,
  }
end

export type OverdialRequest = {
  --- Two or more plugins, in load order.
  paths: { string },
  encoding: Encoding?,
  --- Only the first plugin's topics, against the later plugins'.
  single: boolean?,
}

export type OverdialResult = {
  command: 'overdial',
  paths: { string },
  overlaps: { Compare.TopicOverlap },
}

local function overdial(request: OverdialRequest): OverdialResult
  if #request.paths < 2 then error('overdial requires at least two plugins', 0) end

  local plugins = {}
  for _, path in request.paths do
    mustExist(path)
    local plugin = open(path, request.encoding)
    table.insert(plugins, { name = path, topics = tes3.records.dialogueTopics(plugin) })
  end

  return {
    command = 'overdial',
    paths = request.paths,
    overlaps = Compare.overlaps(plugins, request.single),
  }
end

--[[ lint, validate ]]

--- The least severe finding that counts against a plugin: errors, errors and warnings, anything,
--- or nothing.
export type FailOn = 'error' | 'warning' | 'any' | 'never'

export type LintRequest = {
  path: string,
  encoding: Encoding?,
  --- Checks by name, in any spelling `@tes3cmd`'s `parseCheck` takes.
  checks: { string }?,
  --- Presets, whose checks are added to the ones named.
  presets: { 'all' | 'recommended' }?,
  --- With neither checks nor presets, the recommended checks run. Default `error`.
  failOn: FailOn?,
}

export type LintResult = {
  command: 'lint',
  path: string,
  --- The checks that ran, camelCase, in the order `@tes3cmd` declares them.
  checks: { string },
  --- Findings by severity.
  summary: { errors: number, warnings: number, info: number },
  findings: { Lint.Finding },
  failOn: FailOn,
  --- How many findings are at least as severe as `failOn`.
  failing: number,
}

--- Which severities each `failOn` counts.
local Failing: { [FailOn]: { [Lint.Severity]: boolean } } = {
  error = { error = true },
  warning = { error = true, warning = true },
  any = { error = true, warning = true, info = true },
  never = {},
}

local function lint(request: LintRequest): LintResult
  local failOn: FailOn = request.failOn or 'error'
  local counts = Failing[failOn]
  if not counts then
    error(`unknown failOn '{failOn}': expected error, warning, any, or never`, 0)
  end

  local set: Lint.CheckSet = {}
  for _, name in request.checks or {} do
    set[Lint.parseCheck(name)] = true
  end

  for _, preset in request.presets or {} do
    for label in Lint.preset(preset) do
      set[label] = true
    end
  end

  if next(set) == nil then set = Lint.preset 'recommended' end

  local path = request.path
  mustExist(path)
  local findings = Lint.lint(open(path, request.encoding), set, masters(path))
  local ran = {}
  for _, check in Lint.Checks do
    if set[check.label] then table.insert(ran, Lint.camelCase(check.label)) end
  end

  local summary = { errors = 0, warnings = 0, info = 0 }
  local failing = 0
  for _, finding in findings do
    if finding.severity == 'error' then
      summary.errors += 1
    elseif finding.severity == 'warning' then
      summary.warnings += 1
    else
      summary.info += 1
    end

    if counts[finding.severity] then
      failing += 1
    end
  end

  return {
    command = 'lint',
    path = path,
    checks = ran,
    summary = summary,
    findings = findings,
    failOn = failOn,
    failing = failing,
  }
end

export type ValidateRequest = {
  path: string,
  encoding: Encoding?,
  --- What to check the file against: `raw` (its structure), `tes3` (also what Morrowind.exe
  --- doesn't know), `omwaddon` (also what OpenMW refuses or skips; the default), or `omwsave` (an
  --- OpenMW save's header, format, and cell state).
  profile: tes3.Profile?,
}

export type ValidateResult = {
  command: 'validate',
  path: string,
  profile: tes3.Profile,
  --- What the profile checked, by name, camelCase.
  checks: { string },
  valid: boolean,
  diagnostics: { tes3.Diagnostic },
}

local Profiles: { [string]: boolean } = { raw = true, tes3 = true, omwaddon = true, omwsave = true }

local function validate(request: ValidateRequest): ValidateResult
  local profile: tes3.Profile = request.profile or 'omwaddon'
  if not Profiles[profile] then
    error(`unknown profile '{profile}': expected raw, tes3, omwaddon, or omwsave`, 0)
  end

  local path = request.path
  mustExist(path)
  local plugin = open(path, request.encoding)
  -- A save's own structure is `@tes3-saves`'s to check; every other profile is a plugin's.
  local validation = if profile == 'omwsave'
    then saves.validate(plugin)
    else Lint.validate(plugin, profile)
  return {
    command = 'validate',
    path = path,
    profile = profile,
    checks = validation.checks,
    valid = #validation.diagnostics == 0,
    diagnostics = validation.diagnostics,
  }
end

--[[ clean, delete, modify ]]

export type CleanKind = 'duplicateRecords' | 'evilGmsts' | 'cellParams' | 'junkCells'

--- Every cleanup, in the order a report lists the ones that ran.
local CleanKinds: { CleanKind } = { 'duplicateRecords', 'evilGmsts', 'cellParams', 'junkCells' }

export type CleanRequest = {
  path: string,
  encoding: Encoding?,
  --- The cleanups to run; every one of them when none is named.
  kinds: { CleanKind }?,
  output: string?,
  backup: boolean?,
  dryRun: boolean?,
}

export type CleanResult = {
  command: 'clean',
  path: string,
  --- The cleanups that ran.
  cleanups: { CleanKind },
  removedRecords: number,
  removedSubrecords: number,
  --- The positions the removed records had before cleaning, ascending (0-based).
  removedRecordIndices: { number },
  --- Whether the header's record count changed with the records removed.
  recordCountUpdated: boolean,
  dryRun: boolean,
  written: Written?,
}

local function clean(request: CleanRequest): CleanResult
  local which: { [string]: boolean } = {}
  for _, kind in request.kinds or {} do
    if not table.find(CleanKinds, kind) then
      error(`unknown cleanup '{kind}': expected {table.concat(CleanKinds, ', ')}`, 0)
    end

    which[kind] = true
  end

  local all = next(which) == nil
  local cleanups: { CleanKind } = {}
  for _, kind in CleanKinds do
    which[kind] = all or which[kind] == true
    if which[kind] then table.insert(cleanups, kind) end
  end

  local path = request.path
  mustExist(path)
  Files.checkOutput(path, request.output)
  local plugin = open(path, request.encoding)
  local report = Lint.clean(plugin, which, masters(path))
  local changed = report.removedRecords > 0 or report.removedSubrecords > 0
  return {
    command = 'clean',
    path = path,
    cleanups = cleanups,
    removedRecords = report.removedRecords,
    removedSubrecords = report.removedSubrecords,
    removedRecordIndices = report.removedRecordIndices,
    recordCountUpdated = report.recordCountUpdated,
    dryRun = request.dryRun == true,
    written = if changed then write(path, plugin, request) else nil,
  }
end

export type DeleteRequest = {
  path: string,
  encoding: Encoding?,
  --- What to delete: whole records, or with subrecord or instance filters, the matching
  --- subrecords or CELL references of the records picked. At least one selector is required.
  selectors: SelectorSpec,
  output: string?,
  backup: boolean?,
  dryRun: boolean?,
}

export type DeleteResult = {
  command: 'delete',
  path: string,
  --- How many `unit`s went: records, or the subrecords and references subrecord or instance
  --- filters picked, counted together as items.
  deleted: number,
  unit: 'records' | 'items',
  records: number,
  subrecords: number,
  references: number,
  --- The positions the deleted records had before the deletion, ascending (0-based).
  recordIndices: { number },
  --- Whether the header's record count changed with the records deleted.
  recordCountUpdated: boolean,
  dryRun: boolean,
  written: Written?,
}

local function delete(request: DeleteRequest): DeleteResult
  if selectsEverything(request.selectors) then
    error('delete needs at least one selector; without one it would delete every record', 0)
  end

  local path = request.path
  mustExist(path)
  Files.checkOutput(path, request.output)
  local plugin = open(path, request.encoding)
  local selector = Select.new(request.selectors)
  local removed = Edit.deleteMatching(plugin, selector)
  local parts = Select.hasSubrecordFilters(selector) or Select.hasInstanceFilters(selector)
  local count = if parts then removed.subrecords + removed.references else removed.records
  return {
    command = 'delete',
    path = path,
    deleted = count,
    unit = if parts then 'items' else 'records',
    records = removed.records,
    subrecords = removed.subrecords,
    references = removed.references,
    recordIndices = removed.recordIndices,
    recordCountUpdated = removed.recordCountUpdated,
    dryRun = request.dryRun == true,
    written = if count > 0 then write(path, plugin, request) else nil,
  }
end

export type ModifyRequest = {
  path: string,
  encoding: Encoding?,
  --- Which records, and with subrecord filters, which of their string fields. Instance filters
  --- can't select fields.
  selectors: SelectorSpec?,
  --- `/pattern/replacement/`: a case-insensitive regex and what replaces each match of it in
  --- the selected string fields. Any first character is the delimiter.
  replace: string,
  --- Replace only the first match in each field.
  first: boolean?,
  output: string?,
  backup: boolean?,
  dryRun: boolean?,
}

export type ModifyResult = {
  command: 'modify',
  path: string,
  --- The string fields that changed, and the records they are in.
  fields: number,
  records: number,
  dryRun: boolean,
  written: Written?,
}

local function modify(request: ModifyRequest): ModifyResult
  local path = request.path
  mustExist(path)
  Files.checkOutput(path, request.output)
  local plugin = open(path, request.encoding)
  local selector = Select.new(request.selectors)
  local replacement = Edit.parseReplacement(request.replace, not request.first)
  local report = Edit.replaceMatching(plugin, selector, replacement)
  return {
    command = 'modify',
    path = path,
    fields = report.fields,
    records = report.records,
    dryRun = request.dryRun == true,
    written = if report.fields > 0 then write(path, plugin, request) else nil,
  }
end

--[[ esm, esp ]]

export type ConvertRequest = {
  path: string,
  --- Where to write; beside the input with the other extension by default.
  output: string?,
  --- Replace a file already at the output.
  overwrite: boolean?,
  backup: boolean?,
  dryRun: boolean?,
}

export type ConvertResult = {
  command: 'esm' | 'esp',
  path: string,
  --- The file type the converted file has.
  fileType: 'master' | 'plugin',
  --- Where the converted file goes.
  output: string,
  --- A file is already at the output and replacing it wasn't asked for: nothing was converted.
  blocked: boolean,
  dryRun: boolean,
  written: Written?,
}

local function convert(
  command: 'esm' | 'esp',
  fileType: 'master' | 'plugin',
  request: ConvertRequest
): ConvertResult
  local path = request.path
  mustExist(path)
  local planned = Files.conversion(path, fileType, request.output)
  local blocked = planned.exists and not request.overwrite
  local written: Written? = nil
  if not blocked then
    written = Files.convert(path, fileType, {
      output = request.output,
      overwrite = request.overwrite,
      backup = request.backup,
      dryRun = request.dryRun,
    }).written
  end

  return {
    command = command,
    path = path,
    fileType = fileType,
    output = planned.output,
    blocked = blocked,
    dryRun = request.dryRun == true,
    written = written,
  }
end

local function esm(request: ConvertRequest): ConvertResult return convert('esm', 'master', request) end

local function esp(request: ConvertRequest): ConvertResult return convert('esp', 'plugin', request) end

--[[ testCodec ]]

export type TestCodecRequest = {
  paths: { string },
  --- Check the files after one that fails too.
  keepGoing: boolean?,
  --- Ignore bytes before the first TES3.
  ignoreCruft: boolean?,
  --- Record types to leave out of the comparison: tags or type names.
  excludeTypes: { string }?,
}

export type CodecFile = {
  path: string,
  ok: boolean,
  --- Why not: the file can't be read, doesn't parse, or comes back changed.
  error: string?,
  --- For a file that comes back changed, the offset in the file of the first byte that differs.
  firstDifference: number?,
  --- And the record that byte is in.
  record: { index: number, type: string, id: string? }?,
}

export type TestCodecResult = {
  command: 'testCodec',
  --- One per file checked: the files after a failure aren't, unless the request keeps going.
  results: { CodecFile },
  failed: number,
}

--- Where a file that doesn't come back the same first differs from what it was saved as: the
--- offset in the file, and the record there. Nothing for a file that doesn't parse.
local function firstChange(
  bytes: buffer,
  excluded: { string },
  ignoreCruft: boolean?
): (number?, Compare.RecordDifference?)
  local source, skipped = bytes, 0
  local start = if ignoreCruft then string.find(buffer.tostring(bytes), 'TES3', 1, true) else nil
  if start and start > 1 then
    skipped = start - 1
    source = buffer.create(buffer.len(bytes) - skipped)
    buffer.copy(source, 0, bytes, skipped)
  end

  -- tes3.open raises on bytes that don't frame as records, and then there is no place to name.
  local parsed, plugin = pcall(function(): Plugin return tes3.open(source) end)
  if not parsed then return nil, nil end

  local saved = (plugin :: Plugin):save()
  local whole = Compare.compareBytes(source, saved).firstDifference
  -- And on saved bytes that no longer frame: the first byte that differs is all there is to say.
  local framed, reopened = pcall(function(): Plugin return tes3.open(saved) end)
  if not framed then return whole and whole + skipped, nil end

  local record = Compare.firstDifference(plugin :: Plugin, reopened :: Plugin, excluded)
  local offset = if #excluded > 0 then record and record.offset else whole
  return offset and offset + skipped, record
end

local function testCodec(request: TestCodecRequest): TestCodecResult
  if #request.paths == 0 then error('test-codec requires at least one plugin', 0) end

  local excluded = {}
  for _, value in request.excludeTypes or {} do
    table.insert(excluded, Select.parseType(value))
  end

  local results: { CodecFile } = {}
  local failed = 0
  for _, path in request.paths do
    mustExist(path)
    local bytes, problem = load(path)
    local checked: CodecFile = { path = path, ok = false, error = problem }
    if bytes then
      checked.error = tes3.checkRoundTrip(bytes, excluded, request.ignoreCruft)
      checked.ok = checked.error == nil
    end

    if bytes and not checked.ok then
      local offset, record = firstChange(bytes, excluded, request.ignoreCruft)
      checked.firstDifference = offset
      checked.record = record and { index = record.index, type = record.type, id = record.id }
    end

    table.insert(results, checked)
    if checked.ok then continue end

    failed += 1
    if not request.keepGoing then break end
  end

  return { command = 'testCodec', results = results, failed = failed }
end

export type Result =
  DumpResult
  | StatsResult
  | HeaderResult
  | DiffResult
  | CommonResult
  | CompareResult
  | OverdialResult
  | LintResult
  | ValidateResult
  | CleanResult
  | DeleteResult
  | ModifyResult
  | ConvertResult
  | TestCodecResult

return table.freeze {
  CleanKinds = table.freeze(CleanKinds),
  clean = clean,
  common = common,
  compare = compare,
  delete = delete,
  diff = diff,
  dump = dump,
  esm = esm,
  esp = esp,
  header = header,
  lint = lint,
  modify = modify,
  overdial = overdial,
  stats = stats,
  testCodec = testCodec,
  validate = validate,
}
