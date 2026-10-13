# Mobile export work log

## Window and goal

Start: 2026-10-13 09:45 UTC. End: 2026-10-14 01:45 UTC.
Reduce the experimental planet export for mobile browsers. Aim well below
100 MB for both data files. Record file size, browser memory, load time, and
changes to the map. Keep the fitted plans and full export as references.
Do not change production, UK, or Germany datasets. Keep H3-MON stopped except
for isolated, headless checks that do not start its normal service.

## 09:45 UTC: inspect the consumer and plan measurements

The full export has 120,753,287 rows and uses 8.24 GB. It keeps 99.999% of
each source cell's transport mass. This is a research export, not a suitable
browser dataset. The current browser loads the entire file and builds row
indexes, so file compression alone will not fix its memory use.

The browser uses target-normalized `weight_mean` for aggregation. It also
uses source-to-target support for navigation. Keep both source and target
coverage, the original labels, and source population totals. Measure errors
in target population, geographic means, source means, and conditional weights.

Compare these approaches before choosing a default:

1. Cull by source weight, with explicit source and target coverage guards.
2. Cull by population contribution to each target, with a source anchor.
3. Use narrower numeric columns where their error is negligible.
4. If necessary, adjust the sparse weights to reduce marginal or moment error.

Do not confuse an approximate browser export with the full fitted transport.
Keep the full-plan mass checks unchanged. Test the Arrow files with the actual
JavaScript dependencies before publication. Compression must not require an
unsupported Arrow codec or conceal excessive decoded memory.

Documentation checked: Arrow.jl write API, loaders.gl Arrow reading guide,
and the Arrow JavaScript compression issue. The installed browser uses
Apache Arrow 19.0.1 through loaders.gl. Its actual decoder is the final check.

- https://arrow.apache.org/julia/stable/reference/
- https://loaders.gl/docs/arrowjs/developer-guide/reading-and-writing
- https://github.com/apache/arrow-js/issues/109

## 11:00 UTC: culling profiles and sparse weight adjustment

Built a source and target index for all 120,753,287 rows. Saved separate
country caches for bounded tests. The reference has 387,294 source cells,
54,942 country-target pairs, and 1,715 labelled source cells. Eleven target
coordinates occur in more than one country.

Simple culling causes large errors. Keeping four rows per source, plus
coverage guards, gives an estimated 44 MB transport file. But its 99th
percentile geographic mean error is 114 km. Keeping 32 rows per target gives
an estimated 56 MB and a 62 km error. These estimates exclude the density
file and assume Float32 population. Neither is a safe default.

Tested nonnegative weight adjustment with linear constraints. It preserves
source totals, target population, target geographic means, source forward
means, and optionally target mean population density. Each labelled source
keeps its original anchor with at least half its original weight. These
constraints do not preserve arbitrary data values or the full transport.

A Germany reference test reduced 100,137 rows to 7,746 in 121 seconds.
Maximum geographic mean error was below 0.001 metres. Maximum relative
target population error was 2.3e-9. However, median target total variation
was 0.494. This is an approximation, not lossless compression. This test
did not change the Germany dataset.

Added a separate Julia environment with HiGHS 1.26.0. Direct crossover in
its native HiGHS 1.15.1 crashed before worker initialization. A zero-iteration
solve initializes the workers before crossover. No installed package was
changed. Unit tests pass: 25 export checks and 13 moment checks.

Two dense 128-source blocks from the US and China failed crossover with a
600-second limit. Their results were rejected. The first log did not include
the failure status or elapsed time; this was not proof of a timeout. Test smaller
target blocks next, then merge their sparse results. Keep the full reference
and do not publish a reduced file until independent checks pass.

HiGHS references:

- https://ergo-code.github.io/HiGHS/dev/interfaces/julia/
- https://jump.dev/JuMP.jl/stable/packages/HiGHS/

## 11:10 UTC: bounded blocks and numerical scaling

The smaller blocks exposed a numerical failure, not a time limit. Tiny
weights and redundant moment equations caused crossover to return an unknown
status. Scale the block weights and remove the known shared equations with
pivoted QR. Still check every original equation, including those removed.
A new small-weight regression test passes. There are now 16 moment checks.

A dense US block fell from 217,800 rows to 9,535. Four target-block stages
used 7.3 seconds in crossover. A China block fell from 420,379 to 23,612.
Some small China blocks failed the nonnegative-weight check and retained
their input. Later merges succeeded. No failed result was accepted.

Added a country driver with stage checkpoints and full-country checks.
Started US and China trials. Each stage merges source and target blocks.
The driver retains the input of any failed block. This can increase file
size, but cannot silently install an invalid sparse solution.

## 11:30 UTC: file schema and data-query probes

Added a flat Arrow writer with Int16 coordinates, UInt16 country codes,
UInt32 H3 halves, and Float32 weights. Population remains Float64. Labels
stay on their original source anchors. Recompute target weights across
shared coordinates after Float32 conversion. Omit the unused all-missing
prominence column; the consumer uses population as its fallback.

The 7,746-row Germany test file is 266,274 bytes. It is a local test file,
not a replacement for the Germany dataset. There are 41 export, writer, and
quality checks. Actual JavaScript decoding is still pending.

Added ten data-query probes. For the Germany sparse test, the 99th percentile
error in distance from London is 0.135 km. Density is preserved to numerical
precision. But synthetic noise has a 0.221 error on a zero-to-one scale.
A synthetic half-missing field loses coverage at two of 571 targets and has
a 0.984 error in log density at the 99th percentile. These probes are not
real travel-time data. The sparse file must be described as an approximation.
Preserved map geometry does not imply exact results for arbitrary queries.

## 11:30 UTC: improve scaling for unequal population

The first planet reduction has valid stage checkpoints, but many India and
Russia blocks fail crossover. Do not accept those solver results. A trial
that clipped negative weights and checked the repaired equations did not
help; it was removed. An unknown solver status is still rejected.

Use population-weighted pivots for the shared equations. Scale each variable
by its supplied weight, then scale each equation by its absolute coefficient
sum. This gives a feasible seed of ones and improves small-tail conditioning.
The dense India test block now falls from 368,914 rows to 22,944. Its first
stage rejected one block; later stages completed without a failed block.
The largest checked moment residual was 9.5e-8. Full-country checks remain
required before export.

Added checked restart from a prior stage. Record its SHA256 in the new run
configuration. This avoids discarding valid reductions when scaling changes.
There are now 26 moment and checkpoint checks, including unequal population,
small weights, restart, and changed-input rejection.

## 11:50 UTC: browser checks and checked country export

Restarted the four largest trials from valid stage files at 11:31 UTC.
The new runs use the committed column scaling. The other-country queue
continues with two workers. The US completed five new stages: 29,878,741
reference rows became 201,231 rows. Maximum target geographic mean error
was 0.095 metres. Maximum source forward mean error was 0.000024 coordinate
units. No failed block was accepted. Other large-country runs are in progress.

Added a manifest-based packer. It checks source and target coverage, source
metadata, all city names, and per-country errors. It records input hashes.
The consumer assigns shared-cell country ownership by row count. Where
necessary, split an existing positive row to preserve the reference owner.
This keeps the same transport, apart from Float32 rounding. Tests cover this
case. There are now 46 export checks and 26 moment checks. A complete Germany
pack test passed, without changing its published dataset.

The actual loaders.gl decoder accepts every narrow column. An isolated
Chromium 153 test renders all 571 Germany target cells and 20 target labels.
H3-MON's normal service remains stopped. The test uses its existing build,
a local HTTP server, a mobile viewport, and software rendering. It is not a
measurement on a phone. One existing SVG legend warning is recorded; the
application's own rendering tests also exclude that warning from failures.

With four-times CPU throttling, the Germany cartogram plus the full-world
density file loaded in 25.5 seconds. After forced collection, the browser
reported 19.1 MB JavaScript heap and 374.9 MB ArrayBuffer/string backing
storage. With only Germany density sources, the same cartogram loaded in
7.0 seconds, with 14.4 MB heap and 75.2 MB backing storage. This isolates a
large cost in the full-world source display and its data processing. It is
not the transport file size. A low-precision flag did not reduce this cost.
These figures exclude some browser and GPU memory. Do not claim that the
current application fits a 100 MB memory budget.

Browser measurement references:

- https://playwright.dev/docs/api/class-cdpsession
- https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-getHeapUsage

## 12:00 UTC: independent binary audit

Added a separate audit of the emitted Arrow file against the full reference.
It checks every source, target, population, city anchor, and country owner.
It also checks source sums, physical target weights, density values, and
projection errors. The writer now removes small source-sum drift before
Float32 conversion. The audit then checks the actual emitted numbers, not
only the solver's Float64 result.

The Germany binary audit passed. Maximum source-sum error was 4.5e-8;
maximum relative target population error was 3.3e-8; maximum geographic
mean error was 0.00074 metres. Added eight audit checks, including deliberate
schema, city-anchor, and density errors. There are now 47 export checks.

Next compare weight floors on the largest original target contributions.
These may improve arbitrary-query accuracy while keeping the file small.
Preserving moments alone does not bound the error of an arbitrary query.

## 12:15 UTC: protect important original contributions

Counted the largest contributions needed for each target. Keeping at least
70% of each target's original population mass needs 616,327 protected rows.
Keeping 50% needs 267,304. A global basic solution with the existing moment
constraints has a theoretical size bound of about 76 MB for the 70% case,
including density. Blocked solves and failed blocks can exceed this bound.
This is not a measured file size.

Added optional lower bounds on these original weights. The original plan
remains a feasible starting point. With unchanged target totals, a protected
fraction of 70% bounds target total variation by 0.3. This bounds the error
of an average of complete, bounded data by 0.3 times its range. It does not
give the same bound after missing-data filtering and renormalization.

Check the bound after each country stage. The independent binary audit now
also measures total variation against the full reference, including duplicate
rows used for country ownership. There are 51 export checks, 33 moment checks,
and 11 audit checks. The new option defaults to zero and does not change the
running moment-only trials. Real-data protected-weight trials are in progress.

## 13:10 UTC: lossless dictionaries and decoder support

Dictionary encoding reduced the Germany test file from 266,274 to 187,162
bytes. Every decoded value is identical. Encode the repeated population,
label, and lower H3-half columns. Keep their logical Float64, string, and
UInt32 types. No Arrow compression codec is required.

The installed loaders.gl wrapper rejects dictionary fields. Apache Arrow
19.0.1 reads them correctly. H3-MON commit `6563a17` uses its public
`tableFromIPC` reader directly and moves that existing package to runtime
dependencies. The normal service remains stopped. No dataset was changed.
The build and 57 unit tests pass. Desktop and mobile dictionary, layout, and
line-probe checks pass. The real Germany file renders 571 targets and 20
labels with no new browser errors.

The full rendering suite has an animation timeout. The same timeout occurs
at unchanged H3-MON commit `84cf3f0` in a separate worktree, with reduction
jobs paused. That worktree was removed. Do not report the full suite as
passing. A separate request-route race in the test was fixed by waiting for
the route handler before fulfilling a request.

The packer now uses dictionary encoding. Its output needs a dictionary-capable
reader, such as the updated H3-MON build. The plain writer remains available.
There are now 54 export checks and 12 independent audit checks.

## 13:10 UTC: enforce large-block time limits

Some native crossover calls exceed their configured time limit by many
minutes. The direct Germany protected-weight test hit its external timeout;
no result was accepted. The full-country blocked trials remain valid at
saved stages. Large blocks need a process boundary, not only a solver option.

Added a reusable local worker for blocks with more than 12,000 rows. It gets
only the block's coordinates, weights, and indexes. A wall-clock timeout
kills the worker and retains the valid input block. It then starts a fresh
worker for the next large block. Save failed requests for diagnosis. Copy
the worker code at run start so later edits cannot change a running trial.

Save a checked whole-country snapshot before long blocks. Processed blocks
use their reduced weights; unprocessed blocks keep their valid input. This
is a complete transport, not a partial fitted map. There are now 44 moment,
worker, deadline, restart, and checkpoint checks. All pass.

## 13:55 UTC: first planet file passes independent checks

The moment-only file has 2,407,520 rows. Transport and density use 67.3 MB
on disk and 29.0 MB with HTTP gzip. All 387,294 sources, 54,942 country
cells, and 1,715 labelled sources remain. The independent binary-file audit
passes. Maximum geographic mean error is 0.261 m. Maximum source sum error
is 5.03e-8. This is not yet the selected public file: maximum conditional
weight variation is 0.988. Means can be accurate while other queries change.
The protected 70% trials continue. China and the US have finished.

The first binary audit rejected tiny Float32 tails. Remove an unlabelled
row only when both its source and target fractions are below 1e-20. Keep
all city anchors. The new file passes the original audit limits. There are
61 export checks, 44 moment and worker checks, and 12 audit checks.

The actual browser renders all 54,931 distinct target positions and 1,711
city labels. HTTP resource measurements confirm gzip decoding. Load time
is 27.3 seconds with desktop Chromium at four-times CPU slowdown, while
reduction jobs run. This is not a phone benchmark. After garbage collection,
JavaScript heap and backing buffers still use about 638 MB. File reduction
alone does not establish mobile memory safety.

H3-MON commit `00c9a85` adds streaming HTTP gzip for Arrow responses. All
61 unit checks pass. Its normal service remains stopped. No dataset in its
public data directory has changed. The animation test limitation still
applies. Keep the new candidate in research output until quality selection
and publication checks are complete.

## 14:05 UTC: reduce browser allocations without changing data

H3-MON now disables spare Deck attribute capacity and the released-buffer
pool (`61acf4f`). It uses exact 52-bit keys under a 12-bit prefix for split
H3 lookup (`b60b39e`). All 64 input bits remain distinct. Cartogram row
indexes now share one Uint32 buffer. Numeric weights use their existing
Float32 or Float64 buffer, and decoded dictionary H3 words use Uint32
storage (`978b389`). No map values or transport weights change.

With the same whole-planet candidate, forced-GC JavaScript heap fell from
172.4 to 120.5 MB. Backing storage fell from 465.4 to 367.7 MB. The total
is about 488 MB, excluding embedder and GPU memory. This is still too large
for a strict 100 MB memory budget. The geographic layer still builds full
world geometry. Load times in these trials range from 25.4 to 27.7 seconds.
Do not infer a speed gain from concurrent desktop trials.

All 64 H3-MON unit checks pass. The isolated desktop and mobile dictionary,
layout, and line-probe checks pass after each change. The whole-planet
render still has 54,931 targets and 1,711 labels. The normal service remains
off. Public data files remain unchanged.

## 14:10 UTC: compare a stronger contribution floor

Started a separate 80% protected-contribution trial with two workers. It has
a 23:15 UTC queue deadline and a two-hour country limit. Its launcher kills
the entire country process group on timeout. Keep the 70% trial and the
validated moment-only file as fallbacks. Compare actual Arrow bytes and
query errors before selecting the public export.

A 70% India block with fewer than 12,000 rows still spends many minutes in
native crossover. The process boundary now applies above 1,024 rows. Use
the same threshold for working checkpoints. Existing processes keep their
loaded code; do not discard their valid saved stages. All 44 moment and
worker checks pass after this change.

## 14:20 UTC: retain a full reference and bind audit reports to files

Saved hard links to the full published reference in
`output/mobile-export/full-reference/`. Do not edit these files in place.
The original public directory is still unchanged. The hash in the old fit
provenance identifies the input, not the 8 GB transport. A separate SHA256
file now records the actual full transport, density, and input hashes.

New audit reports include SHA256 hashes for all four inputs. Publication can
therefore reject a report for a different file. The audit also checks that
both density H3 halves are UInt32. All 15 audit checks pass.

Stopped the old 70% India process after a long native call. It had no worker
code directory; it predated the bounded worker. Its verified fifth stage
has 480,605 rows. A new bounded run starts from that checkpoint. The other
country queue continues. The new run keeps its input when a block times out.

H3-MON commit `2ab2c30` limits Uint32 dictionary materialization to the actual
UInt32 logical type. The browser test now includes a UInt64 dictionary index
too. Desktop and mobile checks pass without conversion errors.

## 14:25 UTC: prepare checked publication

Added a staging tool that checks the audit hashes, rejects more than 100 MB
for the two Arrow files, and refuses existing output directories. It keeps
fit and reduction diagnostics separate. Its README states the actual fit
pass count, approximation limits, row counts, and reader requirements. It
writes dataset-specific browser metadata and a hash list. The staging and
changed-file and byte-budget rejection tests pass.

The headless check can now use the intended relative dataset URL and its
actual JSON metadata. That path check passes for the moment-only candidate,
with all source cells, physical targets, and displayed labels present. No
small export has been put in the public data directory yet.

## 14:50 UTC: verify fallbacks and reject a weaker moment trial

The fresh moment-only audit passes with file hashes. It took 664 seconds
while other reductions ran. The staging tool also passes on this real planet
candidate. It is staged outside the web root, not published.

The bounded India restart finished. Its complete 70% result has 448,401 rows,
down from 480,605. It keeps the original moment limits. Failed blocks kept
their input. The 80% US result has 409,157 rows and maximum conditional total
variation 0.1942. The two whole-planet queues continue.

Tested a diagnostic with small source-mean intervals instead of equalities.
Direct native crossover aborted; no stage was accepted. Stopped that process
and retained its log. A separate simplex trial completed on Germany, but it
kept 25,356 rows versus 13,598 with the exact method. It also moved source
means by up to 0.060 coordinate units. This is not an improvement. Do not
ship this diagnostic or relax the audit limits.
