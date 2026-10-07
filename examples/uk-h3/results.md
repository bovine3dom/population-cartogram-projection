# UK results and size estimates

## Completed run: H3-7, factor 5

This run used core revision `1f9edbe`, with the UK example changes in this branch.
The user inspected the result in H3-MON and considered it suitable for this trial.
That is a visual check, not a numerical detail-preservation test.

| Measurement | Result |
| --- | ---: |
| Positive H3-7 sources | 48,815 |
| OWID output squares | 11,475 |
| Source population | 66,962,523 |
| Mean people per output square | 5,835.51 |
| Sparse mapping rows | 86,932 |
| Retained population | 99.85145% |
| Time inside `distribute` | 1,364.54 seconds (22 minutes 45 seconds) |
| City-label rows | 251 |

Hardware: Intel HD Graphics P630, legacy Level Zero driver 1.3.30872,
eight Julia threads. Software: Julia 1.12.7, oneAPI 2.7.2,
KernelAbstractions 0.9.44, GPUCompiler 2.6.0, and LLVM.jl 9.13.2.
The driver path was `/usr/lib/libze_intel_gpu_legacy1.so.1`.
The run used a temporary environment under `output/uk-h3-res8/env`.
The maintained example environment is now `examples/uk-h3`.

The measured time includes work inside `distribute`, including sparse extraction
and any compilation during that call. It excludes package loading, data preparation,
CSV and Arrow export, and rendering. It is one run, not a benchmark median.
The solver did not record the chosen eta or iteration count for this run.

Local results are under `output/uk-h3-res7/factor5/`.
The source extract is `output/uk-h3-res7/country-826-res7.arrow`.
Copies of both H3-MON Arrow files are under
`~/projects/H3-MON/www/data/uk-h3-7-factor5/`.
Generated data and temporary launch scripts are not part of the package.

## Choosing a subdivision

H3 resolution controls source detail. Subdivision controls output detail.
There is no fixed resolution-to-subdivision rule.
The UK OWID outline contains 459 squares, so factor `f` gives `459 × f²` squares.

Earlier visual experience suggested H3-6 with factor 2 was adequate.
One H3 resolution step increases the global cell count by about seven.
Preserving that theoretical ratio gives `2 × sqrt(7) ≈ 5.3` for H3-7 and
`2 × sqrt(49) = 14` for H3-8. This explains the factor-5 trial and factor-14 estimate.
It does not establish a required output resolution.

In this UK extract, the populated source count increases from 48,815 at H3-7
to 219,045 at H3-8: only 4.49 times as many sources.
Preserving the completed trial's source-to-output ratio gives
`5 × sqrt(219045 / 48815) ≈ 10.6`. Thus factor 11 is a smaller H3-8 trial.
Population weighting prevents a direct match between one H3 cell and one output
square. Rural cells can share a square; dense urban cells can span several squares.

## H3-8 runtime estimates — not measured

Use pair count as a rough scaling rule:

```text
estimated time = 1364.54 seconds ×
                 (new source count × new target count) / (48815 × 11475)
```

| Input and subdivision | Sources | Output squares | Relative pair count | Time |
| --- | ---: | ---: | ---: | ---: |
| H3-7, 5×5 | 48,815 | 11,475 | 1.00 | 22m45s, measured |
| H3-8, 11×11 | 219,045 | 55,539 | 21.72 | 8.2 hours, estimated |
| H3-8, 14×14 | 219,045 | 89,964 | 35.18 | 13.3 hours, estimated |

These estimates assume similar iteration counts and device efficiency.
Convergence, eta selection, truncation, and host-side sorting can change runtime
substantially. Matrix-free storage avoids the full cost matrix; it does not remove
all-pairs work. Neither H3-8 configuration in this table has been run.
The earlier H3-8/factor-3 run was stopped; it has no completed result.

Recommendation: try H3-8/factor-11 before factor 14. Compare urban detail, retained
population, and runtime. Neither factor is a proven quality threshold.

## Historical timings

- `8053fbf:readme.md` records about 1.2 seconds for a warmed UK H3-6 fit on a
  GTX 1080 Ti. It used 8,346 sources, 459 targets, and an older dense solver.
  It is not a runtime estimate for the current Intel run.
- `82585bc:benchmark/results.md` and the current
  [oneAPI benchmark](../../benchmark/results.md) record fixed-work France tests.
  Those short, mostly unconverged solves measure throughput, not a complete fit.

## Input provenance

The Kontur file is `~/projects/gtfs_ffs/data/kontur_h3.arrow`.
Its dataset date has not been verified. Country selection used the repository's
Natural Earth GeoJSON at H3-8, then summed selected children into H3-7 parents.
This differs from the missing legacy country-boundary Arrow file and its modal
country assignment. The old H3-6 total of 66,956,569 is not a regression oracle.

GeoNames `cities15000.zip` contained an entry dated 2026-10-07.
There were 253 UK cities above 50,000 people. All matched a populated source;
combined names in shared H3 cells produced 251 label rows.
The JavaScript Arrow and H3 readers used by H3-MON accepted both exported files.
Checks covered UInt32 halves, H3-7 validity, source coverage, and target weight sums.

SHA-256 checksums:

```text
c21eaf6c3eb65563e80f2055347ad13f979014a190f8472817c25a591f427eb3  kontur_h3.arrow
13c0aa23f535f8e4ec0ff52956d69f761933413b4fb7aa4a311c5f492256441b  ne_10m_admin_0_map_units.geojson
a08f41f7b3f8912e3956c8882a255a0e6ea60b5a720216a0746416ba5d62c257  cartogram.csv
865724f89e3274c5172df2f6068596dfb25bb604737ac2711b5ca6d31aebbf32  cities15000.zip
48a5dc772844b0175fc8af2a3b27bd75986d8af80fb6e2c0eb787cb0b8b67956  country-826-res7.arrow
```

Arrow writer versions and column order can change file checksums without changing
source values. Compare tables by H3 id when checking a new extract.
