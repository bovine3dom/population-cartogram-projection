# Mobile export results

Status: 2026-10-13 17:48 UTC. Work continues until 2026-10-14 01:45 UTC.

## Published experiment

The small export is at:

`/home/olie/projects/H3-MON/www/data/planet-h3-5-factor1-continuity/`

Open `/?data=planet-h3-5-factor1-continuity/population_density_hilo.arrow`
after starting H3-MON. The normal H3-MON service remains stopped during this
work. Production, UK, and Germany datasets are unchanged.

| Measure | Full reference | Published 70% profile |
|---|---:|---:|
| Transport rows | 120,753,287 | 2,909,590 |
| Transport Arrow bytes | 8,241,430,130 | 73,685,018 |
| Density Arrow bytes | 6,197,474 | 6,197,474 |
| Both Arrow files | 8,247.6 MB | **79.9 MB** |
| Both files with gzip | Not measured | **33.7 MB** |

MB means 1,000,000 bytes. The combined raw files are about 103 times smaller.
The gzip measurement uses level 6 and includes both files. The headless
browser confirms the encoded and decoded transfer sizes.

The full reference remains outside the web root in
`output/mobile-export/full-reference/`. Its transport SHA256 is
`25799bae61ce4aeaf8d52fac45463c92aaaa2f3f1fb62b30ea77dd9722ecde47`.

## What changed

Row culling alone caused large geographic errors. The selected method also
adjusts the retained positive weights. It preserves masses, geographic
means, source mean target positions, and mean population density. It keeps
large original contributions that cover at least 70% of each target mass.
This limits changes to the conditional distribution at each target.

The file uses smaller numeric types and lossless Arrow dictionaries. It keeps
Float64 population values and UInt32 H3 halves. All 387,294 sources, 54,942
country target cells, and 1,715 labelled sources remain. The browser displays
54,931 distinct target positions and 1,711 city labels.

The binary-file audit reports:

- Maximum source sum error: 5.22e-8.
- Maximum target mass relative error: 3.54e-7.
- Maximum geographic mean error: 0.184 m.
- Maximum source mean target error: 1.39e-5 coordinate units.
- Maximum conditional total variation: 0.29494, below the 0.30 limit.

This is an approximate export, not a new fit. The source fit completed four
passes. It still has large border defects. Fit diagnostics describe the full
fitted plan, not the reduced coupling.

## Query limits

Mean preservation does not make all queries exact. The independent audit
checks test fields on the actual Arrow files at physical target positions.

| Test field | Absolute P99 error |
|---|---:|
| Distance from London | 0.137 km |
| Distance from New York | 0.707 km |
| Synthetic noise on a 0–1 range | 0.0627 |
| Log density with half the sources missing | 0.515 |

Distance tests are geographic distances, not travel times. The half-missing
test loses 87 of 54,421 originally covered target values. Its maximum error
is much larger than its P99 error. Do not assume that partial-data queries
keep their coverage or have the same bound as complete-data queries.

## Browser memory and tests

The updated H3-MON reader supports Arrow dictionaries. An optional geometry
mode builds geographic polygons for the visible region after movement. It
does not remove source data or cartogram rows. Dataset metadata enables it
for this experiment; its default remains off for other datasets.

Packed source navigation indexes reduce per-source JavaScript objects.
The bundle also shares one H3 runtime instead of two. Initial JavaScript heap
plus backing storage is about 242 MB, versus 508 MB before these changes and
visible-region geometry. A world view still uses about 413 MB. Returning to
the initial view uses about 278 MB. The largest sampled initial-load value
is 313 MB; sampling can miss short peaks.
These measurements exclude embedder and GPU memory. They are from headless
desktop Chromium, not a phone. This is not a 100 MB browser-memory solution.

All current export, moment, audit, and publication checks pass. All 69 H3-MON
unit tests and isolated desktop/mobile dictionary, viewport, and line-probe
checks pass. The full rendering suite has a separate animation timeout that
also occurs on the unchanged baseline. Do not report that suite as passing.

See [the work log](mobile-export-work-log.md) for trial details and commits.
See [the export instructions](../examples/continuity/mobile/readme.md) to
reproduce the reduction, audit, and browser checks.
