# tes3cmd benchmarks

`bench/bench.jsl` times tes3cmd through its three modules, the way a tool reaches it: the
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
  --capability filesystem.write jpk/tes3cmd/bench/bench.jsl <scratch folder> [filter]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, a desktop shared with other work while
  this ran (load 1.2 to 1.9 through the main run).
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides.
- Base: `d8e8328`, the package before the move, with this bench (the bench file itself is the
  final one on both sides). Head: `1ed3bbe`, the package after the move and its review.
- Protocol: the whole bench against base and against head, four times each, alternating and
  swapping which goes first, back to back under one lock; each cell is the median of its four
  runs. A difference under 5 percent is called no change.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| lint, the recommended checks | 6208 | 5217 | 1.19x |
| lint, every check, against its master | 23945 | 19253 | 1.24x |
| lint, the per-record checks of a slice | 3272 | 3217 | no change |
| clean, every cleanup, against its master | 20444 | 15077 | 1.36x |
| validate as omwaddon | 30568 | 28611 | 1.07x ¹ |
| validate as tes3 | 6759 | 6601 | no change |
| stats | 5862 | 5799 | no change |
| compare the bytes of two equal plugins | 1418 | 71.4 | 19.87x |
| compare the bytes of two plugins that part ways late | 1008 | 112 | 8.96x |
| first record two plugins part ways at, late | 10436 | 5827 | 1.79x |
| common records of two plugins | 17542 | 16540 | 1.06x ¹ |
| diff two plugins | 531940 | 17795 | 29.89x |
| diff two plugins, the equal records listed | 530516 | 21703 | 24.44x |
| overrides of a load order of three | 42535 | 32851 | 1.29x |
| overlapping topics of three plugins | 5134 | 1921 | 2.67x |
| select by type and id | 3246 | 3233 | no change |
| select by exact id and flag | 2851 | 2876 | no change |
| select by raw bytes | 6382 | 4440 | 1.44x |
| select by subrecord text | 18866 | 18413 | no change |
| select CELL references | 21835 | 22329 | no change |
| delete by type | 3467 | 3338 | no change |
| delete subrecords by text | 18424 | 17485 | 1.05x ¹ |
| delete CELL references | 30064 | 29204 | no change |
| replace text in every string field | 50801 | 50488 | no change |
| replace text in selected subrecords | 38536 | 38284 | no change |
| extract by type, as a plugin | 3722 | 3609 | no change |
| extract selected CELL references | 29884 | 29973 | no change |
| dump the readable values of 3,700 records | 29295 | 27092 | 1.08x ¹ |
| layout of every record, its subrecords and fields | 84197 | 75895 | 1.11x ¹ |
| layout of the references of every CELL | 37513 | 35732 | no change |
| print 3,700 records as YAML | 271874 | 73705 | 3.69x |
| print 3,700 records as JSON | 80281 | 47565 | 1.69x |
| print 3,700 records as TOML | 250630 | 243054 | no change |
| print every layout as JSON | 249025 | 139826 | 1.78x |
| print every layout as YAML | 538456 | 263262 | 2.05x |
| print a listing as YAML | 46968 | 17193 | 2.73x |
| print a lint, a diff, and stats as YAML | 363651 | 332215 | 1.09x |
| print a lint, a diff, and stats as JSON | 60286 | 39974 | 1.51x |
| parse 13 command lines and print the help of each command | 678 | 688 | no change |
| tes3cmd lint --all | 156667 | 131799 | 1.19x |
| tes3cmd clean --dry-run | 24307 | 17147 | 1.42x |
| tes3cmd validate | 33632 | 32631 | no change |
| tes3cmd stats | 18126 | 17178 | 1.06x ¹ |
| tes3cmd diff | 573180 | 55895 | 10.25x |
| tes3cmd common | 190260 | 187087 | no change |
| tes3cmd compare | 1721 | 1742 | no change |
| tes3cmd overdial | 12457 | 8990 | 1.39x |
| tes3cmd dump | 375611 | 181238 | 2.07x |
| tes3cmd dump --format json | 203099 | 147328 | 1.38x |
| tes3cmd dump --raw | 360785 | 228793 | 1.58x |
| tes3cmd dump --list --type STAT | 26173 | 21636 | 1.21x |
| tes3cmd delete --dry-run | 4707 | 4407 | 1.07x ¹ |
| tes3cmd modify --dry-run | 19508 | 19058 | no change |
| tes3cmd test-codec | 7638 | 7269 | 1.05x ¹ |

¹ Measured again below. The whole bench ran base slower than head by 5 to 11 percent on seven
rows whose code is the same on both sides, or nearly: between rounds one of them moved by up to
22 percent within base, and by up to 15 within head. Each of those rows, and the one layout row
whose code did change, was measured again alone in a process of its own, alternating:

| Workload | Rounds | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|---:|
| layout of every record, its subrecords and fields | 5 | 82364 | 77079 | 1.07x |
| dump the readable values of 3,700 records | 5 | 27163 | 27790 | no change (0.98x) |
| common records of two plugins | 5 | 17282 | 17282 | no change (1.00x) |
| validate as omwaddon | 5 | 30416 | 29942 | no change (1.02x) |
| delete subrecords by text | 5 | 18722 | 18944 | no change (0.99x) |
| tes3cmd delete --dry-run | 5 | 4308 | 4253 | no change (1.01x) |
| layout of every record, its subrecords and fields | 9 | 88629 | 81288 | 1.09x |
| layout of every record, its subrecords and fields, glibc trimming off | 9 | 82104 | 76044 | 1.08x |
| tes3cmd stats | 9 | 18021 | 17996 | no change (1.00x) |
| tes3cmd test-codec | 9 | 9182 | 7302 | 1.26x |
| tes3cmd test-codec, glibc trimming off | 9 | 7468 | 7699 | no change (0.97x) |

So six of the rows are not shown to have moved. `tes3cmd test-codec` is two speeds, 7.2 and 9 to
10 ms, on both sides, by where glibc happens to have trimmed the heap; with trimming off
(`MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at 1 GiB) it is one speed and the same on
both. The layout of every record read 1.07x to 1.11x in all four measurements, with base's runs
spread 9 to 17 percent apart: a small gain, and at the edge of what this machine resolves.

A run of the command line from a cold start, the whole process timed, 25 runs a side,
alternating, on the bench's 2.2 MB `Mod.esp`: `stats` 293.3 ms on base and 295.2 on head, `lint`
298.6 and 301.0, `dump --list --type STAT` 298.3 and 304.6 (medians). No change: head finished 2
to 6 ms later, 0.6 to 2 percent, which is under what is called a difference here.

## What moved, and why

- **A diff** (30x and 24x in memory, 10x from the command line). For every changed record it
  searched both plugins from the top for the record's type and id, to read its fields: for each
  of the 299 changed records of this input, up to 11,000 records looked at in each plugin, so
  the time grew with the two multiplied. The diff already had the key maps that say where each
  record is, and now reads the fields there (the first copy of a record a plugin has twice, as
  the search found). The rest is the sort: the keys were tables sorted by a comparator, and are
  now strings of type, NUL, and id sorted as strings, made into tables afterwards; the records
  both plugins have unchanged are only made when they're listed.
- **Comparing bytes** (20x for two equal files of 2.2 MB, 9x for two that differ seven eighths of
  the way in). A loop that read both buffers eight bytes at a time is `bytes.compare`, halved
  down to the first byte that differs when there is one. The first record two plugins don't
  share (1.8x) is found with the same comparison over the records where the plugins hold them,
  instead of over a copy of each.
- **A dump's YAML** (3.7x for readable values, 2.1x for a byte layout, 2.7x for a listing, 2.1x
  for `tes3cmd dump`). Every text that isn't a plain name was handed to `@jess/data/value` to be
  spelled as a whole YAML document, a character at a time. A text is now told by its bytes,
  through a table of what each byte may be part of: a name is plain; a sentence that starts with
  a letter and holds no `:` or `#` is plain too, as the reference would decide; digits are
  quoted, as it quotes them; and only what is left is asked of it. The suite holds this to the
  reference over some 6,000 texts, each in four documents. A block of text is checked for what
  it can't hold with one compiled pattern, keys are written with their colon, and punctuation a
  byte at a time.
- **A dump's JSON** (1.7x for readable values, 1.8x for a byte layout). A string was matched
  against a pattern for a character to escape, and handed away when it had one; it is written
  where it goes and looked through there, and escaped here. A key is written with its comma and
  colon in one write.
- **Reports as JSON** (1.5x) and `lint --all` (1.2x): every finding's check was looked up by
  spelling out all 27 checks in three spellings each. They're spelled once, in a table.
- **Overlapping topics** (2.7x, 1.4x for `overdial`): each topic was lowered again for every topic
  it was compared with, and searched for in topics shorter than it. A topic is lowered the first
  time it is compared, and kept.
- **Cleaning** (1.4x) and **lint against a master** (1.2x): a master's records were keyed by a
  string built for each record and for each lookup, each holding a table; they're keyed by type
  and then id, each one number. Cleaning read every record's id twice.
- **Lint's recommended checks** (1.2x): where a response's text is cut is found by a native
  search for its NUL.
- **Overrides** (1.3x): a copy of a record is one number, not a table, and a record is found by
  its type and then its id with no key built.
- **Selecting by raw bytes** (1.4x): a record's bytes were copied out of the plugin and then
  copied into a string.
- **The layout of every record** (1.07x to 1.11x): whether a record was edited, and whether a
  selector filters subrecords at all, is asked once for the record instead of once for each of
  its subrecords.

## What did not move

The comprehensions, reducers, ranges, and record patterns the loops became lower to the loops
they replaced, and the rows only they touch read no change: selection by type, id, flag, and
subrecord, deletion, replacement, extraction, and the argument parser. A validation's findings
are ordered by a stable `data.argsort` over their offsets instead of a comparator and a table of
positions, which this input, having none to order, does not time.

Some loops are loops on purpose. A list a caller hands in is walked as it is, whatever is in it
and wherever: a selector spec's patterns, flags, and ids, a selector's own lists, a request's
ignored and excluded types, the topics of the plugins compared for overlaps, the plugins of a
load order, and the lists of a result printed as TOML. A comprehension reads such a list from 1
to its length, and stops at, or refuses, a gap the loop walks past; the suite holds each of
these to a list with one.

Three things are not tes3cmd's to speed up. Reports print through `@jess/data/value`, whose YAML
writer is a port of libyaml's emitter that goes a character at a time: it is nearly all of
`print a lint, a diff, and stats as YAML` (332 ms against 40 ms for the same reports as JSON)
and of `tes3cmd common` (187 ms from the command line, of which finding the records is the 17 ms
of `common records of two plugins`). A dump as TOML is built as a tree and written by the same
module. And record identity, subrecord lists, string fields, and decoding are `@esm`'s, which is
most of validation, selection by subrecord, replacement, and what remains of the layouts.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 0.87 and 0.67 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@tes3cmd`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@tes3cmd` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.166 s | 0.131 s |
| Final | 0.122 s | 0.116 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| lint, the recommended checks | 5.243 | **1.320×** | 4.853 | 0.926× |
| lint, every check, against its master | 19.94 | **1.103×** | 17.97 | 0.901× |
| lint, the per-record checks of a slice | 3.247 | **1.383×** | 3.158 | 0.973× |
| clean, every cleanup, against its master | 15.36 | **1.180×** | 14.39 | 0.937× |
| validate as omwaddon | 34.16 | 1.037× | 32.36 | 0.947× |
| validate as tes3 | 6.478 | 0.989× | 5.970 | 0.922× |
| stats | 5.793 | **1.545×** | 5.270 | 0.910× |
| compare the bytes of two equal plugins | 0.06583 | 0.953× | 0.06527 | 0.992× |
| compare the bytes of two plugins that part ways late | 0.1109 | 0.917× | 0.1075 | 0.969× |
| first record two plugins part ways at, late | 6.150 | **1.225×** | 5.730 | 0.932× |
| common records of two plugins | 16.78 | **1.100×** | 15.43 | 0.919× |
| diff two plugins | 18.02 | **1.181×** | 17.01 | 0.944× |
| diff two plugins, the equal records listed | 22.07 | **1.149×** | 20.53 | 0.930× |
| overrides of a load order of three | 32.22 | **1.300×** | 29.04 | 0.901× |
| overlapping topics of three plugins | 1.908 | **1.617×** | 1.783 | 0.934× |
| select by type and id | 3.217 | **1.287×** | 2.993 | 0.930× |
| select by exact id and flag | 3.659 | **1.573×** | 3.321 | 0.908× |
| select by raw bytes | 4.409 | **1.325×** | 4.056 | 0.920× |
| select by subrecord text | 17.66 | **1.201×** | 16.59 | 0.939× |
| select CELL references | 20.78 | **1.148×** | 19.20 | 0.924× |
| delete by type | 3.476 | **1.332×** | 3.234 | 0.931× |
| delete subrecords by text | 17.56 | **1.179×** | 15.91 | 0.906× |
| delete CELL references | 27.76 | **1.106×** | 25.71 | 0.926× |
| replace text in every string field | 49.64 | **1.074×** | 46.91 | 0.945× |
| replace text in selected subrecords | 37.63 | **1.138×** | 35.31 | 0.938× |
| extract by type, as a plugin | 3.765 | **1.485×** | 3.443 | 0.915× |
| extract selected CELL references | 28.90 | **1.105×** | 27.56 | 0.954× |
| dump the readable values of 3,700 records | 29.17 | 1.039× | 27.49 | 0.942× |
| layout of every record, its subrecords and fields | 76.47 | **1.112×** | 71.64 | 0.937× |
| layout of the references of every CELL | 34.09 | **1.091×** | 32.57 | 0.955× |
| print 3,700 records as YAML | 73.43 | **2.151×** | 67.73 | 0.922× |
| print 3,700 records as JSON | 47.47 | **2.470×** | 44.32 | 0.934× |
| print 3,700 records as TOML | 234.0 | **1.056×** | 219.9 | 0.940× |
| print every layout as JSON | 137.5 | **2.786×** | 129.8 | 0.944× |
| print every layout as YAML | 262.7 | **2.369×** | 244.7 | 0.932× |
| print a listing as YAML | 17.38 | **2.660×** | 16.02 | 0.922× |
| print a lint, a diff, and stats as YAML | 323.1 | 1.011× | 301.4 | 0.933× |
| print a lint, a diff, and stats as JSON | 38.12 | **1.076×** | 35.31 | 0.926× |
| parse 13 command lines and print the help of each command | 0.6705 | **1.173×** | 0.7315 | **1.091×** |
| tes3cmd lint --all | 128.9 | 1.025× | 122.9 | 0.954× |
| tes3cmd clean --dry-run | 16.77 | **1.221×** | 16.31 | 0.972× |
| tes3cmd validate | 36.33 | 1.045× | 35.16 | 0.968× |
| tes3cmd stats | 17.04 | **1.345×** | 15.44 | 0.906× |
| tes3cmd diff | 54.16 | **1.091×** | 50.96 | 0.941× |
| tes3cmd common | 183.7 | 1.049× | 171.4 | 0.933× |
| tes3cmd compare | 1.521 | **1.224×** | 1.451 | 0.954× |
| tes3cmd overdial | 8.676 | **1.206×** | 7.874 | 0.908× |
| tes3cmd dump | 178.6 | **1.789×** | 166.8 | 0.934× |
| tes3cmd dump --format json | 144.8 | **1.715×** | 134.8 | 0.931× |
| tes3cmd dump --raw | 223.9 | **2.127×** | 207.9 | 0.929× |
| tes3cmd dump --list --type STAT | 20.54 | **1.672×** | 19.92 | 0.970× |
| tes3cmd delete --dry-run | 4.457 | **1.218×** | 4.049 | 0.908× |
| tes3cmd modify --dry-run | 18.92 | **1.130×** | 18.02 | 0.953× |
| tes3cmd test-codec | 6.747 | 1.011× | 6.514 | 0.965× |

What carries the directive (every module and function here is one a row spends its time in,
unmarked):

- Whole: `display`, `edit`, `pages`, `render`, `select`, `stats`.
- `commands`, by function: a closure at line 306.
- `compare`, by function: `sameRecord`, `firstMismatch`, `common`, `objectMap`, `diff`, `overlaps`,
  `overrides`, `firstDifference`, `nextKept`.
- `lint`, by function: `display`, `isJunkCell`, `infoTextToken`, `matchRanges`, `recordRanges`,
  `recordsByCode`, `recordChecks`, `lint`, `tokenAt`, `clean`.
- Unmarked: `arguments`, `cli`, `files`, `init`, `main`, `masters`, `numbers`.

`arguments`, `cli`, and `main` parse a command line once a run and are never marked, so `parse
13 command lines and print the help of each command` (1.09x, of a 0.7 ms call) is the one row
slower than all marked, by rule. `pages`, the YAML and JSON writer, is marked whole: with only
its seventeen hottest functions marked, the dumps stayed 1.09x to 1.22x slower than all marked,
the calls between those functions and the rest of the writer being most of what was left.
Unmarked, `tes3cmd dump` ran 1.7x to 2.1x slower, 0.16 s to 0.3 s a call.
