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

## 15:45 UTC: validate the 70% planet and reduce visible geometry

All 206 countries have a checked 70% result. The binary-file audit passes:
2,909,590 rows, 79,882,492 bytes for both Arrow files, and 33,669,469 bytes
for both gzip files. Maximum conditional total variation is 0.29494, below
the 0.30 limit. Maximum geographic mean error is 0.184 m. All sources,
country cells, city anchors, and shared-cell owners pass the checks.

H3-MON `fe5b200` adds an optional visible-region geometry mode. It retains
all source values and all cartogram rows. It uses polygon bounds with the
renderer’s longitude unwrap, and includes edge intersections and padding.
It rebuilds after movement or resize. A new layer releases old view buffers.
The mode is off by default; experimental dataset metadata can enable it.

The 70% candidate uses 342 MB of JavaScript heap plus backing storage in
the initial regional view, versus 508 MB without this mode. A world view
still uses about 514 MB. Returning from the world view uses about 379 MB.
These values exclude embedder and GPU memory. Do not call this a 100 MB
memory solution. The headless world/date-line/return test passes and keeps
all 387,294 sources. Paired moment-only screenshots differ at only 100 of
1,316,640 pixels, by one channel unit at most. All 66 unit tests and the
isolated desktop/mobile rendering checks pass. The full-suite animation
failure remains a separate known limitation.

The first stress test found that a resize during data loading could leave
extra off-screen polygons. Refresh geometry after the data update finishes.
The corrected stress test restores the same 8,169 regional polygons.

The audit now computes global query probes directly from both Arrow files,
including physical cells shared by countries. Keep the packer’s per-country,
pre-serialization probes as a separate file. New reports bind the query CSV
with a hash. There are now 17 audit checks; all pass. The 61 export checks
and publication tests also pass. A fresh 70% binary query audit is running.

The 80% China result has 1,552,934 rows, including 683,502 protected rows.
Started larger-block refinements for China and the US from valid 80% seeds.
Each process has an 8 GiB address-space limit and a three-hour deadline.
Each native block has a 200-second wall-clock limit. Keep the 70% candidate
as a validated fallback if stronger protection exceeds the byte budget.

## 16:00 UTC: check missing-data limits and compress density losslessly

The independent 70% query audit passes. Across physical target cells, the
synthetic noise test has absolute P99 error 0.0627 on a 0–1 range. Distance
P99 errors range from 0.088 to 0.707 km for the five test cities. These are
geographic distances, not travel times.

The actual binary half-missing test loses 87 of 54,421 originally covered
target values. The checkpoint probe had reported 20 losses. Float32 tail
removal explains why the binary check is necessary: even negligible mass
can become important after missing-data renormalization. The published
README will state the measured loss count. Do not claim coverage for every
partial-data query. Complete density coverage and all source coverage still
pass the independent checks.

The density file has only four distinct lower H3 words. A lossless Arrow
dictionary reduces it from 6,197,474 to 5,035,946 bytes. Every value and H3
half matches the full file exactly. Its gzip size is 3,628,761 bytes. The
actual browser reads it correctly. New packs use this encoding. There are
67 export checks and 18 audit checks; all pass.

Also started a 75% China trial from the valid 80% seed. This is a possible
middle profile if the 80% planet exceeds 100 MB. It has the same exact moment
checks, an 8 GiB address-space limit, and a three-hour deadline. No small
candidate has replaced the public experiment yet.

## 16:05 UTC: publish the validated 70% profile

Replaced only the experimental directory:
`/home/olie/projects/H3-MON/www/data/planet-h3-5-factor1-continuity/`.
It now contains the 79.9 MB pair, the binary query audit, fit and reduction
diagnostics, a clear README, and dataset-specific browser metadata. This
profile still has the original lossless density file; later packs use the
smaller dictionary density file.

Checked all staged file hashes and ran the actual metadata URL with the
headless world/date-line/return test before moving the directory. All checks
pass. Kept the former public directory in
`output/mobile-export/former-public-full/`. The immutable full reference
also remains at `output/mobile-export/full-reference/`. These use hard links
for the large original files. Do not edit them in place.

The production input hash is unchanged. No normal H3-MON service is running.
No production, UK, or Germany dataset was replaced. The stronger 80% and
mixed 75% trials continue within their deadlines. Keep this checked public
profile unless a stronger result meets the byte and quality limits.

## 16:53 UTC: packed browser indexes and stronger-profile limits

H3-MON commit `15a2fae` stores source navigation bounds and adjacency in
shared typed buffers. An independent comparison checks all 387,294 source
bounds, all transport adjacency entries, and four nearest-point queries.
No source or transport row is removed. Initial browser heap and backing
storage fall from 342 MB to 285 MB. A world view uses 456 MB; the return
view uses 322 MB. These figures still exclude embedder and GPU memory.
All 68 unit checks pass. The isolated rendering checks pass. The full
rendering suite still has the same baseline animation timeout.

The 80% profile has completed all countries. Its first pack uses 114.7 MB
for both files, which exceeds the publication limit. Its independent audit
continues. Larger blocks remove only 14,331 further China rows and no US
rows. A China native factorization exceeds the 8 GiB worker address-space
limit. Failed blocks retain their valid inputs. A 75% China trial ends at
1,443,700 rows, only a small reduction from its 80% seed.

A diagnostic objective that favours already-protected rows times out on a
Germany block. No new result is accepted and no solver option is shipped.
A separate bounded primal-simplex diagnostic is in progress. Keep the
validated 70% public export while these tests run.

## 17:05 UTC: remove a second H3 heap

A browser heap snapshot found two 32 MiB H3 runtimes. Deck loaded H3 4.1,
while the application loaded H3 4.4. Both dependency ranges permit 4.4.
H3-MON commit `8a55410` makes the bundler resolve both imports to the root
package. No installed package is changed. Initial heap and backing storage
now use 251 MB; the world view uses 422 MB; the return view uses 288 MB.
The initial screenshot is pixel-identical to the previous build. All 68
unit checks and the isolated desktop/mobile rendering checks pass.
Commit `934f563` also checks an empty viewport and return navigation.

The esbuild alias rules were checked at https://esbuild.github.io/api/#alias.
The 80% binary audit passes, but its 114.7 MB raw size remains over budget.
A ten-minute primal-simplex trial still has no feasible solver result. It
is rejected. A separate trial holds protected contributions fixed and solves
only their residual weights. It removes 44,177 further China rows in small
blocks without changing the validation limits. Larger China and India trials
are in progress. This residual method is not yet in the committed exporter.

## 17:41 UTC: lossless row order for smaller transfers

Sorting transport rows by source reduces gzip size. A pure source sort
would change the browser's first-source navigation anchors. Instead, keep
the first row of each target in a prefix, then sort the remaining rows.
An independent comparison confirms that all 2,909,590 rows and all 54,931
navigation anchors are unchanged. All 1,711 displayed city labels are also
unchanged. The writer's 68 checks and the headless world/date-line/return
check pass.

With dictionary density, this candidate uses 78.7 MB raw and 30.6 MB gzip,
versus 79.9 MB and 33.7 MB for the current public files. The difference is
lossless. The smaller gzip transport is 26,965,999 bytes. A target-first
sort was worse at 31,618,870 bytes, so it is not used. Keep the current
public files until the final candidate has a fresh complete binary audit.

## 17:44 UTC: checked residual-weight reduction

The fixed-contribution trial reduces China from 643,399 to 544,025 rows.
India falls from 448,401 to 421,544 rows. Larger blocks still time out and
keep their valid inputs. The full-country checks pass with the original
70% variation bound. These checkpoints are not yet published.

Added `fixed_floors=true` as an optional refinement. The default method is
unchanged. It subtracts the protected contribution, reduces the nonnegative
remaining weights, and adds the protected contribution back. City anchors
are held separately too. Solver failure, worker deadlines, and full-country
checks still apply. All 60 moment, worker, floor, and restart checks pass.

## 17:48 UTC: bounded refinement queue and narrow browser bounds

Started a two-worker fixed-contribution queue from the checked 70% stages.
It uses a frozen copy of commit `94107d3`, a 30-minute country limit, a
12 GiB process address-space limit, and a 23:00 UTC queue deadline. It kills
the whole country process group on timeout. China starts from its smaller
checked diagnostic stage. India's large diagnostic run was still active,
so India starts from its original checked 70% stage. Countries with fewer
than 1,000 rows are not rerun. Keep completed stages; do not use an incomplete file.

H3-MON commit `73852ac` keeps Int16 navigation bounds in Int16 storage.
Other coordinate types still use Float64 bounds. No coordinate changes.
Initial browser heap and backing storage use 242 MB; the world view uses
413 MB; the return view uses 278 MB. The largest sampled initial-load value
is 313 MB. Sampling is not a proof of the true peak. All 69 unit checks and
the isolated desktop/mobile rendering checks pass.

## 18:33 UTC: check the refinement result before replacement

The fixed-contribution queue has completed its largest countries without a
country timeout. Its China result has 544,025 rows; India has 421,545. The
US is unchanged. A new manifest will use a refined stage only when it has
fewer rows than the original checked stage. The pack, full binary audit,
and browser checks will then run automatically, but publication will not.

Started separate China and India diagnostics with shifted block boundaries.
These can combine rows across the old block cuts without larger matrices.
Each diagnostic has a 90-minute process-group deadline and the same weight
and geometry checks. No shifted-block option has been added to the exporter.

## 19:17 UTC: smaller checked profile and shifted blocks

The fixed-contribution queue is complete. A manifest selects smaller stages
for 21 countries and keeps the other checked results. The new pack has
2,723,935 rows and uses 74.1 MB for both files. Its full binary audit and
headless world/date-line/return checks pass. Maximum geographic mean error
is 0.184 m. The synthetic noise P99 error is 0.0642. The half-missing probe
loses 89 target values, versus 87 in the current public profile. This is
still an approximation. The public files have not yet changed again.

Shifted-block diagnostics reduce China further to 520,389 rows and India
to 375,846. Their full-country checks pass with the same 70% bound. Added
`block_shift` with a zero default. It rotates only the block assignment,
not the coordinates or constraints. All 65 moment, worker, floor, shift,
and restart checks pass. Further trials will use the committed option.

## 20:36 UTC: 69.7 MB candidate and release of decoded buffers

The shifted-block queue completed all 27 selected countries without a country
timeout. The checked pack has 2,552,293 rows and uses 69.7 MB raw or 27.4 MB
gzip for both files. Its independent binary audit passes. Geographic mean
error remains below 0.185 m. Synthetic noise P99 error is 0.0654; the
half-missing probe loses 89 values. The public files still use the earlier
79.9 MB profile.

H3-MON commit `2451b73` copies the retained numeric join columns after cell
metadata and navigation are built. This releases the larger original Arrow
buffer. Strings and object-array inputs keep the old path. For the unchanged
public profile, retained heap and backing storage fall from 242 MB to 203 MB.
The world view uses 374 MB; the return view uses 239 MB. The largest sampled
initial-load value is 318 MB, slightly higher than the previous trial.
This reduces retained memory, not the transient copy cost. All 71 unit tests
and isolated rendering checks pass. The full rendering run still reports
only the known baseline Frame 2 timeout.

A different block order reduces China to 491,040 rows and India to 314,102.
It orders sources by latitude and targets by Y, with unchanged constraints.
Added the optional `block_order=:latitude` mode after this checked result.
All 70 moment, worker, floor, order, and restart checks pass. The next queue
will test this order on the larger countries before the final selection.

## 20:39 UTC: final bounded order trial

Started the latitude-order queue from commit `be3dcbc`. It has two workers,
a 20-minute country limit, a 12 GiB process address-space limit, and a
23:00 UTC deadline. It uses only countries with at least 15,000 rows.
China and India start from their checked latitude diagnostic stages.
All other countries start from the checked 69.7 MB profile's manifest.

The final manifest will select the smallest complete stage for each country.
It will then run the full pack, binary audit, gzip, and headless checks.
No job can publish automatically. The 69.7 MB candidate and the public
79.9 MB profile remain checked fallbacks.

## 21:27 UTC: publish the selected 65.7 MB profile

The latitude queue is complete. It ran 27 countries. India reached its
20-minute country limit and its process group was stopped. The final
manifest uses India's last complete, checked stage, not its unfinished
block. The other 26 runs completed. The pack, full binary audit, gzip, and
headless checks all pass.

The selected transport has 2,392,689 rows and uses 60,697,906 bytes. Density
uses 5,035,946 bytes. Together they use 65,733,852 bytes raw and 26,028,735
bytes with gzip. Maximum geographic mean error is 0.184079 m. The full audit
retains the 70% guarantee. The half-missing test loses 90 of 54,421 originally
covered target values. All 1,711 displayed city names are independently
checked against the earlier public profile and are unchanged.

Verified all 22 staged file hashes. Tested the actual dataset metadata URL
with world/date-line/return navigation. Then replaced only the experimental
public directory. Saved the earlier 79.9 MB directory at
`output/mobile-export/former-public-protected-07/`. The full original
reference and its separate backup remain unchanged. The production input
SHA256 is still `af126bbd70747c95d2921f5d63a81fed4b5f9aebde98e3b12db7628d40a49249`.
H3-MON remains stopped. No production, UK, or Germany dataset was replaced.

The selected profile uses about 191 MB heap and backing storage after
collection, 362 MB in the world view, and 227 MB after return. The largest
sampled initial-load value is 279 MB. These are desktop headless measures,
not phone limits. The remaining window is for verification and cleanup.


## 22:16 UTC: browser heap checks and direct dictionary decode

H3-MON commit `373cb8e` builds navigation bounds directly in typed buffers.
It avoids six growing object arrays. Independent checks compare all
2,392,689 adjacency entries, 387,294 bounds, and four nearest-cell queries
with the earlier implementation. Three earlier paired browser checks reduced
sampled initial peaks from 289–378 MB to 261–262 MB. Retained memory did not
change. These peaks depend on collection timing.

A separate 64 MiB V8 heap test found an out-of-memory failure in dictionary
H3 decoding. The old path first built a full JavaScript array, then copied it
into a typed array. A direct scalar decoder passed the limited-heap test.
The final decoder instead reads Arrow chunk indexes and their dictionaries.
It keeps dictionary validity, sliced indexes, replacement dictionaries, and
UInt64 fallback behavior. It does not create the full temporary object array.

H3-MON commit `a0803ce` contains the decoder and tests. All 74 unit checks,
actual Arrow 19 chunk tests, and isolated desktop/mobile rendering checks
pass. Every H3 half in both public files matches the original reader exactly.
Commit `301e084` fixes a test race: a replacement viewport layer can exist
before its geometry state is ready.

The final reader passes world/date-line/return navigation with the confirmed
67,108,864-byte V8 heap limit. The reusable browser check now supports
`JS_HEAP_MB`. This is not a total memory limit. The capped run still uses
about 191 MB heap plus backing storage after collection, and samples a
196 MB initial peak. Default-heap runs sample 305–315 MB initial peaks.
Their load times range from 23.2 to 34.3 seconds. Lower-word decoding itself
uses 36–61 ms, versus 1.8–2.4 seconds in two new old-reader checks. Other
local jobs were active. Do not infer a precise end-to-end speed gain from
these runs. The earlier scalar-decoder timing difference was not enough to
establish a regression.

Logs are in `output/mobile-export/browser-chunk-dictionary-*`,
`browser-dictionary-baseline-*`, `browser-final-heap64`, and
`h3mon-chunk-dictionary-*`. The published dataset is unchanged. No normal
H3-MON service was started. Unrelated auto-cartogram jobs belong to other
work and were not stopped.


## 23:50 UTC: repeat the public audit and test repeated navigation

The final regression run passes 68 export checks, 70 moment checks, 18
independent audit checks, and the publication test. A new full binary audit
reads the public files against the 8.24 GB reference. Its report matches the
previous audit exactly. All 22 public manifest hashes and both decompressed
gzip payload hashes match. The production input hash is unchanged.

The full H3-MON rendering run still fails only at the known desktop Frame 2
animation wait on line 998. It is not a passing suite. The isolated
mobile/desktop dictionary, viewport, and line-probe checks remain passing.

A 90-movement capped-heap check passes. A subsequent 600-movement check
also passes, with all source cells and return-view coverage unchanged.
The latter takes about 67 minutes with 4× CPU throttling and the confirmed
64 MiB V8 heap limit. Each cycle shows the world, the date line, and the
initial region. It collects garbage after each movement. World-view heap
plus backing storage ranges from 362.0 to 364.2 MB. Return-view memory
ranges from 227.4 to 229.2 MB. Small growth remains; these results do not
prove a fixed memory bound. Inspector logs and measurement records are also
retained during the test.

Logs are `final-test-*`, `audit-public-final.toml`, `final-public-hashes.log`,
`h3mon-final-full-render.log`, `browser-soak-final/`, and `browser-soak-long/`
in `output/mobile-export/`. All these jobs have stopped. The normal H3-MON
service is still stopped. No further dataset reduction is planned in the
remaining window; the checked public 65.7 MB profile remains selected.


## 2026-10-14 01:06 UTC: reproduce the long browser check

Added `VIEWPORT_CYCLES` to the reusable browser check. This removes the need
for a separate copy of the script. Its default remains one cycle. Repeated
the full 200-cycle, 600-movement test with the new option and a 64 MiB V8
heap limit. All checks pass again. World-view heap plus backing storage is
362.0–364.2 MB; return-view memory is 227.2–229.3 MB. Cell counts are
unchanged in every movement. Logs are in `browser-soak-reproducible/`.

The public files have not changed. All long tests have stopped. The rest of
the window is reserved for final hashes, repository checks, and cleanup.
