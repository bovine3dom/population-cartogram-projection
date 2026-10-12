# Planet continuity run

## 2026-10-12: preparation

The requested output is a separate experimental H3-MON dataset. Use native H3-5
sources and factor 1. Do not change the existing planet, UK, or Germany files.

Input: `~/projects/H3-MON/www/data/cartogram_weights_hilo.arrow`.
Study: `output/planet-h3-5-factor1-continuity/`.
Destination: `~/projects/H3-MON/www/data/planet-h3-5-factor1-continuity/`.

The input has 206 country codes. The contact audit finds 245 real artwork
contacts, with 3,292 grid edges. Fit their 152 countries together. Keep the old
conditional mapping for the other 54 countries. There are 49 false artwork
contacts and 64 geographic neighbour pairs with no usable artwork contact.
Exclude mixed-country target cells from the edge graph, including where the
other owner is outside the fitted group.

One full dense plan for the fitted countries is 5.14 GB. Stream pose candidates
instead of keeping eight global plans. Calculate dense gradients only for the
active country. Cache transport objective values with weak plan references.
Save full fit checkpoints after each pass, not after each country update.
The production solver is unchanged.

The runner uses KernelAbstractions and oneAPI, with no CPU solver fallback.
It tests eight rotations per country, then runs up to ten coupled passes.
The local-scale penalty uses the regional experiment's stronger settings.
This is an experimental fit, not a claim of global continuity or convergence.
It retains the known limits on islands, false contacts, and geometric folds.

CPU and oneAPI research tests pass. A complete small oneAPI test passes through
preparation, fitting, Arrow export, and atomic directory publication. Tests also
cover shared target cells, city names, source coverage, hi/lo IDs, and source and
target normalization. Logs are in `output/planet-validation/`.

After the full fit finishes, the runner checks mass constraints and writes both
Arrow files and diagnostics. Only then does it publish the destination folder.
H3-MON stays stopped. The existing dataset remains unchanged.

See `examples/continuity/planet.md` for commands, file names, and limitations.

## 05:40 UTC: launch

Started the detached fit-and-publish job from commit `d9f67bf`. Runner PID:
`2163081`. Initial Julia PID: `2163084`. The log confirms the Intel HD Graphics
P630 oneAPI device. Country cost preparation is in progress. No output has been
published yet. The log is `output/planet-h3-5-factor1-continuity/job.log`.
The runner writes its final exit status and publishes only after a successful
fit and export. No reliable whole-planet runtime estimate is available yet.
