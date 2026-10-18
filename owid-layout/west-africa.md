# West Africa border experiment

## Purpose

Test changes to mainland borders without changing country tile counts.
The input is the clean OWID layout. The experiment does not change the approved
layout, its source assignments, or H3-MON.

[Open the review images](../examples/auto-cartogram/results/west-africa-refinement/index.html).

The trial contains 3,052 tiles in 15 scopes: Benin, Burkina Faso, Côte d’Ivoire,
Ghana, Guinea, Guinea-Bissau, The Gambia, Liberia, Mali, Mauritania, Niger,
Nigeria, Senegal, Sierra Leone, and Togo.

## Initial audit

The African mainland contains 9,878 land cells and **zero enclosed empty cells**.
The clean build did not add African lakes. Earlier water checks only protected
empty cells already present in the artwork.

Natural Earth supplies the desired neighbour graph. Shared polygon segments
count as geographic borders. Shared tile edges count as artwork borders.
A corner contact is sufficient for country connectivity, but not for a border.

Inside the trial region, the current map has ten extra neighbour pairs and
lacks twelve geographic neighbour pairs. Including contacts with fixed outside
countries, it has eighteen extra pairs and lacks fourteen pairs.

Burkina Faso currently touches Mali, Morocco, Mauritania, Nigeria, and Senegal.
Natural Earth gives it Benin, Côte d’Ivoire, Ghana, Mali, Niger, and Togo.
Only Mali agrees. This is a placement problem, not just a rough-border problem.

## Controls

- Keep all country tile counts exact.
- Keep the regional land mask fixed. Do not add or remove water cells.
- Keep outside countries fixed.
- Require each country to stay connected under the corner-contact rule.
- Derive coast status from the outer source boundary. Interior rings do not
  count as sea. Burkina Faso, Mali, and Niger must stay inland.
- Use Natural Earth, not OWID, to score neighbour relationships.
- Report errors at the fixed regional boundary. Do not treat them as correct.

The fixed regional boundary is a limit of this pilot. For example, it contains
cells against Egypt, but no selected country has a real border with Egypt.
An exact geographic graph for every contact is therefore not possible under
these controls. Internal contacts can change; external errors require a larger
region or a different outer mask.

## Methods

### Border-constrained fits

The shared-outline solver can require the exact internal geographic graph.
A conservative fit uses 25% geographic shape cost and 75% original shape cost.
The stronger fit uses 85% geographic shape cost. A perimeter cost discourages
long borders. The regional footprint does not change.

The narrow conservative candidate set could not supply a Benin–Niger contact.
The narrow geographic candidate set was infeasible. Broader searches did not
produce a validated export before they were stopped. Two penalized searches
were also stopped. These runs took approximately 10–15 minutes each. This is
not proof that an exact internal fit is impossible.

### Local exchanges

Exchange equal numbers of tiles between country pairs. Each accepted exchange
reduces the total cost and preserves counts, connectivity, and coast status.
The cost includes geographic placement, perimeter, unsupported border length,
and missing geographic neighbour pairs. No wrong neighbour pair is protected.

The conservative trial changed 227 cells. Extra internal neighbour pairs fell
from ten to six; missing pairs fell from twelve to nine. Total country perimeter
increased from 996 to 1,062 tile edges.

The stronger trial reduced extra internal pairs to four and missing pairs to
seven. Perimeter increased to 1,188. Visual review showed narrow strips around
existing shapes, rather than a good relocation of Burkina Faso. It also added
an unsupported Nigeria–Egypt contact at the fixed outer boundary. Neither local
trial is a replacement map.

### Whole-region reassignment

A second solver assigns the full region again from geographic costs. It does
not preserve existing borders or require the old country positions. Exact
counts and coast status remain constraints. Disconnected results receive
additional constraints; they are not exported as valid maps.

Shape-based costs did not give a connected result within twenty cut rounds.
The next trial uses squared distance to geographic guide centres. A second
version applies local exchanges after this assignment. Both versions audit
neighbours against Natural Earth; neither assumes that compactness proves
correct geography.

The first centre-based solution left detached coastal cells in Ghana and Benin.
Simple connectivity cuts moved these fragments along the coast without joining
them to the main country. The revised seed selects a root in the largest
candidate component. Selected cells must have a path of decreasing distance
to that root. Togo subsequently needed the same constraint. Roots come from
the new candidate, not from hand-written coordinates. This is a stronger shape
prior than connectivity alone, so the result is not a global optimum over all
connected layouts. Local exchanges can subsequently move these root cells.

## Results and visual review

| Trial | Extra internal pairs | Missing internal pairs | Total perimeter |
| --- | ---: | ---: | ---: |
| Current map | 10 | 12 | 996 |
| Geographic local exchanges | 4 | 7 | 1,188 |
| Geographic centres | 10 | 9 | 1,078 |
| Centres plus strong border score | 3 | 2 | 1,226 |
| Centres plus stronger perimeter score | 10 | 7 | 1,082 |

All exported trials retain exact country counts, connectivity, and coast status.
Perimeter is the sum of country boundary lengths in tile-edge units. It includes
both sides of an internal border.

The strong border-score trial moves Burkina Faso south. It gives the country
all six real neighbours, but also Guinea and Senegal. The other extra internal
pair is The Gambia–Guinea-Bissau. The two missing internal pairs are
Mali–Côte d’Ivoire and Mali–Guinea.

Visual review rejects this as a replacement: Benin develops a narrow northern
extension, Togo and Benin have thin coastal strips, and other contacts use narrow
connectors. Better neighbour counts do not make a better map. The stronger
perimeter score reduces these incentives but leaves more geographic errors.
The approved world map remains unchanged.

The next test should use Kontur population centres for interior placement guides,
not only polygon area centres. Mali's remaining errors are a useful test case.
Then allow a movable boundary with the neighbouring North and Central African
countries. The current fixed mask makes some external errors unavoidable.
A further shape test must reject narrow connectors, rather than reward a new
contact at any cost.

## Reproduce

Use the pinned Julia project and new output directories:

```sh
julia --project=owid-layout owid-layout/bin/refine-west-africa.jl \
  output/auto-cartogram/owid-clean-v2 \
  output/auto-cartogram/west-africa-new \
  geographic-centres-refined

julia --project=owid-layout owid-layout/bin/review-west-africa.jl \
  output/auto-cartogram/owid-clean-v2 \
  output/auto-cartogram/west-africa-review-new \
  output/auto-cartogram/west-africa-new
```

The renderer can take several trial directories. Red borders identify
unsupported neighbour pairs. Grey countries are outside the trial. The source
geography uses a separate scale. The HTML table reports remaining errors.

## Work log

- Audited the original African mainland and the 15-country neighbour graph.
- Added exact and penalized contact options without changing the default fit.
- Added deterministic local exchanges with count and connectivity checks.
- Checked the rendered local trials. Rejected thin-strip results for promotion.
- Added whole-region reassignment with explicit connectivity cuts.
- Strengthened these cuts: a disconnected component smaller than a country's
  budget must either disappear or connect across its boundary.
- Recorded rejected seed candidates. Identified detached coastal cells as the
  main obstacle to the centre-based seed, then added automatic connection roots.
- Checked the whole-region and strong-border-score images. Rejected the narrow
  connectors for promotion, despite the improvement in neighbour counts.
- Repeated the strong-border-score fit in a separate process. Final cells are
  byte-identical. The second report also retains the seed solver checks.
- Passed 221 Julia tests, including disconnected seeds and deterministic swaps.
- Reran the default clean layout fit. Its cells remain byte-identical to the
  approved clean build. SHA-256:

```text
ecb5033efa791e51f6fd3aeb9f857ba74903341040642a60991938fa0f009629
```
