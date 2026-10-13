"""Stage an audited mobile export. Do not replace an existing directory."""
import csv
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tomllib

TRANSPORT = "cartogram_weights_planet_h3_5_factor1_continuity_hilo.arrow"
DENSITY = "population_density_hilo.arrow"
MAX_ARROW_BYTES = 100_000_000


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publish(candidate, audit_file, reference, destination):
    candidate, audit_file, reference, destination = map(Path, (candidate, audit_file, reference, destination))
    pending = destination.with_name(destination.name + ".pending")
    if destination.exists() or pending.exists():
        raise ValueError("Destination or staging directory already exists")
    with audit_file.open("rb") as stream:
        audit = tomllib.load(stream)
    query_report = audit_file.with_suffix(".queries.csv")
    if digest(query_report) != audit["query_report_sha256"]:
        raise ValueError("Query report hash mismatch")
    with (candidate / "export.toml").open("rb") as stream:
        export = tomllib.load(stream)
    for key, path in (("transport", candidate / TRANSPORT), ("density", candidate / DENSITY),
                      ("reference", reference / TRANSPORT)):
        if digest(path) != audit["sha256"][key]:
            raise ValueError(f"Audit hash mismatch: {key}")
    if export["input_sha256"] != audit["sha256"]["input"] or export["rows"] != audit["rows"]:
        raise ValueError("Export and audit do not match")
    size = sum((candidate / name).stat().st_size for name in (TRANSPORT, DENSITY))
    if size > MAX_ARROW_BYTES:
        raise ValueError("The two Arrow files exceed 100 MB")
    with (reference / "settings.csv").open() as stream:
        passes = int(next(csv.DictReader(stream))["outer_steps"])
    pending.mkdir(parents=True)
    # Fit diagnostics describe the original fitted plan, not the reduced coupling.
    for name in ("baseline-seams.csv", "candidate-seams.csv", "candidate-orientation.csv", "contacts.csv",
                 "countries.csv", "fit-config.csv", "metrics.csv", "settings.csv", "provenance.txt", "compact.md"):
        shutil.copy2(reference / name, pending / name)
    shutil.copy2(reference / "README.md", pending / "fit-method.md")
    for name in (TRANSPORT, DENSITY, "export.toml", "provenance.csv", "shared-cell-owners.csv"):
        shutil.copy2(candidate / name, pending / name)
    shutil.copy2(candidate / "countries.csv", pending / "mobile-countries.csv")
    shutil.copy2(candidate / "query-errors.csv", pending / "checkpoint-query-errors.csv")
    shutil.copy2(query_report, pending / "query-errors.csv")
    shutil.copy2(audit_file, pending / "mobile-audit.toml")
    for key, name in (("transport", TRANSPORT), ("density", DENSITY)):
        if digest(pending / name) != audit["sha256"][key]:
            raise ValueError(f"Staged file changed: {name}")
    metadata = {"cartogram": f"{destination.name}/{TRANSPORT}", "trimFactor": 0, "viewportGeometry": True}
    (pending / "population_density_hilo.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (pending / "README.md").write_text(f"""# Small experimental planet export

Both Arrow files use H3-5 cells and subdivision factor 1. They use {size:,} bytes
in total. This is an approximate browser export of the continuity experiment.
It is not a replacement for the production planet, UK, or Germany datasets.

The source fit completed {passes} passes. It still has large border defects.
Do not describe it as converged. The small export does not refit the map.

## Reduction and checks

The transport has {audit['rows']:,} rows, {audit['sources']:,} source cells,
{audit['targets']:,} country target cells, and {audit['labels']:,} labelled sources.
Some countries share a target position. The browser therefore has fewer
physical cells and displayed labels than these country and source counts.

The reduction preserves source mass, source mean target position, target
population, target mean geographic XYZ position, and target mean density.
It keeps the original city anchors and shared-cell country ownership.
The required protected contribution fraction is {audit['requested_target_retained']:g}.
Measured maximum conditional total variation is {audit['target_tv_max']:.8g}.
Maximum geographic mean error is {1000 * audit['geographic_error_km_max']:.6g} m.

Other queries can change. For complete values in a bounded range, total
variation bounds the mean error as a fraction of that range. The same bound
does not apply unchanged after missing-data filtering and renormalization.
See `query-errors.csv` for tests of the actual binary files at physical target
positions. Distance tests are not travel times. The separate checkpoint query
report gives pre-serialization results for each country.

`mobile-audit.toml` records independent checks of the binary files and their
SHA256 hashes. `mobile-countries.csv` and `provenance.csv` record the reduction.
The remaining fit diagnostics describe the original fitted plan. The old
fit instructions are in `fit-method.md`; their 99.999% export rule describes
the full reference, not this small file.

## Browser

Use a dictionary-capable Arrow reader. H3-MON commit `6563a17` or later uses
Apache Arrow directly. Older loaders.gl readers can reject these files.
HTTP gzip reduces transfer bytes but does not reduce decoded data size.
File size alone does not establish a safe memory limit on a phone. Metadata
enables visible-region geometry in updated H3-MON builds. All source data
remain available for queries. A world view still needs full-world geometry.

Open `/?data={destination.name}/population_density_hilo.arrow` in H3-MON.
The adjacent JSON file selects this experimental cartogram. Publication does
not start H3-MON or change its default dataset.
""")
    hashes = {path.name: digest(path) for path in sorted(pending.iterdir()) if path.is_file()}
    (pending / "sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    pending.rename(destination)
    return size


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: publish.py CANDIDATE AUDIT_TOML FULL_REFERENCE NEW_DESTINATION")
    print(publish(*sys.argv[1:]))
