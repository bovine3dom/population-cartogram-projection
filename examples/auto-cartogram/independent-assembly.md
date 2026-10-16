# Regional assembly of independent shapes

[Review the paired images and checks](http://proto.olie.science:8642/results/geography/independent-assembly/index.html).
The [current best](current-best.md) is unchanged.

## What a cut does

The assembly has no shared flow field. Each country starts with its independent
90% Kontur shape. A cut removes that pair from the required-contact list.
It has no direct contact penalty, boundary matching term, or target gap.
General collision and geographic ordering still apply to all pairs.

The two cases have the same shapes, area budgets, initial geographic positions,
deformation bounds, and optimization settings. The control requests 23 contacts.
The cut case requests 19. It releases Russia–Kazakhstan, China–Kazakhstan,
Russia–China, and Russia–Mongolia. All four pass the saved population audit.

The 12-country region includes Azerbaijan, Iran, Afghanistan, Pakistan, and
India. Thus, the required-contact graph still connects Russia and China. Removing a direct
connection does not remove the indirect constraints through other countries.
External neighbours, islands, and lakes are omitted.

## Scope of this prototype

This is a contact-only affine assembly, not the full boundary model proposed in
the discussion. Each country can translate, stretch, and shear. The transform
has determinant one, so area stays fixed. Log stretch and shear are bounded to
[-0.7, 0.7]. The assembly minimizes deformation from the independent shapes.

Retained contacts initially use nearest-boundary distance penalties. These allow
point contacts; they do not make corresponding border curves coincide. The final
paired test adds explicit numerical constraints on retained gaps and total
overlap. Both final cases start from the same saved all-borders pose.

The final constraint targets are a maximum gap of 0.05 tile widths and total
overlap below 0.001 tile areas. These are requests to the solver, not guarantees.
The gallery reports the actual residuals. Its looser diagnostic check requires
maximum gap below 0.1 and total overlap below 0.01. Passing that check would still
not establish a full border fit.

## Measured result

Six paired trials completed. None passes the contact-only check. In the last
pair, the control has 0.1705 tile areas of overlap and a maximum required gap of
2.459 tile widths. The cut case has 0.4850 tile areas of overlap and a maximum
required gap of 0.580 tile widths. Ten control contacts and two retained cut-case
contacts exceed the 0.1 gap threshold. The two cut-case gaps are Azerbaijan–Iran
and Kazakhstan–Uzbekistan. Both optimizations stopped without success.

The cuts have a real effect: Russia–Kazakhstan opens to 7.685 tile widths and
China–Kazakhstan to 7.047. Russia–Mongolia opens to 0.687. Russia–China still
touches or overlaps slightly. A cut permits separation; it does not require it.

Visual checks show that India becomes narrower, and several Central Asian
countries remain too thin. Russia's geographic outline score improves slightly,
but China, India, and Kazakhstan get worse in the last cut comparison. Thus,
these results do not establish a useful shape improvement. Do not promote them.

The next model needs local boundary deformation with explicit matching along
retained borders. It must keep the released borders independent. Increasing
whole-country stretch or repeating seam-width tests is not the next step.

## Tests and numerical issues

The first overlap penalty used intersection area alone. This has no translation
gradient when a small country is wholly inside a larger country. Mongolia could
remain inside China. A general interior-depth penalty now supplies an escape
direction. It also applies to cut pairs.

Other trials test stronger shape penalties, scaled translation variables, and
the SLSQP optimizer. Unchanged country-pair calculations are cached. The cached
and uncached first stages have identical objective values and iteration counts.
The incomplete timing run and an interrupted preliminary polish run are not
published as completed comparisons.

All trials use the same simplified independent outlines. Simplification changes
the outline score by 0.004–0.047. The shapes are rescaled to their original
component tile-area budgets before assembly. No population is reassigned.

A failed assembly does not establish that the cut policy is wrong or impossible.
The affine model has limited freedom, the contact model is incomplete, and the
optimization is local. Do not promote a result that has residual overlaps or
missing required borders, even if its country outlines look better.

## Reproduce the latest pair

Run from the repository root. Use new output directories:

```sh
export PYTHONDONTWRITEBYTECODE=1 OPENBLAS_NUM_THREADS=1
PY=output/auto-cartogram/geometry-env/bin/python
ROOT=output/auto-cartogram
$PY examples/auto-cartogram/assemble_independent.py "$ROOT" \
  "$ROOT/assembly-repeat" --iterations 200 --optimizer SLSQP
$PY examples/auto-cartogram/polish_independent_assembly.py "$ROOT" \
  "$ROOT/assembly-repeat" "$ROOT/assembly-repeat-constrained" --iterations 500
```

These commands need the saved independent fits in `independent-kontur-flow` and
`independent-eurasia-neighbours`. `publish_independent_assembly.py` builds the
review gallery from the named trial directories. The gallery includes settings,
input hashes, measured gaps and overlaps, country shape scores, and geometry.

The optimizer options were checked against the
[SciPy documentation](https://docs.scipy.org/doc/scipy/reference/optimize.minimize-lbfgsb.html).
