# Larger missing scopes in the OWID export

Audit date: 2026-10-18 UTC. No layout or population assignment changed.

## Conclusion

The evidence indicates that all three large scopes are already included in
OWID's population budgets:

| Missing source scope | OWID budget that includes it | Existing tiles | Evidence |
| --- | --- | ---: | --- |
| Kosovo (`KOS`) | Serbia (`SRB`, 688) | 55 | The matching UN population revision explicitly includes Kosovo in Serbia. |
| Somaliland (`SOL`) | Somalia (`SOM`, 706) | 117 | The UN Somalia population scope covers the whole country, including the northern regions. |
| Northern Cyprus (`CYN`) | Cyprus (`CYP`, 196) | 8 | The UN table specifies the whole country. IOM also specifies the whole island for UN population data. |

Do not add their populations or tile quotas on top of these existing budgets.
If they receive separate labels, divide the existing combined budgets.

## Export provenance

`data/citation.md` cites the 2018 OWID article. But `data/readme.md` identifies
the actual export settings: the interactive OWID cartogram app, fluid scale,
year 2026, radius 1, square cells.

The app loads `data/population/unpd-flat.csv`. In `core/plot.js`, it selects the
population row by the polygon's numeric country ID and uses the selected year.
The inspected upstream revision is
`7fca238522ee065aa0406530ccc20e8c5481c39c`.

These are the app's stored values, not current 2026 population estimates:

| OWID row | Stored 2018 population | Stored 2026 projection |
| --- | ---: | ---: |
| Serbia, 688 | 8,802,741 | 8,455,287 |
| Somalia, 706 | 15,008,225 | 18,914,825 |
| Cyprus, 196 | 1,189,262 | 1,251,215 |

The historical values agree with the 2019 UN population revision. The app has
no separate population rows for Kosovo, Somaliland, or Northern Cyprus.
The tile export is a rasterized cartogram, not an exact population apportionment.
Tile counts alone are therefore not sufficient evidence of geographic scope.

## External scope checks

### Kosovo

World Population Prospects 2019, Table A.9, labels Serbia with footnote 31.
The footnote states: “Including Kosovo.” Its Serbia totals also match the
app's series at the precision printed in the UN table.

This conclusion applies to this older data series. Do not assume that a newer
UN Serbia series uses the same scope.

### Northern Cyprus

The same table labels Cyprus with footnote 6: “Refers to the whole country.”
The IOM report cited below explicitly states that the UN population data for
Cyprus refer to the whole island. The app's Cyprus series is approximately
1.2 million in 2019, not a separate southern-area series.

Our source data also separate the UN buffer zone (`CNM`) and the eastern and
western sovereign base areas (`ESB`, `WSB`). Those scopes need an explicit
assignment policy. Do not drop them when joining the Cyprus population pool.
Their polygon-assigned counts are not verified administrative population totals.

### Somaliland

The UN Somalia population scope is not restricted to the area outside
Somaliland. The UNFPA Population Estimation Survey 2014 covers the 18 pre-war
regions. Its total includes Awdal, Woqooyi Galbeed, Togdheer, Sanaag, and Sool.
The report gives a combined total of 12,316,895 people for all regions.

This supports inclusion of the north in the UN Somalia population geography.
Unlike Serbia, the inspected WPP table does not attach a specific
“including Somaliland” footnote. The conclusion uses the UN geographic scope
and regional survey coverage, not a claim that the survey and projection
values are identical.

## What our pipeline currently does

The published `source-assignments.csv` assigns these populations:

| Target | Assigned source population | Separate source population omitted |
| --- | ---: | ---: |
| Serbia | 7,220,316 | Kosovo: 1,659,899 |
| Somalia | 13,625,253 | Somaliland: 4,250,437 |
| Cyprus | 798,271 | Northern Cyprus: 334,359 |

The Cyprus buffer-zone and base-area source counts are another 128,598.
Thus the target budgets and the source polygons do not use the same scopes.
The separate scopes appear in `source-scopes-without-tiles.csv`; they are not
silently included in the published assignments.

A division of the existing budgets using the current source shares gives:

- Serbia plus Kosovo: approximately **45 + 10 = 55 tiles**.
- Somalia plus Somaliland: approximately **89 + 28 = 117 tiles**.
- Cyprus: approximately **2 of the existing 8 tiles** for Northern Cyprus.
  The remaining six must also account for the buffer and base-area scopes
  under an explicit policy.

These are trial quotas, not new census estimates. The source assignment and
OWID projections use different data dates and methods.

## Recommended next change

First define a statistical-scope crosswalk. Keep source geometry IDs separate
from the target display label. Then either join the source populations to the
existing label, or divide the existing landmass into separate labels.

For separate labels, update the border graph as well. For example, the
current Serbia–Albania contact would need review when Kosovo gets its own
part. Fit the new internal borders inside the existing combined outline.
No extra world tile budget is needed for these three cases.

The smaller missing territories were not fully audited in this check.
The earlier five-state list described missing entries in our CSV, not an
absence from every version of OWID's original illustration.

## Sources

- [OWID app population table, pinned revision](https://github.com/owid/cartograms/blob/7fca238522ee065aa0406530ccc20e8c5481c39c/data/population/unpd-flat.csv)
- [OWID population selection code, pinned revision](https://github.com/owid/cartograms/blob/7fca238522ee065aa0406530ccc20e8c5481c39c/core/plot.js)
- [UN World Population Prospects 2019, Volume I](https://population.un.org/wpp/assets/Files/WPP2019_Volume-I_Comprehensive-Tables.pdf), Table A.9 and footnotes 6 and 31. PDF text inspected directly.
- [IOM Key Migration Data 2023–2024](https://eca.iom.int/sites/g/files/tmzbdl2626/files/documents/2025-02/key-migration-data-2023-2024-eca_feb2025-1.pdf), endnote 5. PDF text inspected directly.
- [UNFPA Population Estimation Survey 2014](https://somalia.unfpa.org/sites/default/files/pub-pdf/Population-Estimation-Survey-of-Somalia-PESS-2013-2014.pdf), regional population table. PDF text inspected directly.
- [Current source assignments](results/owid-landmass-world/source-assignments.csv)
- [Current unrepresented source scopes](results/owid-landmass-world/source-scopes-without-tiles.csv)
