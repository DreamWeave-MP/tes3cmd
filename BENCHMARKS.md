# tes3cmd benchmarks

`bench/bench.luau` times tes3cmd through its three modules, the way a tool reaches it: the
checks, cleanups, comparisons, selections, edits, and layouts `@tes3cmd` runs on plugins in
memory; the documents `@tes3cmd/cli` prints for what `@tes3cmd/commands` found; and the command
line, from its arguments to its last byte of output, on files. The input is a mod of 11,000
records built from the suite's `all_types.esp`: statics and items, settings, spells, 400 scripts,
3,000 dialogue responses, 300 cells of 20 references, and doors, with the dirt and the mistakes
the checks look for among them; a master it shares 2,600 records with; and two later plugins
that change, drop, and add some. Each file is about 2.2 MB.

Each workload is warmed up, sized to a batch of about a tenth of a second, and reported as the
median of seven batches with a full collection between them. Every workload's result (everything
it found, or every byte it printed) is digested and held to a digest kept in the bench, made
from the package before the move: a path that stops doing the work, or does other work, stops
the run instead of posting a time.

```sh
jess run --package jpk/tes3cmd --package-path jpk --capability filesystem.read \
  --capability filesystem.write jpk/tes3cmd/bench/bench.luau <scratch folder> [filter]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, a desktop shared with other work while
  this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.1 (Luau 0.742), the same one for
  both sides.
- Base: `d8e8328`, the package before the move, with this bench (the bench file itself is the
  final one on both sides). Head: `b2c87f1`.
- Protocol: the whole bench against base and against head, five times each, alternating and
  swapping which goes first, back to back under one lock; each cell is the median of its five
  runs. A difference under 5 percent is called no change.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| lint, the recommended checks | 6214 | 5442 | 1.14x |
| lint, every check, against its master | 22822 | 19989 | 1.14x |
| lint, the per-record checks of a slice | 3236 | 3282 | no change |
| clean, every cleanup, against its master | 19509 | 15193 | 1.28x |
| validate as omwaddon | 29031 | 31113 | 0.93x ¹ |
| validate as tes3 | 6672 | 6735 | no change |
| stats | 5825 | 5906 | no change |
| compare the bytes of two equal plugins | 1431 | 72.2 | 19.80x |
| compare the bytes of two plugins that part ways late | 1000 | 123 | 8.11x |
| first record two plugins part ways at, late | 10411 | 6063 | 1.72x |
| common records of two plugins | 16906 | 17756 | no change |
| diff two plugins | 520854 | 19676 | 26.47x |
| diff two plugins, the equal records listed | 518807 | 23049 | 22.51x |
| overrides of a load order of three | 39933 | 32396 | 1.23x |
| overlapping topics of three plugins | 5159 | 1934 | 2.67x |
| select by type and id | 3330 | 3322 | no change |
| select by exact id and flag | 2803 | 2928 | no change |
| select by raw bytes | 6220 | 4712 | 1.32x |
| select by subrecord text | 17799 | 18397 | no change |
| select CELL references | 20940 | 22320 | 0.94x ¹ |
| delete by type | 3324 | 3281 | no change |
| delete subrecords by text | 17600 | 17539 | no change |
| delete CELL references | 28209 | 28754 | no change |
| replace text in every string field | 48944 | 50255 | no change |
| replace text in selected subrecords | 37207 | 37862 | no change |
| extract by type, as a plugin | 3550 | 3786 | 0.94x ¹ |
| extract selected CELL references | 29001 | 30240 | no change |
| dump the readable values of 3,700 records | 26317 | 27815 | 0.95x ¹ |
| layout of every record, its subrecords and fields | 75881 | 78409 | no change |
| layout of the references of every CELL | 35764 | 36277 | no change |
| print 3,700 records as YAML | 268770 | 74473 | 3.61x |
| print 3,700 records as JSON | 79890 | 48012 | 1.66x |
| print 3,700 records as TOML | 235986 | 240081 | no change |
| print every layout as JSON | 240877 | 138928 | 1.73x |
| print every layout as YAML | 524714 | 266395 | 1.97x |
| print a listing as YAML | 47487 | 17800 | 2.67x |
| print a lint, a diff, and stats as YAML | 354524 | 332259 | 1.07x |
| print a lint, a diff, and stats as JSON | 60770 | 41640 | 1.46x |
| parse 13 command lines and print the help of each command | 683 | 692 | no change |
| tes3cmd lint --all | 151872 | 133830 | 1.13x |
| tes3cmd clean --dry-run | 21699 | 18446 | 1.18x |
| tes3cmd validate | 33408 | 34487 | no change |
| tes3cmd stats | 17228 | 18044 | no change |
| tes3cmd diff | 564917 | 58899 | 9.59x |
| tes3cmd common | 183394 | 194294 | 0.94x ¹ |
| tes3cmd compare | 1864 | 1827 | no change |
| tes3cmd overdial | 12036 | 9264 | 1.30x |
| tes3cmd dump | 369472 | 192203 | 1.92x |
| tes3cmd dump --format json | 186349 | 157226 | 1.19x |
| tes3cmd dump --raw | 340870 | 245181 | 1.39x |
| tes3cmd dump --list --type STAT | 25698 | 23650 | 1.09x |
| tes3cmd delete --dry-run | 4461 | 4906 | 0.91x ¹ |
| tes3cmd modify --dry-run | 19077 | 18497 | no change |
| tes3cmd test-codec | 7462 | 7107 | 1.05x |

¹ Six rows read 5 to 9 percent slower. Two of the five rounds ran while the desktop was busy
(load 3 to 4 against 1.3 to 1.5), and in those rounds one side of a row ran up to 30 percent over
its own other rounds. Each of the six was measured again alone, seven rounds a side, alternating:

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| validate as omwaddon | 28770 | 29667 | no change (0.97x) |
| tes3cmd common | 196120 | 190980 | no change (1.03x) |
| tes3cmd delete --dry-run | 4314 | 4311 | no change |
| extract by type, as a plugin | 3836 | 3742 | no change (1.03x) |
| select CELL references | 21862 | 21608 | no change |
| dump the readable values of 3,700 records | 27870 | 26291 | 1.06x |

So none of the six is shown to be slower, and the last one is not shown to be faster: on this
machine tonight a row moves by that much from one run to the next.

A first run of the same comparison, three rounds a side, was thrown away. A linker elsewhere on
the machine was using four to five cores through it, and rows whose code is the same on both
sides came out up to 20 percent apart, in whichever direction the load fell.

## What moved, and why

- **A diff** (26x and 23x in memory, 9.6x from the command line). For every changed record it
  searched both plugins from the top for the record's type and id, to read its fields: for each
  of the 299 changed records of this input, up to 11,000 records looked at in each plugin, so
  the time grew with the two multiplied. The diff already had the key maps that say where each
  record is, and now reads the fields there (the first copy of a record a plugin has twice, as
  the search found). The rest is the sort: the keys were tables sorted by a comparator, and are
  now strings of type, NUL, and id sorted as strings, made into tables afterwards; the records
  both plugins have unchanged are only made when they're listed.
- **Comparing bytes** (20x for two equal files of 2.2 MB, 8x for two that differ seven eighths of
  the way in). A loop that read both buffers eight bytes at a time is `bytes.compare`, halved
  down to the first byte that differs when there is one. The first record two plugins don't
  share (1.7x) is found with the same comparison over the records where the plugins hold them,
  instead of over a copy of each.
- **A dump's YAML** (3.6x for readable values, 2.0x for a byte layout, 2.7x for a listing, 1.9x
  for `tes3cmd dump`). Every text that isn't a plain name was handed to `@jess/data/value` to be
  spelled as a whole YAML document, a character at a time: about 150 of the readable dump's 270
  ms, by a timer put around that call. A text is now told by its bytes, through a table of what
  each byte may be part of: a name is plain; a sentence that starts with a letter and holds no
  `:` or `#` is plain too, as the reference would decide; digits are quoted, as it quotes them;
  and only what is left is asked of it. The suite holds this to the reference over some 6,000
  texts, each in four documents. A block of text is checked for what it can't hold with one
  compiled pattern, keys are written with their colon, and punctuation a byte at a time.
- **A dump's JSON** (1.7x for both). A string was matched against a pattern for a character to
  escape, and handed away when it had one; it is written where it goes and looked through
  there, and escaped here. A key is written with its comma and colon in one write.
- **Reports as JSON** (1.5x) and `lint --all` (1.1x): every finding's check was looked up by
  spelling out all 27 checks in three spellings each. They're spelled once, in a table.
- **Overlapping topics** (2.7x, 1.3x for `overdial`): each topic was lowered again for every topic
  it was compared with, and searched for in topics shorter than it.
- **Cleaning** (1.3x) and **lint against a master** (1.1x): a master's records were keyed by a
  string built for each record and for each lookup, each holding a table; they're keyed by type
  and then id, each one number. Cleaning read every record's id twice.
- **Lint's recommended checks** (1.1x): where a response's text is cut is found by a native
  search for its NUL.
- **Overrides** (1.2x): a copy of a record is one number, not a table, and a record is found by
  its type and then its id with no key built.
- **Selecting by raw bytes** (1.3x): a record's bytes were copied out of the plugin and then
  copied into a string.

## What did not move

The comprehensions, reducers, ranges, and record patterns the loops became lower to the loops
they replaced, and the rows only they touch read no change: selection by type, id, flag, and
subrecord, deletion, replacement, extraction, and the argument parser. A validation's findings
are ordered by a stable `data.argsort` over their offsets instead of a comparator and a table of
positions, which this input, having none to order, does not time.

One commit is marked `PERF` that this table does not bear out: asking once per record, instead
of once per subrecord, whether it was edited (`eae933e`). The two layout rows read no change.

Three things are not tes3cmd's to speed up. Reports print through `@jess/data/value`, whose YAML
writer is a port of libyaml's emitter that goes a character at a time, about 0.3 µs a byte of
text: it is nearly all of `print a lint, a diff, and stats as YAML` (332 ms against 42 ms for
the same reports as JSON) and of `tes3cmd common` (about 17 ms to find the records, and the rest
of its 190 to read the two files and print 10,800 keys). A dump as TOML is built as a tree and
written by the same module. And record identity, subrecord lists, string fields, and decoding
are `@tes3`'s, which is most of validation, selection by subrecord, replacement, and what
remains of the layouts.
