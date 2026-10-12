--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The `tes3cmd` command line as data: every command with its arguments and flags as `jess plugin`
declared them (names, short forms, other spellings, value names, and help), the reading of an
argument list against them into the request `@tes3cmd/commands` takes, and the help printed from
them. No file is touched here.

A flag is spelled `--name value` or `--name=value`, a short one `-t value`, `-tvalue`, or
`-t=value`; `--` ends the flags. Flags and arguments come in any order, `--format` anywhere on the
line, before the command or after it.
]]

local Commands = require './commands'

export type Format = 'yaml' | 'json' | 'toml'

export type Request =
  Commands.DumpRequest
  | Commands.StatsRequest
  | Commands.HeaderRequest
  | Commands.DiffRequest
  | Commands.CommonRequest
  | Commands.CompareRequest
  | Commands.OverdialRequest
  | Commands.LintRequest
  | Commands.ValidateRequest
  | Commands.CleanRequest
  | Commands.DeleteRequest
  | Commands.ModifyRequest
  | Commands.ConvertRequest
  | Commands.TestCodecRequest

--- What an argument list asks for: a command of `@tes3cmd/commands` by name with its request and
--- the format to print its result in, or help (on `topic`, a command, when one was named), or the
--- version.
export type Command = {
  command: string,
  format: Format?,
  request: Request?,
  topic: string?,
}

--- A flag: what it is called, whether it takes a value (`value`, its name in help) and may repeat
--- (`many`), and what it does to the request: sets `set`'s fields, adds `item` to the list at
--- `field`, or puts its value at `field` (added to the list there when it may repeat). A field
--- with a dot is a field of the table at the name before it.
type Flag = {
  long: string,
  short: string?,
  aliases: { string }?,
  value: string?,
  many: boolean?,
  choices: { string }?,
  field: string?,
  item: string?,
  set: { [string]: unknown }?,
  help: string,
}

--- An argument that isn't a flag: its name in help, the request field it fills, and whether it
--- takes every argument left (then at least `least` of them).
type Positional = { name: string, field: string, many: boolean?, least: number?, help: string }

type Spec = {
  name: string,
  --- The name of the `@tes3cmd/commands` function, where it isn't the command's own.
  command: string?,
  aliases: { string }?,
  about: string,
  flags: { Flag },
  positionals: { Positional },
  --- What is wrong with a request no flag's own rules refuse, given the flags that were used.
  check: ((request: { [string]: unknown }, used: { [string]: boolean }) -> string?)?,
}

type Extra = { short: string?, aliases: { string }?, choices: { string }? }

--- A flag that takes no value and sets fields.
local function switch(long: string, help: string, set: { [string]: unknown }, extra: Extra?): Flag
  return {
    long = long,
    help = help,
    set = set,
    short = extra and extra.short,
    aliases = extra and extra.aliases,
  }
end

--- A flag that takes no value and adds `item` to the list at `field`.
local function adds(long: string, help: string, field: string, item: string, extra: Extra?): Flag
  return {
    long = long,
    help = help,
    field = field,
    item = item,
    aliases = extra and extra.aliases,
  }
end

--- A flag that takes one value, once.
local function value(long: string, name: string, help: string, field: string, extra: Extra?): Flag
  return {
    long = long,
    value = name,
    help = help,
    field = field,
    short = extra and extra.short,
    aliases = extra and extra.aliases,
    choices = extra and extra.choices,
  }
end

--- A flag that takes one value each time it is given.
local function list(long: string, name: string, help: string, field: string, extra: Extra?): Flag
  local flag = value(long, name, help, field, extra)
  flag.many = true
  return flag
end

local function join(...: { Flag }): { Flag }
  local out = {}
  for _, flags in { ... } do
    table.move(flags, 1, #flags, #out + 1, out)
  end

  return out
end

local Formats = { 'yaml', 'json', 'toml' }

local FormatFlag = value(
  'format',
  'FORMAT',
  'Output format: YAML (the default), compact one-line JSON, or TOML. Raw byte-layout dumps default to JSON.',
  'format',
  { choices = Formats }
)

local HelpFlag: Flag = { long = 'help', short = 'h', help = 'Print help' }
local VersionFlag: Flag = { long = 'version', short = 'V', help = 'Print version' }

local Selectors: { Flag } = {
  list('type', 'TYPES', 'Only match record types. Can be repeated.', 'selectors.type', { short = 't' }),
  list(
    'flag',
    'FLAGS',
    'Only match records with any of these flags. Names: deleted, persistent, ignored, blocked.',
    'selectors.flags'
  ),
  list(
    'id',
    'ID',
    'Only match records whose ID matches this case-insensitive regex. Can be repeated.',
    'selectors.id'
  ),
  list(
    'exact-id',
    'EXACT_ID',
    'Only match records whose ID exactly matches this string. Can be repeated.',
    'selectors.exactId'
  ),
  list(
    'match',
    'MATCHES',
    'Only match records whose raw bytes match this case-insensitive regex. Can be repeated.',
    'selectors.match'
  ),
  list(
    'no-match',
    'NO_MATCHES',
    'Skip records whose raw bytes match this case-insensitive regex. Can be repeated.',
    'selectors.notMatch'
  ),
  value(
    'sub-match',
    'SUB_MATCH',
    'Only match subrecords whose rendered raw text matches this regex.',
    'selectors.sub'
  ),
  value(
    'sub-no-match',
    'SUB_NO_MATCH',
    'Skip subrecords whose rendered raw text matches this regex.',
    'selectors.notSub'
  ),
  value(
    'instance-match',
    'INSTANCE_MATCH',
    'Only match CELL reference groups whose rendered raw text matches this regex.',
    'selectors.instance'
  ),
  value(
    'instance-no-match',
    'INSTANCE_NO_MATCH',
    'Skip CELL reference groups whose rendered raw text matches this regex.',
    'selectors.notInstance'
  ),
  switch('interior', 'Only match interior CELL records.', { ['selectors.interior'] = true }),
  switch('exterior', 'Only match exterior CELL records.', { ['selectors.exterior'] = true }),
}

local Encoding: { Flag } = {
  value(
    'encoding',
    'ENCODING',
    'The code page the plugin\'s text is in: win1252 for English and Western European releases, win1251 for Russian, win1250 for Central European. By default, win1252.',
    'encoding',
    { choices = { 'win1250', 'win1251', 'win1252' } }
  ),
}

local Write: { Flag } = {
  switch('dry-run', 'Report what would change without writing anything.', { dryRun = true }),
  switch(
    'no-backup',
    'Don\'t back up files before writing over them (normally copied to .bak, .bak1, ...).',
    { backup = false }
  ),
}

local function output(help: string): { Flag } return { value('output', 'OUTPUT', help, 'output') } end

local function input(help: string): { Positional }
  return { { name = 'INPUT', field = 'path', help = help } }
end

local function pair(left: string, right: string): { Positional }
  return {
    { name = 'LEFT', field = 'left', help = left },
    { name = 'RIGHT', field = 'right', help = right },
  }
end

--- `--output` naming the input: an edit over its input is what leaving `--output` out is for.
local function sameOutput(action: string, request: { [string]: unknown }): string?
  if request.output and request.output == request.path then
    return `{action} --output must differ from resolved input`
  end

  return nil
end

--- `modify --script` ran a Luau script on the plugin. A package can't: it has no way to turn a
--- file it is handed into code.
local NoScript =
  '--script isn\'t available: today\'s Jess gives a package no way to load and run a script file handed to it at run time. Write the edit as a Luau script over @tes3 and @tes3cmd, and run that with jess run --package'

local WhichCheck =
  'Which check: lint asks whether a plugin\'s content is sensible, and validate whether its format loads in Morrowind.exe or OpenMW.'

--- Every lint check's flag, in the order `jess plugin lint --help` listed them.
local LintChecks: { Flag } = {
  adds(
    'duplicate-records',
    'Report duplicate records with the same type and ID.',
    'checks',
    'duplicate-records'
  ),
  adds(
    'evil-gmsts',
    'Report Evil GMSTs: Tribunal and Bloodmoon GMSTs the Construction Set leaks into plugins, still at the expansion\'s value.',
    'checks',
    'evil-gmsts',
    { aliases = { 'gmsts' } }
  ),
  adds('overrides', 'Report records that override a master record.', 'checks', 'overrides'),
  adds('missing-author', 'Report missing HEDR author.', 'checks', 'missing-author'),
  adds('missing-description', 'Report missing HEDR description.', 'checks', 'missing-description'),
  adds(
    'missing-version',
    'Report missing Version text in TES3 description.',
    'checks',
    'missing-version'
  ),
  adds('missing-master', 'Report TES3 masters that cannot be resolved.', 'checks', 'missing-master'),
  adds(
    'master-sync',
    'Report TES3 master DATA sizes that do not match resolved files.',
    'checks',
    'master-sync'
  ),
  adds(
    'cell-params',
    'Report duplicate CELL header params before references.',
    'checks',
    'cell-params'
  ),
  adds('junk-cells', 'Report conservatively empty CELL records.', 'checks', 'junk-cells'),
  adds('record-count', 'Report mismatched HEDR record count.', 'checks', 'record-count'),
  adds('fogbug', 'Report interior CELL fog density set to zero.', 'checks', 'fogbug'),
  adds(
    'fogsync',
    'Report CELL DATA/AMBI fog density mismatches when both values are present.',
    'checks',
    'fogsync'
  ),
  adds('autocalc-spells', 'Report autocalc spells.', 'checks', 'autocalc-spells'),
  adds(
    'bloodmoon-dependency',
    'Report Bloodmoon feature usage without Bloodmoon.esm.',
    'checks',
    'bloodmoon-dependency'
  ),
  adds('cell-00', 'Report possible dirty exterior CELL 0,0 copies.', 'checks', 'cell-00'),
  adds(
    'deprecated-lists',
    'Report scripts that modify standard leveled lists.',
    'checks',
    'deprecated-lists'
  ),
  adds('getsoundplaying', 'Report suspicious GetSoundPlaying usage.', 'checks', 'getsoundplaying'),
  adds('menumode', 'Report scripts that do not mention MenuMode.', 'checks', 'menumode'),
  adds('scripted-doors', 'Report scripts attached to door records.', 'checks', 'scripted-doors'),
  adds('dialogue-teleports', 'Report dialogue result teleports.', 'checks', 'dialogue-teleports'),
  adds('duplicate-info', 'Report duplicate INFO IDs.', 'checks', 'duplicate-info'),
  adds(
    'modified-info',
    'Report INFO records that override master INFO records with changed bytes.',
    'checks',
    'modified-info'
  ),
  adds(
    'modified-info-id',
    'Report duplicate INFO text under different IDs.',
    'checks',
    'modified-info-id',
    { aliases = { 'modified-info_id' } }
  ),
  adds(
    'expansion-dependency',
    'Report expansion feature usage without expansion masters.',
    'checks',
    'expansion-dependency'
  ),
  adds(
    'no-bloodmoon-functions',
    'Report Bloodmoon.esm dependency without detected Bloodmoon functions.',
    'checks',
    'no-bloodmoon-functions'
  ),
  adds(
    'no-tribunal-functions',
    'Report Tribunal.esm dependency without detected Tribunal functions.',
    'checks',
    'no-tribunal-functions'
  ),
}

local ConvertFlags: { Flag } = join(
  {
    switch(
      'overwrite',
      'Replace the output file if it already exists (after backing it up).',
      { overwrite = true }
    ),
  },
  output 'Write the converted file here instead of next to the input with the new extension.',
  Write
)

local function sameConverted(request: { [string]: unknown }): string?
  if request.output and request.output == request.path then
    return 'conversion output must differ from resolved input'
  end

  return nil
end

local Specs: { Spec } = {
  {
    name = 'dump',
    about = 'Print records as readable values, or their byte layout with --raw.',
    flags = join(
      Selectors,
      {
        switch('list', 'Only list the matching records\' number, type, and id.', { list = true }),
        switch(
          'raw',
          'Print each record\'s byte layout (tags, sizes, byte ranges, decoded fields) instead of its values. JSON unless --format says otherwise.',
          { raw = true }
        ),
        value(
          'raw-output',
          'PATH',
          'Write the matching records, byte for byte, to a new plugin file instead of dumping them.',
          'rawOutput'
        ),
        switch(
          'header',
          'With --raw-output, start the file with the input\'s TES3 header, so it loads as a plugin.',
          { header = true }
        ),
        switch(
          'no-backup',
          'With --raw-output, don\'t back up a file already at that path before replacing it.',
          { backup = false }
        ),
      },
      Encoding
    ),
    positionals = input 'The file to dump: its path.',
    check = function(request, used): string?
      for _, flag in { 'header', 'no-backup' } do
        if used[flag] and not request.rawOutput then
          return `--{flag} requires --raw-output <PATH>`
        end
      end

      return nil
    end,
  },
  {
    name = 'stats',
    about = 'Count records and subrecords by type.',
    flags = {},
    positionals = {
      {
        name = 'INPUT',
        field = 'paths',
        many = true,
        least = 1,
        help = 'Plugins to count, by path. Counts are summed over all of them.',
      },
    },
  },
  {
    name = 'header',
    about = 'Show the header (author, description, masters, record count), or change it.',
    flags = join(
      {
        switch(
          'update-record-count',
          'Set the header\'s record count to the number of records.',
          { updateRecordCount = true }
        ),
        switch(
          'update-masters',
          'Set each master\'s recorded size to its file\'s current size, found by path or beside the plugin.',
          { updateMasters = true }
        ),
        switch(
          'synchronize',
          'Both --update-masters and --update-record-count (tes3cmd\'s name).',
          { updateRecordCount = true, updateMasters = true },
          { aliases = { 'sync' } }
        ),
        value(
          'author',
          'AUTHOR',
          'Set the author. Start it with + to append to the author instead.',
          'author'
        ),
        value(
          'description',
          'DESCRIPTION',
          'Set the description. Start it with + to append instead; \\n and \\r in it are line breaks.',
          'description'
        ),
      },
      output 'Write the edited plugin here instead of over the input.',
      Write,
      Encoding
    ),
    positionals = input 'The plugin, by its path. Without a change to make, its header is shown.',
    check = function(request): string?
      local changes = request.author
        or request.description
        or request.updateRecordCount
        or request.updateMasters
      if request.output and not changes then
        return 'header --output requires a header mutation flag'
      end

      return sameOutput('header', request)
    end,
  },
  {
    name = 'diff',
    about = 'What changed between two plugins, record by record.',
    flags = join({
      switch('equal', 'Also list the records both plugins have unchanged.', { equal = true }),
      list(
        'ignore-type',
        'TYPE',
        'Leave out records of this type, like GMST or Light. Can be repeated.',
        'ignoreTypes'
      ),
    }, Encoding),
    positionals = pair('The plugin to compare from, by its path.', 'The plugin to compare to.'),
  },
  {
    name = 'common',
    about = 'The records two plugins both have, by type and id.',
    flags = Encoding,
    positionals = pair('The first plugin, by its path.', 'The second plugin.'),
  },
  {
    name = 'compare',
    aliases = { 'comp' },
    about = 'Whether two files are byte-for-byte identical. Exits 1 when they differ.',
    flags = {},
    positionals = pair('The first file: its path.', 'The second file.'),
  },
  {
    name = 'overdial',
    about = 'Dialogue topics that contain other topics, and so can hide them.',
    flags = join({
      switch(
        'single',
        'Only check the first plugin\'s topics: report those that contain a topic from a later plugin, not topics of later plugins that contain each other or the first plugin\'s.',
        { single = true }
      ),
    }, Encoding),
    positionals = {
      { name = 'INPUT', field = 'paths', many = true, help = 'Two or more plugins, by path.' },
    },
    check = function(request): string?
      local paths = request.paths :: { string }?
      if not paths or #paths < 2 then return 'overdial requires at least two plugins' end

      return nil
    end,
  },
  {
    name = 'lint',
    about = 'Report content problems: dirt, likely mistakes, and missing dependencies. Exits 1 on errors (see --fail-on).',
    flags = join(
      {
        adds('all', 'Run every check.', 'presets', 'all'),
        adds(
          'recommended',
          'Run the recommended checks: junk cells, fog bugs, a missing version line, dependency mistakes, deprecated leveled list edits, dialogue teleports, and duplicated dialogue text. The default when no checks are named.',
          'presets',
          'recommended'
        ),
      },
      LintChecks,
      {
        value(
          'fail-on',
          'FAIL_ON',
          'The least severe finding that makes lint exit 1: error (the default: a missing master or expansion), warning (also dirt and likely mistakes), any, or never.',
          'failOn',
          { choices = { 'error', 'warning', 'any', 'never' } }
        ),
      },
      Encoding
    ),
    positionals = input 'The plugin to check, by its path.',
  },
  {
    name = 'validate',
    about = 'Check the file\'s format against a profile: what Morrowind.exe or OpenMW can\'t load. Exits 1 when it doesn\'t fit.',
    flags = join({
      value(
        'profile',
        'PROFILE',
        'The profile to check against. Every profile checks the file\'s structure; tes3 adds what Morrowind.exe doesn\'t know, omwaddon what OpenMW refuses or skips, and omwsave an OpenMW save\'s header, format, and cell state. By default, omwaddon.',
        'profile',
        { choices = { 'raw', 'tes3', 'omwaddon', 'omwsave' } }
      ),
    }, Encoding),
    positionals = input 'The file to check: its path.',
  },
  {
    name = 'clean',
    about = 'Remove safe dirt: evil GMSTs, duplicate and identical-to-master records, junk cells, and repeated cell settings. With none named, all of them.',
    flags = join(
      {
        adds(
          'evil-gmsts',
          'Remove Evil GMSTs: Tribunal and Bloodmoon GMSTs the Construction Set leaks into plugins, still at the expansion\'s value.',
          'kinds',
          'evilGmsts',
          { aliases = { 'gmsts' } }
        ),
        adds(
          'duplicate-records',
          'Remove later duplicate records with the same type and ID, and records identical to their master\'s copy.',
          'kinds',
          'duplicateRecords',
          { aliases = { 'dups' } }
        ),
        adds(
          'cell-params',
          'Remove duplicate CELL header params before references.',
          'kinds',
          'cellParams'
        ),
        adds(
          'junk-cells',
          'Remove junk cells: CELL records with nothing but a name and grid data.',
          'kinds',
          'junkCells'
        ),
      },
      output 'Write the cleaned plugin here instead of over the input.',
      Write,
      Encoding
    ),
    positionals = input 'The plugin to clean, by its path.',
    check = function(request): string? return sameOutput('clean', request) end,
  },
  {
    name = 'delete',
    about = 'Delete the records a selector picks, or with subrecord or reference filters, the matching parts of them.',
    flags = join(
      Selectors,
      output 'Write the edited plugin here instead of over the input.',
      Write,
      Encoding
    ),
    positionals = input 'The plugin to edit, by its path.',
    check = function(request): string?
      if not request.selectors then
        return 'delete needs at least one selector (--type, --id, --exact-id, --flag, --match, ...); without one it would delete every record'
      end

      return sameOutput('delete', request)
    end,
  },
  {
    name = 'modify',
    about = 'Change text in the records a selector picks with a regex replace.',
    flags = join(
      Selectors,
      {
        value(
          'replace',
          '/PATTERN/REPLACEMENT/',
          'Replace every match of a case-insensitive regex in the selected records\' text fields (names, models, script text, ...), written /pattern/replacement/.',
          'replace'
        ),
        value(
          'replace-first',
          '/PATTERN/REPLACEMENT/',
          'Like --replace, but only the first match in each field.',
          'replaceFirst',
          { aliases = { 'replacefirst' } }
        ),
        value(
          'script',
          'SCRIPT',
          'Refused: it ran a Luau script on the plugin, and today\'s Jess gives a package no way to load and run a script file handed to it. Write the edit as a Luau script over @tes3 and @tes3cmd, and run that with jess run --package.',
          'script'
        ),
      },
      output 'Write the edited plugin here instead of over the input.',
      Write,
      Encoding
    ),
    positionals = input 'The plugin to edit, by its path.',
    check = function(request, used): string?
      if used.script then
        return NoScript
      end

      if used.replace and used['replace-first'] then
        return 'the argument \'--replace </PATTERN/REPLACEMENT/>\' cannot be used with \'--replace-first </PATTERN/REPLACEMENT/>\''
      end

      if not used.replace and not used['replace-first'] then
        return 'modify needs --replace or --replace-first'
      end

      local selectors = request.selectors :: { [string]: unknown }?
      if selectors and (selectors.instance or selectors.notInstance) then
        return 'modify does not support --instance-match or --instance-no-match yet'
      end

      -- One request field holds the expression; whether every match goes is beside it.
      if used['replace-first'] then
        request.replace = request.replaceFirst
        request.first = true
        request.replaceFirst = nil
      end

      return sameOutput('modify', request)
    end,
  },
  {
    name = 'esm',
    about = 'Convert a plugin (.esp) to a master (.esm).',
    flags = ConvertFlags,
    positionals = input 'The file to convert, by its path.',
    check = sameConverted,
  },
  {
    name = 'esp',
    about = 'Convert a master (.esm) to a plugin (.esp).',
    flags = ConvertFlags,
    positionals = input 'The file to convert, by its path.',
    check = sameConverted,
  },
  {
    name = 'test-codec',
    command = 'testCodec',
    about = 'Check that files read and write back byte for byte. Exits 1 when one doesn\'t, saying where it first differs.',
    flags = {
      switch('continue', 'Keep checking later files after one fails.', { keepGoing = true }),
      switch(
        'ignore-cruft',
        'Ignore bytes before and after the plugin data.',
        { ignoreCruft = true }
      ),
      list(
        'exclude-type',
        'TYPE',
        'Leave records of this type out of the check. Can be repeated.',
        'excludeTypes',
        { short = 'x' }
      ),
    },
    positionals = {
      { name = 'INPUT', field = 'paths', many = true, help = 'Files to check, by path.' },
    },
    check = function(request): string?
      local paths = request.paths :: { string }?
      if not paths or #paths == 0 then return 'test-codec requires at least one plugin' end

      return nil
    end,
  },
}

--- The commands under the headings help lists them by, in order.
local Groups: { { heading: string, names: { string } } } = {
  {
    heading = 'Inspect',
    names = { 'dump', 'stats', 'header', 'diff', 'common', 'compare', 'overdial' },
  },
  { heading = 'Check', names = { 'lint', 'validate' } },
  { heading = 'Edit', names = { 'clean', 'delete', 'modify', 'esm', 'esp' } },
  { heading = 'Development', names = { 'test-codec' } },
}

--- Commands `jess plugin` had that are another package's now, and what to run instead.
local Moved: { [string]: string } = {
  assets = 'assets isn\'t tes3cmd\'s: the asset report is its own command, plugin-assets <plugins>...',
}

local ByName: { [string]: Spec } = {}
for _, spec in Specs do
  ByName[spec.name] = spec
  for _, alias in spec.aliases or {} do
    ByName[alias] = spec
  end
end

--[[ Reading ]]

--- A flag as messages name it: `--type <TYPES>`.
local function shown(flag: Flag): string
  return if flag.value then `--{flag.long} <{flag.value}>` else `--{flag.long}`
end

--- Sets `field` of `request`: a name, or `table.name` for a field of the table at `table`.
local function assign(request: { [string]: unknown }, field: string, given: unknown, add: boolean?)
  local outer, inner = string.match(field, '^([^.]+)%.(.+)$')
  local target, key = request, field
  if outer and inner then
    local nested = request[outer] :: { [string]: unknown }?
    if not nested then
      nested = {}
      request[outer] = nested
    end

    target, key = nested :: { [string]: unknown }, inner
  end

  if not add then
    target[key] = given
    return
  end

  local items = target[key] :: { unknown }?
  if not items then
    items = {}
    target[key] = items
  end

  table.insert(items :: { unknown }, given)
end

--- The flags a command takes, by `--name` and `-n`, with the ones every command does.
local function lookup(flags: { Flag }): { [string]: Flag }
  local found: { [string]: Flag } = {}
  for _, flag in join(flags, { FormatFlag, HelpFlag, VersionFlag }) do
    found[`--{flag.long}`] = flag
    if flag.short then found[`-{flag.short}`] = flag end

    for _, alias in flag.aliases or {} do
      found[`--{alias}`] = flag
    end
  end

  return found
end

local Global = lookup {}

--- An argument as a flag's name and the value attached to it, or nil when it isn't a flag:
--- `--name`, `--name=value`, `-n`, `-nvalue`, `-n=value`.
local function flagOf(argument: string): (string?, string?)
  if string.sub(argument, 1, 2) == '--' then
    local name, attached = string.match(argument, '^(%-%-[^=]+)=(.*)$')
    if name then return name, attached end

    return argument, nil
  end

  if string.sub(argument, 1, 1) ~= '-' or #argument < 2 then return nil, nil end

  local name = string.sub(argument, 1, 2)
  if #argument == 2 then return name, nil end

  local rest = string.sub(argument, 3)
  return name, if string.sub(rest, 1, 1) == '=' then string.sub(rest, 2) else rest
end

local function parse(argv: { string }): (Command?, string?)
  local request: { [string]: unknown } = {}
  local positional: { string } = {}
  local used: { [string]: boolean } = {}
  local spec: Spec? = nil
  local flags = Global
  local format: Format? = nil
  local help, version, literal = false, false, false
  local index = 1
  while index <= #argv do
    local argument = argv[index]
    index += 1
    local name, attached = flagOf(argument)
    if literal or not name then
      if spec then
        table.insert(positional, argument)
        continue
      end

      if Moved[argument] then return nil, Moved[argument] end

      -- `help` is a command too: `tes3cmd help dump`.
      if argument == 'help' then
        help = true
        continue
      end

      local named = ByName[argument]
      if not named then return nil, `unrecognized command '{argument}'` end

      spec = named
      flags = lookup(named.flags)
      continue
    end

    if argument == '--' then
      literal = true
      continue
    end

    local flag = flags[name]
    if not flag then return nil, `unexpected argument '{name}' found` end

    if not flag.value then
      if attached then
        return nil, `unexpected value '{attached}' for '--{flag.long}' found; no more were expected`
      end

      if used[flag.long] then
        return nil, `the argument '{shown(flag)}' cannot be used multiple times`
      end
    end

    if flag == HelpFlag then
      help = true
      continue
    end

    if flag == VersionFlag then
      version = true
      continue
    end

    local given: string? = attached
    if flag.value and not given then
      given = argv[index]
      index += 1
      if not given then
        return nil, `a value is required for '{shown(flag)}' but none was supplied`
      end
    end

    if given and flag.choices and not table.find(flag.choices, given) then
      return nil,
        `invalid value '{given}' for '{shown(flag)}': possible values: {table.concat(flag.choices, ', ')}`
    end

    if flag.value and not flag.many and used[flag.long] then
      return nil, `the argument '{shown(flag)}' cannot be used multiple times`
    end

    used[flag.long] = true
    if flag == FormatFlag then
      format = given :: Format
      continue
    end

    for field, constant in flag.set or {} do
      assign(request, field, constant)
    end

    if flag.field then assign(request, flag.field, flag.item or given, flag.many or flag.item ~= nil) end
  end

  if help then return { command = 'help', topic = spec and spec.name }, nil end

  if version then return { command = 'version' }, nil end

  if not spec then return nil, 'a command is required: tes3cmd --help lists them' end

  for _, wanted in spec.positionals do
    if wanted.many then
      if #positional < (wanted.least or 0) then
        return nil, `the following required arguments were not provided: <{wanted.name}>...`
      end

      request[wanted.field] = positional
      positional = {}
      continue
    end

    local given = table.remove(positional, 1)
    if not given then
      return nil, `the following required arguments were not provided: <{wanted.name}>`
    end

    request[wanted.field] = given
  end

  if #positional > 0 then return nil, `unexpected argument '{positional[1]}' found` end

  local problem = if spec.check then spec.check(request, used) else nil
  if problem then return nil, problem end

  return {
    command = spec.command or spec.name,
    format = format,
    request = (request :: unknown) :: Request,
  },
    nil
end

--[[ Help ]]

local Width = 100

--- `text` in lines of at most `Width` columns, each after `indent` spaces.
local function wrap(text: string, indent: number): string
  local pad = string.rep(' ', indent)
  local lines = {}
  local line = ''
  for word in string.gmatch(text, '%S+') do
    if line ~= '' and indent + #line + 1 + #word > Width then
      table.insert(lines, pad .. line)
      line = word
    elseif line == '' then
      line = word
    else
      line ..= ' ' .. word
    end
  end

  if line ~= '' then table.insert(lines, pad .. line) end

  return table.concat(lines, '\n')
end

local function flagHelp(flag: Flag, lines: { string })
  local short = if flag.short then `-{flag.short}, ` else '    '
  table.insert(lines, `  {short}{shown(flag)}`)
  local help = flag.help
  if flag.choices then help ..= ` [possible values: {table.concat(flag.choices, ', ')}]` end

  local spellings = [for alias in flag.aliases or {} => `--{alias}`]
  if #spellings > 0 then help ..= ` [also: {table.concat(spellings, ', ')}]` end

  table.insert(lines, wrap(help, 10))
  table.insert(lines, '')
end

local ExitStatus =
  'Exit status: 0 done; 1 where a command\'s help says "Exits 1 when ..."; 8 the command line can\'t be used; 9 the command failed.'

--- Help for `tes3cmd`, or for the command named `topic`.
local function usage(topic: string?): string
  local spec = if topic then ByName[topic] else nil
  local lines = {}
  if not spec then
    table.insert(lines, 'Inspect, check, and modify plugin files.')
    table.insert(lines, '')
    table.insert(lines, 'Usage: tes3cmd [OPTIONS] <COMMAND>')
    for _, group in Groups do
      table.insert(lines, '')
      table.insert(lines, `{group.heading}:`)
      for _, name in group.names do
        local about = wrap(ByName[name].about, 14)
        table.insert(lines, `  {name}{string.rep(' ', 12 - #name)}{string.sub(about, 15)}`)
      end
    end

    table.insert(lines, '')
    table.insert(lines, 'Options:')
    for _, flag in { FormatFlag, HelpFlag, VersionFlag } do
      flagHelp(flag, lines)
    end

    table.insert(lines, wrap('tes3cmd <COMMAND> --help says what a command takes. A plugin is named by its path.', 0))
    table.insert(lines, '')
    table.insert(lines, wrap(`Moved: {Moved.assets}`, 0))
    table.insert(lines, '')
    table.insert(lines, wrap(`Not here: modify {NoScript}`, 0))
    table.insert(lines, '')
    table.insert(lines, wrap(WhichCheck, 0))
    table.insert(lines, '')
    table.insert(lines, wrap(ExitStatus, 0))
    return table.concat(lines, '\n')
  end

  table.insert(lines, wrap(spec.about, 0))
  table.insert(lines, '')
  local arguments = [
    for wanted in spec.positionals
    => if wanted.many then `<{wanted.name}>...` else `<{wanted.name}>`
  ]

  table.insert(lines, `Usage: tes3cmd {spec.name} [OPTIONS] {table.concat(arguments, ' ')}`)
  table.insert(lines, '')
  table.insert(lines, 'Arguments:')
  for position, wanted in spec.positionals do
    table.insert(lines, `  {arguments[position]}`)
    table.insert(lines, wrap(wanted.help, 10))
    table.insert(lines, '')
  end

  table.insert(lines, 'Options:')
  for _, flag in join(spec.flags, { FormatFlag, HelpFlag, VersionFlag }) do
    flagHelp(flag, lines)
  end

  if spec.name == 'lint' or spec.name == 'validate' then
    table.insert(lines, wrap(WhichCheck, 0))
    table.insert(lines, '')
  end

  table.insert(lines, wrap(ExitStatus, 0))
  return table.concat(lines, '\n')
end

return table.freeze { parse = parse, usage = usage }
