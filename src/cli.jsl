--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
@tes3cmd/cli: the `tes3cmd` command line, which is `jess plugin`'s: the same commands, the same
flags, the same documents.

  parse(argv) -> (command, nil) | (nil, message)
  render(result, options?) -> text
  status(result) -> exit status
  complaint(result) -> message?
  usage(topic?) -> text
  run(argv, write?) -> exit status

  tes3cmd [--format yaml|json|toml] <command> [options] <plugin>...
  tes3cmd <command> --help

`parse` reads an argument list into the command it names and the request `@tes3cmd/commands` takes
for it, touching no file. `render` is that command's result as the one document the command
prints, `status` the exit status the outcome has, and `complaint` what standard error says of an
outcome that isn't 0. `run` is the four in a row and nothing more: parse, call the command, print
the document, return the status. `write` takes what would be printed (`'stdout'` or `'stderr'`,
and the text) in place of the process's own streams.

A dump is the one command `run` calls more than once: it asks for the records a page at a time
(the request's `from` and `limit`, the result's `next`) and prints each page as it comes, so a
master's records are never all held at once. `render` prints a page as the part of the document
it is, and the pages one after another are the document a dump asked for whole prints.

Two things `jess plugin` did aren't here, and each is refused by name. `assets` is another
package's command now, `plugin-assets`. `modify --script` ran a Luau script on the plugin, and
today's Jess gives a package no way to load and run a script file handed to it.

Exit statuses: 0 when the command did what it was asked; 1 for the outcomes a command's help
names (`compare`: the files differ; `validate`: the file doesn't fit the profile; `lint`: a finding
at least as severe as `--fail-on`; `test-codec`: a file doesn't come back byte for byte); 8 when
the command line can't be used (no command or an unknown one, an unknown or repeated flag, a
missing or extra argument, a value a flag doesn't take, flags that can't go together); 9 when the
command failed (a file that isn't there, doesn't parse, or can't be written, a pattern that isn't
a regex, a conversion a file is in the way of). Messages go to standard error as
`tes3cmd: <message>`; the document goes to standard output.
]]

local Arguments = require './arguments'
local Commands = require './commands'
local Render = require './render'
local process = require '@dream/process'

export type Format = Arguments.Format
export type Command = Arguments.Command
export type Request = Arguments.Request
export type Options = Render.Options
export type Write = (stream: 'stdout' | 'stderr', text: string) -> ()

local Version = '0.1.0'

local Exit = table.freeze { ok = 0, found = 1, invalidInput = 8, runtime = 9 }

--- `count` with the word that agrees with it: `1 error was found`, `2 errors were found`.
local function counted(count: number, one: string, many: string): string
  return `{count} {if count == 1 then one else many}`
end

--- The exit status a result has: 1 for what its command reports as a failure on purpose, 9 for a
--- conversion a file stood in the way of, and 0 otherwise.
local function status(result: Commands.Result): number
  if result.command == 'compare' then return if result.identical then Exit.ok else Exit.found end

  if result.command == 'validate' then return if result.valid then Exit.ok else Exit.found end

  if result.command == 'lint' then return if result.failing == 0 then Exit.ok else Exit.found end

  if result.command == 'testCodec' then
    return if result.failed == 0 then Exit.ok else Exit.found
  end

  if (result.command == 'esm' or result.command == 'esp') and result.blocked then
    return Exit.runtime
  end

  return Exit.ok
end

--- What standard error says of a result whose status isn't 0, or nil.
local function complaint(result: Commands.Result): string?
  if status(result) == Exit.ok then return nil end

  if result.command == 'compare' then return 'files differ' end

  if result.command == 'validate' then return 'profile validation failed' end

  if result.command == 'testCodec' then
    return `codec failed for {counted(result.failed, 'file', 'files')}`
  end

  if result.command == 'esm' or result.command == 'esp' then
    return `{result.output} already exists; use --overwrite to replace it`
  end

  if result.command ~= 'lint' then return nil end

  if result.failOn == 'warning' then
    return counted(result.failing, 'error or warning was found', 'errors or warnings were found')
  end

  if result.failOn == 'any' then
    return counted(result.failing, 'problem was found', 'problems were found')
  end

  return counted(result.failing, 'error was found', 'errors were found')
end

--- What a raised error says, with what the command line can do about it where there is something.
local function reason(problem: unknown): string
  local text = tostring(problem)
  local encoding = string.match(text, 'can\'t be written in (.-), the plugin\'s encoding$')
  if not encoding then return text end

  return `{text}; nothing was written\nhint: if the plugin's text isn't {encoding}, pass its code page with --encoding (win1250, win1251, or win1252); if it is, the replacement needs characters {encoding} has`
end

--- The command of `@tes3cmd/commands` a parsed command names, called on its request.
local function call(command: Command): Commands.Result
  local run = (Commands :: { [string]: unknown })[command.command]
  if type(run) ~= 'function' then error(`tes3cmd has no command '{command.command}'`, 0) end

  return run(command.request)
end

--- What a dump holds as values at a time: a whole master's records wouldn't fit in memory. A
--- page is so many records, or fewer when their bytes in the file come to the budget first, since
--- a few hundred large cells are as much to hold as a small plugin.
local PageSize = 512
local PageBytes = 65536

--- The command with its dump asked for in pages, from record `from` on: a dump is printed a page
--- at a time, as the original printed each record as it read it. A dump to a file isn't printed,
--- and a TOML document has no list to leave open, so those are asked for whole.
local function paging(command: Command, from: number?): Command
  local request = command.request :: Commands.DumpRequest
  if command.command ~= 'dump' or command.format == 'toml' or request.rawOutput then
    return command
  end

  local page = table.clone(request)
  page.limit = PageSize
  page.byteLimit = PageBytes
  page.from = from
  return { command = 'dump', format = command.format, request = page }
end

local function standard(stream: 'stdout' | 'stderr', text: string) process.write(stream, text) end

--- Calls the command, prints its document, and for a result whose status isn't 0 says why. The
--- status, or for a page of a dump with pages to follow, the record the next one starts at.
--- Nothing of the result outlives the call: a page's values and its text are done with once it
--- is printed.
local function answer(command: Command, continued: boolean, print: Write): (number, number?)
  -- A command raises for a request it can't carry out: a file that isn't there, doesn't parse,
  -- or can't be written, a pattern that isn't a regex, a record type nothing has.
  local ran, result = pcall(call, command)
  if not ran then
    print('stderr', `tes3cmd: {reason(result)}\n`)
    return Exit.runtime, nil
  end

  -- The plugins the command read are garbage now, and all that is left to do is print what it
  -- learned. Luau's collector wouldn't get to them until the heap had grown by as much again, so
  -- they are collected here: a report is then printed in the room its plugins took, not on top
  -- of them. A dump's page still has its plugin, and is collected once it is printed.
  local paged = result.command == 'dump' and (continued or result.next ~= nil)
  if not paged then jess.bench.collect() end

  local document = Render.render(result, { format = command.format, continued = continued })
  if document ~= '' then print('stdout', document) end

  if result.command == 'dump' and result.next then return Exit.ok, result.next end

  local said = complaint(result)
  if said then print('stderr', `tes3cmd: {said}\n`) end

  return status(result), nil
end

local function run(argv: { string }, write: Write?): number
  local print: Write = write or standard
  local command, message = Arguments.parse(argv)
  if not command then
    print('stderr', `tes3cmd: {message}\n`)
    return Exit.invalidInput
  end

  if command.command == 'help' then
    print('stdout', Arguments.usage(command.topic) .. '\n')
    return Exit.ok
  end

  if command.command == 'version' then
    print('stdout', `tes3cmd {Version}\n`)
    return Exit.ok
  end

  local asked, continued = paging(command), false
  while true do
    local outcome, more = answer(asked, continued, print)
    if not more then return outcome end

    -- A page's values and text are garbage now, and Luau's collector only starts once the heap
    -- has grown by as much again as was live. With a master open that is the master's size in
    -- garbage before it runs, so a dump would take twice the memory the plugin does. A full
    -- collection here keeps what a dump holds to the plugin and one page, whatever the file.
    jess.bench.collect()
    asked, continued = paging(asked, more), true
  end
end

return table.freeze {
  Exit = Exit,
  complaint = complaint,
  parse = Arguments.parse,
  render = Render.render,
  run = run,
  status = status,
  usage = Arguments.usage,
}
