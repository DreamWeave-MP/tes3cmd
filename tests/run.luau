--!strict
--!native
-- tes3cmd's own cases: what jess's CLI plugin tests (`libs/cli/tests/plugin.rs`) and
-- jess-omwaddon's lint, edit, and compare tests check, on plugins built here, so the suite needs
-- nothing but the package.
local fixtures = require './fixtures'
local tes3 = require '@tes3'
local tes3cmd = require '@tes3cmd'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local record, subrecord, u32 = fixtures.record, fixtures.subrecord, fixtures.u32

local function open(bytes: string, options: tes3.OpenOptions?): tes3.Plugin
  return tes3.open(bytes, options)
end

local function saved(plugin: tes3.Plugin): string return buffer.tostring(plugin:save()) end

local function contains(haystack: string, needle: string): boolean
  return string.find(haystack, needle, 1, true) ~= nil
end

local function hasFinding(findings: { tes3cmd.Finding }, check: string, message: string): boolean
  for _, finding in findings do
    if finding.check == check and contains(finding.message, message) then return true end
  end

  return false
end

local function lint(
  bytes: string,
  checks: { string }?,
  masters: tes3cmd.MasterSource?
): { tes3cmd.Finding }
  return tes3cmd.lint(open(bytes), if checks then tes3cmd.checkSet(checks) else nil, masters)
end

local function lintAll(bytes: string, masters: tes3cmd.MasterSource?): { tes3cmd.Finding }
  return tes3cmd.lint(open(bytes), tes3cmd.preset 'all', masters)
end

suite.describe('lint', function()
  suite.it('reports the early clean issues', function()
    local findings = lintAll(fixtures.dirty())
    expect(hasFinding(findings, 'duplicateRecords', 'STAT dup_static')).toBe(true)
    expect(hasFinding(findings, 'evilGmsts', 'GMST fWerewolfHealth')).toBe(true)
    expect(hasFinding(findings, 'cellParams', 'duplicate WHGT')).toBe(true)
    expect(hasFinding(findings, 'junkCells', 'CELL junk_cell')).toBe(true)
    expect(hasFinding(findings, 'recordCount', 'HEDR has 999, actual is 5')).toBe(true)
  end)

  suite.it('runs the recommended checks unless told otherwise', function()
    local recommended = lint(fixtures.dirty())
    expect(hasFinding(recommended, 'junkCells', 'CELL junk_cell')).toBe(true)
    expect(hasFinding(recommended, 'evilGmsts', '')).toBe(false)
    expect(tes3cmd.checkSet()['fogbug']).toBe(true)
    expect(tes3cmd.checkSet()['evil-gmsts']).toBeNil()

    local named = lint(fixtures.dirty(), { 'evilGmsts' })
    expect(hasFinding(named, 'evilGmsts', 'GMST fWerewolfHealth')).toBe(true)
    expect(hasFinding(named, 'junkCells', '')).toBe(false)
    expect(#tes3cmd.checks).toBe(27)
  end)

  suite.it('takes every spelling of a check, and refuses unknown ones', function()
    expect(tes3cmd.parseCheck 'evil-gmsts').toBe 'evil-gmsts'
    expect(tes3cmd.parseCheck 'evil_gmsts').toBe 'evil-gmsts'
    expect(tes3cmd.parseCheck 'evilGmsts').toBe 'evil-gmsts'
    expect(tes3cmd.parseCheck 'cell00').toBe 'cell-00'
    expect(function() tes3cmd.parseCheck 'nope' end).toThrow 'unknown lint check \'nope\''
    expect(function() tes3cmd.preset 'some' end).toThrow 'unknown preset \'some\''
  end)

  suite.it('reports script and dialogue checks', function()
    local findings = lint(
      fixtures.scripts(),
      { 'getsoundplaying', 'menumode', 'dialogue-teleports', 'scripted-doors' }
    )
    for _, check in { 'getsoundplaying', 'menumode', 'dialogueTeleports', 'scriptedDoors' } do
      expect(hasFinding(findings, check, '')).toBe(true)
    end
  end)

  suite.it('takes INFO ids from INAM', function()
    local plugin = open(fixtures.infoIds())
    local selector = tes3cmd.selector { exactId = '222' }
    local picked = tes3cmd.select.picked(selector, plugin)
    expect(#picked).toBe(1)
    expect(picked[1].index).toBe(2)
    expect(tes3cmd.select.ids(selector, plugin)).toEqual { '222' }
    local findings = lint(fixtures.infoIds(), { 'modified-info-id' })
    expect(hasFinding(findings, 'modifiedInfoId', 'INFO 222 at record 2 duplicates text from 111')).toBe(
      true
    )
  end)

  suite.it('reports the version and fog checks', function()
    local findings = lint(fixtures.fogbug(), { 'missing-version', 'fogbug' })
    expect(hasFinding(findings, 'missingVersion', '')).toBe(true)
    expect(hasFinding(findings, 'fogbug', 'CELL foggy_cell')).toBe(true)
    expect(tes3cmd.hasVersion 'A mod\n  Version 1.0').toBe(true)
    expect(tes3cmd.hasVersion 'A mod, v1').toBe(false)
  end)

  suite.it('reports fogsync, with tiny floats in scientific notation', function()
    local findings = lint(fixtures.fogsync(fixtures.f32(0.25), 'fogsync_cell'), { 'fogsync' })
    expect(hasFinding(findings, 'fogsync', 'CELL fogsync_cell')).toBe(true)
    expect(findings[1].message).toContain 'DATA fog 0.25 differs from AMBI fog 0.5'
    local tiny = lint(fixtures.fogsync(string.pack('<I4', 0x00223344), 'tiny_fog'), { 'fogsync' })
    expect(tiny[1].message).toContain 'DATA fog 3.140798e-39 differs from AMBI fog 0.5'
  end)

  suite.it('compares with masters for overrides and duplicates', function()
    local duplicate = record('STAT', subrecord('NAME', 'master_static'))
    local master = fixtures.plugin { duplicate }
    local dependent = fixtures.plugin({ duplicate }, { { name = 'Master.esm', size = 1 } })
    local masters = tes3cmd.masters.memory { ['Master.esm'] = master }
    expect(hasFinding(lint(dependent, { 'overrides' }, masters), 'overrides', 'STAT master_static')).toBe(
      true
    )

    local plugin = open(dependent)
    local report = tes3cmd.clean(plugin, { duplicateRecords = true }, masters)
    expect(report.removedRecords).toBe(1)
    expect(contains(saved(plugin), 'master_static')).toBe(false)

    local missing = lint(dependent, { 'missing-master' }, tes3cmd.masters.none())
    expect(hasFinding(missing, 'missingMaster', 'Master.esm')).toBe(true)
  end)
end)

suite.describe('clean', function()
  suite.it('runs every cleanup unless told otherwise', function()
    local plugin = open(fixtures.dirty())
    local report = tes3cmd.clean(plugin)
    expect(report.removedRecords).toBe(3)
    expect(report.removedSubrecords).toBe(1)
    expect(report.recordCountUpdated).toBe(true)
    expect(report.removedRecordIndices).toEqual { 2, 3, 5 }

    local evil = open(fixtures.dirty())
    expect(tes3cmd.clean(evil, { evilGmsts = true }).removedRecords).toBe(1)
    local allBut = open(fixtures.dirty())
    expect(tes3cmd.clean(allBut, { evilGmsts = false }).removedRecords).toBe(2)
  end)

  suite.it('removes safe dirt, leaving nothing for lint', function()
    local plugin = open(fixtures.dirty())
    tes3cmd.clean(
      plugin,
      { duplicateRecords = true, evilGmsts = true, cellParams = true, junkCells = true }
    )
    local bytes = saved(plugin)
    expect(contains(bytes, 'dup_static')).toBe(true)
    expect(contains(bytes, 'fWerewolfHealth')).toBe(false)
    expect(contains(bytes, 'junk_cell')).toBe(false)
    expect(contains(bytes, 'kept_ref')).toBe(true)
    local again = lint(
      bytes,
      { 'duplicate-records', 'evil-gmsts', 'cell-params', 'junk-cells', 'record-count' }
    )
    expect(again).toEqual {}
  end)
end)

suite.describe('header', function()
  suite.it('updates the record count', function()
    local plugin = open(fixtures.dirty())
    expect(plugin:header().recordCount).toBe(999)
    local changed = tes3cmd.updateHeader(plugin, { recordCount = true })
    expect(changed).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(5)
    expect((tes3cmd.updateHeader(plugin, { recordCount = true }))).toBe(false)
  end)

  suite.it('sets the author and appends to the description', function()
    local plugin = open(fixtures.cell())
    tes3cmd.updateHeader(plugin, { author = 'tester', description = 'first' })
    tes3cmd.updateHeader(plugin, { description = '+\\nsecond' })
    local header = open(saved(plugin)):header()
    expect(header.author).toBe 'tester'
    expect(header.description).toBe 'first\nsecond'
  end)

  suite.it('syncs master sizes', function()
    local dependent = fixtures.plugin({}, { { name = 'Master.esm', size = 1 } })
    local master = fixtures.plugin {}
    local plugin = open(dependent)
    local masters = tes3cmd.masters.memory { ['master.esm'] = master }
    local changed, synced = tes3cmd.updateHeader(plugin, { syncMasters = true }, masters)
    expect(changed).toBe(true)
    expect(synced).toEqual {
      { name = 'Master.esm', oldSize = 1, newSize = #master, path = 'master.esm' },
    }
    expect(open(saved(plugin)):masters()[1].size).toBe(#master)
    expect(function() tes3cmd.syncMasters(open(dependent), tes3cmd.masters.none()) end).toThrow 'failed to resolve TES3 master \'Master.esm\''
  end)
end)

suite.describe('delete', function()
  suite.it('removes the selected records and updates the count', function()
    local plugin = open(fixtures.dirty())
    local deleted = tes3cmd.delete(plugin, tes3cmd.selector { type = 'STAT' })
    expect(deleted.records).toBe(2)
    expect(deleted.recordIndices).toEqual { 1, 2 }
    expect(deleted.recordCountUpdated).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(3)
  end)

  suite.it('removes a cell instance and only it', function()
    local plugin = open(fixtures.cell())
    local deleted = tes3cmd.delete(plugin, tes3cmd.selector { instance = 'first_ref' })
    expect(deleted.references).toBe(1)
    local bytes = saved(plugin)
    expect(contains(bytes, 'first_ref')).toBe(false)
    expect(contains(bytes, 'second_ref')).toBe(true)
  end)

  suite.it('removes subrecords by match', function()
    local plugin = open(fixtures.dirty())
    local deleted = tes3cmd.delete(plugin, tes3cmd.selector { type = 'STAT', sub = '^mesh:' })
    expect(deleted.subrecords).toBe(2)
    expect(contains(saved(plugin), 'a.nif')).toBe(false)
  end)
end)

suite.describe('modify', function()
  suite.it('replaces typed string fields', function()
    local plugin = open(fixtures.plugin { fixtures.stat('marker', 'marker.nif') })
    local report = tes3cmd.replace(
      plugin,
      tes3cmd.selector { type = 'STAT', sub = 'id:' },
      tes3cmd.parseReplacement('/^/PC_/', true)
    )
    expect(report.fields).toBe(1)
    expect(report.records).toBe(1)
    local bytes = saved(plugin)
    expect(contains(bytes, 'PC_marker')).toBe(true)
    expect(contains(bytes, 'marker.nif')).toBe(true)
    expect(contains(bytes, 'PC_marker.nif')).toBe(false)
  end)

  suite.it('replaces the first match, and a miss changes nothing', function()
    local plugin = open(fixtures.plugin { fixtures.stat 'foo foo' })
    expect(
      tes3cmd.replace(plugin, tes3cmd.selector(), tes3cmd.parseReplacement('/foo/bar/', false)).fields
    ).toBe(1)
    expect(contains(saved(plugin), 'bar foo')).toBe(true)
    expect(
      tes3cmd.replace(plugin, tes3cmd.selector(), tes3cmd.parseReplacement('/nothing/x/', true)).fields
    ).toBe(0)
  end)

  suite.it('names the character the encoding can\'t hold', function()
    local bytes = fixtures.plugin {
      record('STAT', subrecord('NAME', 'marker\0') .. subrecord('MODL', 'x.nif\0')),
    }
    local selector = tes3cmd.selector { type = 'STAT' }
    expect(
      function()
        tes3cmd.replace(
          open(bytes),
          selector,
          tes3cmd.parseReplacement('/marker/маркер/', true)
        )
      end
    ).toThrow 'STAT \'marker\' NAME: \'м\' (U+043C) can\'t be written in Windows-1252'
    local plugin = open(bytes, { encoding = 'win1251' })
    expect(
      tes3cmd.replace(plugin, selector, tes3cmd.parseReplacement('/marker/маркер/', true)).fields
    ).toBe(1)
  end)

  suite.it('keeps cell references when renaming a cell or its region', function()
    local plugin = open(fixtures.cell())
    tes3cmd.replace(
      plugin,
      tes3cmd.selector { type = 'CELL', sub = 'id:' },
      tes3cmd.parseReplacement('/synthetic/edited/', true)
    )
    local bytes = saved(plugin)
    for _, text in { 'edited_cell', 'first_ref', 'second_ref', 'NAM0' } do
      expect(contains(bytes, text)).toBe(true)
    end

    local region = open(fixtures.namedCell())
    tes3cmd.replace(
      region,
      tes3cmd.selector { type = 'CELL', sub = 'region:' },
      tes3cmd.parseReplacement('/Old/New/', true)
    )
    local edited = saved(region)
    expect(contains(edited, 'New Region')).toBe(true)
    expect(contains(edited, 'Old Cell')).toBe(true)
    expect(contains(edited, 'chair')).toBe(true)
  end)

  suite.it('refuses an expression that is not /pattern/replacement/', function()
    expect(function() tes3cmd.parseReplacement('foo', true) end).toThrow 'invalid replacement expression \'foo\''
  end)
end)

suite.describe('dump and select', function()
  suite.it('filters by type, flags, ids, and raw bytes', function()
    local plugin = open(fixtures.dirty())
    local function ids(spec: tes3cmd.SelectorSpec): { string }
      return tes3cmd.select.ids(tes3cmd.selector(spec), plugin)
    end

    expect(ids { type = 'stat' }).toEqual { 'dup_static', 'dup_static' }
    expect(ids { match = 'b%.nif' }).toEqual {}
    expect(ids { match = 'b\\.nif' }).toEqual { 'dup_static' }
    expect(ids { type = 'Cell', id = 'junk' }).toEqual { 'junk_cell' }
    expect(ids { exactId = 'JUNK_CELL' }).toEqual { 'junk_cell' }
    expect(ids { flags = 'persistent' }).toEqual {}
    expect(function() tes3cmd.selector { type = 'nonsense' } end).toThrow 'invalid record type \'nonsense\''
    expect(function() tes3cmd.selector { flags = 'shiny' } end).toThrow 'invalid record flag \'shiny\''
    expect(function() (tes3cmd.selector :: any) { nope = true } end).toThrow 'unknown selector option \'nope\''
  end)

  suite.it('keeps only the matching instances of a typed cell', function()
    local function reference(index: number, id: string): string
      return subrecord('FRMR', u32(index))
        .. subrecord('NAME', id)
        .. subrecord('DATA', string.rep('\0', 24))
    end

    local cell = record(
      'CELL',
      subrecord('NAME', 'typed_cell')
        .. subrecord('DATA', u32(1) .. u32(0) .. u32(0))
        .. fixtures.nam0(2)
        .. reference(1, 'first_ref')
        .. reference(2, 'second_ref')
    )
    local plugin = open(fixtures.plugin { cell })
    local dumped = tes3cmd.dump(plugin, tes3cmd.selector { instance = 'second' })
    expect(#dumped).toBe(1)
    local references = dumped[1].references :: { { [string]: unknown } }
    expect(#references).toBe(1)
    expect(references[1].id).toBe 'second_ref'
  end)

  suite.it('extracts the selected records, with the header updated', function()
    local plugin = open(fixtures.dirty())
    local extracted =
      open(buffer.tostring(tes3cmd.extract(plugin, tes3cmd.selector { type = 'STAT' }, true)))
    expect(extracted:count()).toBe(3)
    expect(extracted:header().recordCount).toBe(2)
    expect(extracted:tag(0)).toBe 'TES3'
    local bare =
      open(buffer.tostring(tes3cmd.extract(plugin, tes3cmd.selector { type = 'STAT' }, false)))
    expect(bare:count()).toBe(2)
  end)

  suite.it('lays out records and subrecords', function()
    local plugin = open(fixtures.dirty())
    local layout =
      tes3cmd.layout(plugin, 1, tes3cmd.selector(), { subrecords = true, fields = true })
    expect(layout.type).toBe 'STAT'
    expect(layout.id).toBe 'dup_static'
    local subs = layout.subrecords :: { tes3cmd.SubrecordLayout }
    expect(subs[1].field).toBe 'id'
    expect(subs[2].field).toBe 'mesh'
    expect(subs[2].value).toBe 'a.nif'
  end)

  suite.it('lays out the references an instance filter picks, and only a cell has any', function()
    local plugin = open(fixtures.cell())
    local selector = tes3cmd.selector { instance = 'second_ref' }
    expect(tes3cmd.references(plugin, 1, selector, true)).toEqual {
      {
        index = 1,
        subrecords = {
          { index = 6, type = 'FRMR', size = 4, range = { start = 447, ['end'] = 459 } },
          {
            index = 7,
            type = 'NAME',
            size = 10,
            range = { start = 459, ['end'] = 477 },
            field = 'id',
            value = 'second_ref',
          },
          { index = 8, type = 'DATA', size = 24, range = { start = 477, ['end'] = 509 } },
        },
      },
    }

    local bare = tes3cmd.references(plugin, 1, selector)
    expect(bare[1].subrecords[2].field).toBeNil()
    expect(#tes3cmd.references(plugin, 1, tes3cmd.selector())).toBe(2)
    expect(tes3cmd.references(plugin, 0, selector)).toEqual {}
  end)

  suite.it('counts records and subrecords, and list subrecords', function()
    local stats = tes3cmd.stats.new()
    tes3cmd.stats.add(stats, open(fixtures.dirty()))
    tes3cmd.stats.add(stats, open(fixtures.cell()))
    expect(stats.plugins).toBe(2)
    expect(stats.records).toBe(8)
    expect(stats.recordTypes.CELL).toBe(3)
    expect(stats.subrecordTypes['CELL.NAME']).toBe(6)
    expect(stats.listSubrecords['CELL.NAME']).toBe(2)
  end)
end)

suite.describe('compare', function()
  suite.it('compares bytes', function()
    local left, right = buffer.fromstring 'abcdefghij', buffer.fromstring 'abcdefghiX'
    expect(tes3cmd.compare.compareBytes(left, left).identical).toBe(true)
    expect(tes3cmd.compare.compareBytes(left, right).firstDifference).toBe(9)
    expect(tes3cmd.compare.compareBytes(left, buffer.fromstring 'abc').firstDifference).toBe(3)
  end)

  suite.it('finds records in common, without the header', function()
    local plugin = open(fixtures.dirty())
    local common = tes3cmd.compare.common(plugin, plugin)
    expect(common[1]).toEqual { type = 'CELL', id = 'dirty_cell' }
    for _, key in common do
      expect(key.type ~= 'TES3').toBe(true)
    end
  end)

  suite.it('diffs records by id, with field changes', function()
    local left = open(fixtures.plugin { fixtures.stat('marker', 'a.nif'), fixtures.stat 'gone' })
    local right = open(fixtures.plugin { fixtures.stat('marker', 'b.nif'), fixtures.stat 'new' })
    local diff = tes3cmd.compare.diff(left, right)
    expect(diff.leftOnly).toEqual { { type = 'STAT', id = 'gone' } }
    expect(diff.rightOnly).toEqual { { type = 'STAT', id = 'new' } }
    expect(diff.changed[1].rawChanged).toBe(true)
    expect(diff.changed[1].fields).toEqual { { field = 'mesh[1]', left = 'a.nif', right = 'b.nif' } }
    expect(tes3cmd.compare.diff(left, right, { 'STAT' }).changed).toEqual {}
    expect(tes3cmd.compare.diff(left, left, nil, true).equal).toEqual {
      { type = 'STAT', id = 'gone' },
      { type = 'STAT', id = 'marker' },
    }
  end)

  suite.it('finds the first record two plugins don\'t share byte for byte', function()
    local left = open(fixtures.plugin { fixtures.stat('marker', 'a.nif'), fixtures.stat 'gone' })
    local right = open(fixtures.plugin { fixtures.stat('marker', 'b.nif'), fixtures.stat 'gone' })
    expect(tes3cmd.compare.firstDifference(left, left)).toBeNil()
    expect(tes3cmd.compare.firstDifference(left, right)).toEqual {
      index = 1,
      type = 'STAT',
      id = 'marker',
      offset = 362,
    }
    expect(tes3cmd.compare.firstDifference(left, right, { 'Static' })).toBeNil()

    -- A plugin that has run out: the other's next record, at the end of this one's bytes.
    local short = open(fixtures.plugin { fixtures.stat 'one' })
    local long = open(fixtures.plugin { fixtures.stat 'one', fixtures.stat 'two' })
    expect(tes3cmd.compare.firstDifference(short, long).index).toBe(0)
    expect(tes3cmd.compare.firstDifference(short, long, { 'TES3' })).toEqual {
      index = 2,
      type = 'STAT',
      id = 'two',
      offset = 351,
    }

    expect(tes3cmd.compare.firstDifference(long, short, { 'TES3' })).toEqual {
      index = 2,
      type = 'STAT',
      id = 'two',
      offset = 351,
    }
  end)

  suite.it('finds the records a load order overrides, comparing them where they are', function()
    local function order(...: { string }): { tes3.Plugin }
      local plugins = {}
      for _, records in { ... } do
        table.insert(plugins, open(fixtures.plugin(records)))
      end

      return plugins
    end

    local first, second, third =
      fixtures.stat('rock', 'a.nif'), fixtures.stat('rock', 'b.nif'), fixtures.stat('rock', 'c.nif')

    -- A copy unchanged from an earlier plugin's, and a change a later copy throws away.
    expect(tes3cmd.compare.overrides(order({ first }, { first }, { second }))).toEqual {
      {
        type = 'STAT',
        id = 'rock',
        plugins = { 1, 2, 3 },
        identical = { { plugin = 2, sameAs = 1 } },
        overridden = {},
      },
    }

    expect(tes3cmd.compare.overrides(order({ first }, { second }, { third }))).toEqual {
      { type = 'STAT', id = 'rock', plugins = { 1, 2, 3 }, identical = {}, overridden = { 2 } },
    }

    -- Two plugins that differ are an override and nothing more to say; ids match ignoring case;
    -- a plugin that defines a record twice counts once, with its last copy.
    expect(tes3cmd.compare.overrides(order({ first }, { second }))).toEqual {}
    local shouted = fixtures.stat('ROCK', 'a.nif')
    local twice = tes3cmd.compare.overrides(order({ first }, { second, shouted }, { third }))
    expect(twice[1].plugins).toEqual { 1, 2, 3 }
    expect(twice[1].identical).toEqual {}
    expect(twice[1].overridden).toEqual { 2 }
    expect(tes3cmd.compare.overrides(order({ first }, { first }), { 'Static' })).toEqual {}

    -- A record edited in memory is compared as it is now.
    local edited = order({ first }, { first })
    tes3cmd.replace(edited[2], tes3cmd.selector(), tes3cmd.parseReplacement('/a.nif/z.nif/', true))
    expect(tes3cmd.compare.overrides(edited)).toEqual {}
    expect(tes3cmd.compare.diff(edited[1], edited[2]).changed[1].fields).toEqual {
      { field = 'mesh[1]', left = 'a.nif', right = 'z.nif' },
    }
  end)

  suite.it('finds topics that hide other topics', function()
    local plugins = {
      { name = 'left.esp', topics = { 'to rescue me' } },
      { name = 'right.esp', topics = { 'rescue me' } },
    }
    local overlaps = tes3cmd.compare.overlaps(plugins, true)
    expect(overlaps).toEqual {
      {
        earlierPlugin = 'left.esp',
        laterPlugin = 'right.esp',
        outerTopic = 'to rescue me',
        innerTopic = 'rescue me',
      },
    }
    local reversed = { plugins[2], plugins[1] }
    expect(#tes3cmd.compare.overlaps(reversed, true)).toBe(0)
    expect(#tes3cmd.compare.overlaps(reversed, false)).toBe(1)
    expect(tes3.records.dialogueTopics(open(fixtures.topic 'to rescue me'))).toEqual {
      'to rescue me',
    }
  end)

  suite.it('finds the first byte two buffers differ at, wherever it is', function()
    local text = 'The quick brown fox jumps over the lazy dog, twice.'
    local left = buffer.fromstring(text)
    for offset = 0, #text - 1 do
      local right = buffer.fromstring(text)
      buffer.writeu8(right, offset, 0)
      -- A later difference too, which isn't the first.
      buffer.writeu8(right, #text - 1, 1)
      local compared = tes3cmd.compare.compareBytes(left, right)
      expect(compared.identical).toBe(false)
      expect(compared.firstDifference).toBe(offset)
      expect(tes3cmd.compare.compareBytes(right, left).firstDifference).toBe(offset)
    end

    local empty = buffer.create(0)
    expect(tes3cmd.compare.compareBytes(empty, empty)).toEqual {
      identical = true,
      leftBytes = 0,
      rightBytes = 0,
    }

    expect(tes3cmd.compare.compareBytes(empty, left)).toEqual {
      identical = false,
      leftBytes = 0,
      rightBytes = #text,
      firstDifference = 0,
    }

    expect(tes3cmd.compare.compareBytes(left, buffer.fromstring(text .. '!'))).toEqual {
      identical = false,
      leftBytes = #text,
      rightBytes = #text + 1,
      firstDifference = #text,
    }
  end)

  suite.it('lists a diff by type and then id, as bytes order them', function()
    local function door(id: string, name: string): string
      return record('DOOR', subrecord('NAME', id) .. subrecord('FNAM', name))
    end

    local left = open(fixtures.plugin {
      fixtures.stat('b_same', 'a.nif'),
      fixtures.stat('Zeta', 'a.nif'),
      door('gate', 'Gate'),
      fixtures.stat('alpha', 'a.nif'),
      door('arch', 'Arch'),
      fixtures.stat('a_same', 'a.nif'),
      door('hatch', 'Hatch'),
    })

    local right = open(fixtures.plugin {
      door('hatch', 'Hatch'),
      fixtures.stat('a_same', 'a.nif'),
      fixtures.stat('omega', 'a.nif'),
      door('gate', 'Portcullis'),
      fixtures.stat('alpha', 'b.nif'),
      door('Wicket', 'Wicket'),
      fixtures.stat('b_same', 'a.nif'),
      fixtures.stat('Beta', 'a.nif'),
    })

    local diff = tes3cmd.compare.diff(left, right, nil, true)
    expect(diff.leftOnly).toEqual { { type = 'DOOR', id = 'arch' }, { type = 'STAT', id = 'Zeta' } }
    expect(diff.rightOnly).toEqual {
      { type = 'DOOR', id = 'Wicket' },
      { type = 'STAT', id = 'Beta' },
      { type = 'STAT', id = 'omega' },
    }

    expect(diff.equal).toEqual {
      { type = 'DOOR', id = 'hatch' },
      { type = 'STAT', id = 'a_same' },
      { type = 'STAT', id = 'b_same' },
    }

    expect(diff.changed).toEqual {
      {
        type = 'DOOR',
        id = 'gate',
        rawChanged = true,
        fields = { { field = 'name[1]', left = 'Gate', right = 'Portcullis' } },
      },
      {
        type = 'STAT',
        id = 'alpha',
        rawChanged = true,
        fields = { { field = 'mesh[1]', left = 'a.nif', right = 'b.nif' } },
      },
    }

    -- The equal records are only listed when asked for, and a type is left out by tag or name.
    expect(tes3cmd.compare.diff(left, right).equal).toBeNil()
    local doors = tes3cmd.compare.diff(left, right, { 'stat' }, true)
    expect(doors.leftOnly).toEqual { { type = 'DOOR', id = 'arch' } }
    expect(doors.rightOnly).toEqual { { type = 'DOOR', id = 'Wicket' } }
    expect(doors.equal).toEqual { { type = 'DOOR', id = 'hatch' } }
    expect(#doors.changed).toBe(1)
    expect(tes3cmd.compare.diff(left, right, { 'Static', 'Door' }, true)).toEqual {
      leftOnly = {},
      rightOnly = {},
      equal = {},
      changed = {},
    }
  end)

  suite.it('diffs a record a plugin has twice by its last copy, and its fields by its first', function()
    local left = open(fixtures.plugin {
      fixtures.stat('twice', 'first.nif'),
      fixtures.stat('once', 'a.nif'),
      fixtures.stat('twice', 'last.nif'),
    })

    local right = open(fixtures.plugin {
      fixtures.stat('twice', 'last.nif'),
      fixtures.stat('once', 'a.nif'),
      fixtures.stat('twice', 'other.nif'),
    })

    expect(tes3cmd.compare.diff(left, right).changed).toEqual {
      {
        type = 'STAT',
        id = 'twice',
        rawChanged = true,
        fields = { { field = 'mesh[1]', left = 'first.nif', right = 'last.nif' } },
      },
    }

    -- The last copies are the same bytes, so nothing changed, whatever the first ones hold.
    local same = open(fixtures.plugin { fixtures.stat('twice', 'x.nif'), fixtures.stat('twice', 'last.nif') })
    expect(tes3cmd.compare.diff(left, same, nil, true)).toEqual {
      leftOnly = { { type = 'STAT', id = 'once' } },
      rightOnly = {},
      equal = { { type = 'STAT', id = 'twice' } },
      changed = {},
    }

    expect(tes3cmd.compare.fieldChanges(left, right, { type = 'STAT', id = 'twice' })).toEqual {
      { field = 'mesh[1]', left = 'first.nif', right = 'last.nif' },
    }

    expect(tes3cmd.compare.fieldChanges(left, right, { type = 'STAT', id = 'missing' })).toEqual {}
  end)

  suite.it('reports fields that differ in order, and none of a type it has no name for', function()
    local function door(model: string, name: string, sound: string): string
      return record(
        'DOOR',
        subrecord('NAME', 'gate')
          .. subrecord('MODL', model)
          .. subrecord('FNAM', name)
          .. subrecord('SNAM', sound)
      )
    end

    local left = open(fixtures.plugin { door('a.nif', 'Gate', 'creak'), record('ZZZZ', subrecord('NAME', 'odd')) })
    local right = open(fixtures.plugin {
      door('b.nif', 'Gate', 'slam'),
      record('ZZZZ', subrecord('NAME', 'odd') .. subrecord('FNAM', 'Odd')),
    })

    expect(tes3cmd.compare.diff(left, right).changed).toEqual {
      {
        type = 'DOOR',
        id = 'gate',
        rawChanged = true,
        fields = {
          { field = 'mesh[1]', left = 'a.nif', right = 'b.nif' },
          { field = 'sound[3]', left = 'creak', right = 'slam' },
        },
      },
      { type = 'ZZZZ', id = 'odd', rawChanged = true, fields = {} },
    }
  end)

  suite.it('says where a record that is the start of another parts from it', function()
    local short = open(fixtures.plugin { fixtures.stat('rock', 'a.nif') })
    local long = open(fixtures.plugin {
      record('STAT', subrecord('NAME', 'rock') .. subrecord('MODL', 'a.nif') .. subrecord('XTRA', 'x')),
    })

    -- The size in the record's header is the first byte that differs.
    expect(tes3cmd.compare.firstDifference(short, long)).toEqual {
      index = 1,
      type = 'STAT',
      id = 'rock',
      offset = 328,
    }

    -- A record edited in memory is compared as it is now, and placed where it was in the file.
    local rocks = { fixtures.stat('rock', 'a.nif'), fixtures.stat('moss', 'a.nif') }
    local edited, other = open(fixtures.plugin(rocks)), open(fixtures.plugin(rocks))
    tes3cmd.replace(edited, tes3cmd.selector { exactId = 'moss' }, tes3cmd.parseReplacement('/nif/niF/', true))
    expect(tes3cmd.compare.firstDifference(edited, other)).toEqual {
      index = 2,
      type = 'STAT',
      id = 'moss',
      offset = 405,
    }
  end)

  suite.it('finds overlapping topics both ways, ignoring case, in load order', function()
    local plugins = {
      { name = 'one.esp', topics = { 'Rescue', 'the old mine', 'latest rumors' } },
      { name = 'two.esp', topics = { 'RESCUE', 'to rescue me', 'mine' } },
      { name = 'three.esp', topics = { 'rumors', 'old' } },
    }

    expect(tes3cmd.compare.overlaps(plugins)).toEqual {
      { earlierPlugin = 'one.esp', laterPlugin = 'two.esp', outerTopic = 'to rescue me', innerTopic = 'Rescue' },
      { earlierPlugin = 'one.esp', laterPlugin = 'two.esp', outerTopic = 'the old mine', innerTopic = 'mine' },
      { earlierPlugin = 'one.esp', laterPlugin = 'three.esp', outerTopic = 'the old mine', innerTopic = 'old' },
      {
        earlierPlugin = 'one.esp',
        laterPlugin = 'three.esp',
        outerTopic = 'latest rumors',
        innerTopic = 'rumors',
      },
    }

    expect(tes3cmd.compare.overlaps(plugins, true)).toEqual {
      { earlierPlugin = 'one.esp', laterPlugin = 'two.esp', outerTopic = 'the old mine', innerTopic = 'mine' },
      { earlierPlugin = 'one.esp', laterPlugin = 'three.esp', outerTopic = 'the old mine', innerTopic = 'old' },
      {
        earlierPlugin = 'one.esp',
        laterPlugin = 'three.esp',
        outerTopic = 'latest rumors',
        innerTopic = 'rumors',
      },
    }

    expect(tes3cmd.compare.overlaps({ plugins[1] })).toEqual {}
    expect(tes3cmd.compare.overlaps({})).toEqual {}
  end)
end)

suite.describe('files', function()
  suite.it('spells converted paths and refuses bad conversions', function()
    expect(tes3cmd.files.convertedPath('Data/Mod.esp', 'master')).toBe 'Data/Mod.esm'
    expect(tes3cmd.files.convertedPath('Mod.esm', 'plugin')).toBe 'Mod.esp'
    expect(tes3cmd.files.convertedPath('Mod', 'plugin')).toBe 'Mod.esp'
    expect(function() tes3cmd.files.convert('Mod.esm', 'master') end).toThrow 'input must be a .esp file'
    expect(function() tes3cmd.files.convert('Mod.esp', 'save') end).toThrow 'can\'t convert to a save'
    expect(function() tes3cmd.files.convert('Mod.esp', 'master', { output = 'Mod.esp' }) end).toThrow 'output must differ from resolved input'
    expect(function() tes3cmd.files.checkOutput('a.esp', 'a.esp') end).toThrow 'output must differ'
  end)

  suite.it('plans a conversion: where it writes, and whether a file is in the way', function()
    local folder = jess.fs.join(scratchRoot, 'files-conversion')
    local input = jess.fs.join(folder, 'Mod.esp')
    jess.fs.write(input, fixtures.cell())
    expect(tes3cmd.files.conversion(input, 'master')).toEqual {
      output = jess.fs.join(folder, 'Mod.esm'),
      exists = false,
    }
    expect(tes3cmd.files.conversion(input, 'master', jess.fs.join(folder, 'Mod.esp.bak')).exists).toBe(
      false
    )
    jess.fs.write(jess.fs.join(folder, 'Mod.esm'), 'in the way')
    expect(tes3cmd.files.conversion(input, 'master').exists).toBe(true)
    expect(function() tes3cmd.files.conversion(input, 'plugin') end).toThrow 'input must be a .esm file'
    expect(function() tes3cmd.files.conversion(input, 'master', input) end).toThrow 'output must differ from resolved input'
  end)

  suite.it('toggles the file type', function()
    local plugin = open(fixtures.cell())
    expect((tes3cmd.updateHeader(plugin, { fileType = 'master' }))).toBe(true)
    expect(open(saved(plugin)):header().fileType).toBe 'master'
  end)
end)

suite.describe('validate', function()
  suite.it('checks something for every profile', function()
    local plugin = open(fixtures.scripts())
    for _, profile in { 'raw', 'tes3', 'omwaddon' } :: { tes3.Profile } do
      expect(#tes3cmd.validate(plugin, profile).checks > 0).toBe(true)
    end

    local omwaddon = tes3cmd.validate(plugin, 'omwaddon')
    expect(omwaddon.checks).toEqual {
      'structure',
      'openmwRecordTypes',
      'dialogueOrder',
      'recordContents',
    }
    expect(omwaddon.diagnostics[1].message).toContain 'SCPT script_id doesn\'t read the way OpenMW reads it'
  end)
end)

suite.describe('numbers', function()
  suite.it('spells floats the shortest way that reads back', function()
    local cases: { { number | string } } = {
      { 0.25, '0.25' },
      { 1, '1.0' },
      { -0.0, '-0.0' },
      { 100, '100.0' },
      { 1e16, '1.0e16' },
      { 1.5e-5, '1.5e-5' },
      { string.unpack('<f', string.pack('<f', 0.1)) :: number, '0.1' },
      { 0 / 0, 'NaN' },
      { math.huge, 'inf' },
    }

    for _, case in cases do
      expect(tes3cmd.floatText(case[1] :: number)).toBe(case[2])
    end
  end)
end)

return suite
