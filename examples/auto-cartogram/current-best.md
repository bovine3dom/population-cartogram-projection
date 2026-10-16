# Current best layout

The user selected the coarse 90% Kontur planet layout as the current best.

- [World image](http://proto.olie.science:8642/results/geography/planet-kontur-coarse90/review.png)
- [Review and data](http://proto.olie.science:8642/results/geography/planet-kontur-coarse90/index.html)
- Run: `output/auto-cartogram/planet-kontur-coarse90/`.
- Archive: `results/geography/planet-kontur-coarse90/cells.csv.gz`.
- Land: 55,000 tiles, with exact budgets for 481 connected components.
- Lakes: 45 named lakes, with 220 empty cells.

## Known defects

- The 178-tile Malaysian peninsula is detached from Thailand.
- Lithuania has no exterior-water edge.
- Paraguay has a false coast, with 16 exterior-water edges.
- Sweden has a false direct contact with Germany. Norway does not have that
  contact in this layout.
- The layout has 73 missing and 48 false administrative contacts in total.

This selection is the development baseline. It does not change the deployed
H3-MON mapping. Keep the saved layout unchanged while testing early border cuts.
