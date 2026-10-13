# Mobile export results

Status: 2026-10-13 21:28 UTC. Work continues until 2026-10-14 01:45 UTC.

## Published experiment

The selected export is at:

`/home/olie/projects/H3-MON/www/data/planet-h3-5-factor1-continuity/`

Open `/?data=planet-h3-5-factor1-continuity/population_density_hilo.arrow`
after starting H3-MON. Its normal service remains stopped during this work.
Production, UK, and Germany datasets are unchanged.

| Measure | Full reference | Published 70% profile |
|---|---:|---:|
| Transport rows | 120,753,287 | 2,392,689 |
| Transport Arrow bytes | 8,241,430,130 | 60,697,906 |
| Density Arrow bytes | 6,197,474 | 5,035,946 |
| Both Arrow files | 8,247.6 MB | **65.7 MB** |
| Both files with gzip | Not measured | **26.0 MB** |

MB means 1,000,000 bytes. The combined raw files are about 125 times smaller.
The gzip measurement uses level 6 and includes both files. The headless
browser confirms the encoded and decoded transfer sizes. The 80% profile
passed its audit but exceeded the 100 MB raw limit. It was not published.

The full reference remains outside the web root in
`output/mobile-export/full-reference/`. Its transport SHA256 is
`25799bae61ce4aeaf8d52fac45463c92aaaa2f3f1fb62b30ea77dd9722ecde47`.

## What changed

Row culling alone caused large geographic errors. The selected method also
adjusts the retained positive weights. It preserves masses, geographic
means, source mean target positions, and mean population density. It keeps
large original contributions that cover at least 70% of each target mass.
This limits changes to the conditional distribution at each target.

Bounded block solves reduce the weights. Later passes hold protected
contributions fixed and change block boundaries and order. Failed blocks
keep their valid inputs. The final manifest uses complete country stages.
One India trial reached its time limit; its last complete stage passed all
checks and was used. This is not a partial country export.

The files use smaller numeric types and lossless Arrow dictionaries. They
keep Float64 population values and UInt32 H3 halves. Row order also reduces
gzip bytes without changing weights. All 387,294 sources, 54,942 country
target cells, and 1,715 labelled sources remain. The browser displays 54,931
distinct target positions and the same 1,711 city labels.

The binary-file audit reports:

- Maximum source sum error: 4.89e-8.
- Maximum target mass relative error: 3.52e-7.
- Maximum geographic mean error: 0.184 m.
- Maximum source mean target error: 1.47e-5 coordinate units.
- Maximum conditional total variation: 0.29495, below the 0.30 limit.

This is an approximate export, not a new fit. The source fit completed four
passes. It still has large border defects. Fit diagnostics describe the full
fitted plan, not the reduced coupling.

## Query limits

Mean preservation does not make all queries exact. The independent audit
checks test fields on the actual Arrow files at physical target positions.

| Test field | Absolute P99 error |
|---|---:|
| Distance from London | 0.170 km |
| Distance from Delhi | 0.537 km |
| Distance from New York | 0.758 km |
| Synthetic noise on a 0–1 range | 0.0665 |
| Log density with half the sources missing | 0.578 |

Distance tests are geographic distances, not travel times. The half-missing
test loses 90 of 54,421 originally covered target values. Its maximum error
is 6.37 log-density units. Do not assume that partial-data queries keep their
coverage or have the same bound as complete-data queries. See the published
`query-errors.csv` for all test fields, including maximum errors.

## Browser memory and tests

The updated H3-MON reader supports Arrow dictionaries. An optional geometry
mode builds geographic polygons for the visible region after movement. It
does not remove source data or cartogram rows. Dataset metadata enables it
for this experiment; its default remains off for other datasets.

Packed source indexes reduce per-source JavaScript objects. The bundle
shares one H3 runtime instead of two. It also releases unused Arrow columns
after navigation and cell metadata are built. For the selected profile,
JavaScript heap plus backing storage after forced garbage collection is
about **191 MB** initially, **362 MB** in a world view, and **227 MB** after
returning. The largest sampled initial-load value is **279 MB**. Sampling
can miss short peaks. Copying retained columns briefly holds both buffers.

These measurements exclude embedder and GPU memory. They are from headless
desktop Chromium, not a phone. This is not a 100 MB browser-memory solution.

All current export, moment, audit, and publication checks pass. All 71 H3-MON
unit tests and isolated desktop/mobile dictionary, viewport, and line-probe
checks pass. The full rendering suite has a separate animation timeout that
also occurs on the unchanged baseline. Do not report that suite as passing.

See [the work log](mobile-export-work-log.md) for trial details and commits.
See [the export instructions](../examples/continuity/mobile/readme.md) to
reproduce the reduction, audit, and browser checks.
