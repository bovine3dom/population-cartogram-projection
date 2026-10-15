"""Publish separate, audited H3-6 data without changing H3-MON code."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tomllib

FILES = {"transport": "cartogram_weights_hilo.arrow", "density": "population_density_hilo.arrow"}


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def toml(path):
    with Path(path).open("rb") as stream:
        return tomllib.load(stream)


def publish(raw, packed, quality, destination, packing_audit=None):
    raw, packed, quality, destination = map(Path, (raw, packed, quality, destination))
    pending = destination.with_name(destination.name + ".pending")
    if destination.exists() or pending.exists():
        raise ValueError("Destination or staging directory exists")
    audit = toml(raw / "audit.toml")
    geometry = toml(quality / "geometry.toml")
    config = toml(raw / "fit-input.toml")
    if audit["parts_sha256"] != geometry["parts_sha256"] or audit["factor"] != geometry["factor"]:
        raise ValueError("Geometry and binary inputs differ")
    if audit["resolution"] != 6 or audit["countries"] != 206:
        raise ValueError("Expected a complete native planet")
    checks = {}
    for kind, name in FILES.items():
        check = toml(packed / f"{kind}-verified.toml")
        packing = json.loads((packed / Path(name).with_suffix(".packing.json")).read_text())
        original, final = digest(raw / name), digest(packed / name)
        if not (check["all_columns_equal"] and check["reader"] == "Arrow.Stream"
                and original == audit[f"{kind}_sha256"] == check["reference_sha256"] == packing["input_sha256"]
                and final == check["stream_sha256"] == packing["output_sha256"]
                and check["stream_bytes"] == (packed / name).stat().st_size):
            raise ValueError(f"Invalid hash or value chain: {kind}")
        checks[kind] = check
    if "target_retained" in config:
        if packing_audit is None:
            raise ValueError("Approximate packing requires a binary comparison")
        packing_audit = Path(packing_audit)
        comparison = toml(packing_audit)
        if not (comparison["anchors_equal"] and comparison["transport_sha256"] == audit["transport_sha256"]
                and comparison["parts_sha256"] == audit["parts_sha256"]
                and comparison["query_sha256"] == digest(str(packing_audit) + ".queries.csv")):
            raise ValueError("Packing comparison differs")
    pending.mkdir(parents=True)
    for kind, name in FILES.items():
        shutil.copy2(packed / name, pending / name)
        if digest(pending / name) != checks[kind]["stream_sha256"]:
            raise ValueError("Staged binary changed")
        shutil.copy2(packed / f"{kind}-verified.toml", pending)
        shutil.copy2(packed / Path(name).with_suffix(".packing.json"), pending)
    for name in ("audit.toml", "fit-input.toml", "fit-countries.csv", "country-mass.csv"):
        shutil.copy2(raw / name, pending / ("unpacked-audit.toml" if name == "audit.toml" else name))
    shutil.copytree(quality, pending / "geometry")
    if packing_audit is not None:
        shutil.copy2(packing_audit, pending / "packing-audit.toml")
        shutil.copy2(str(packing_audit) + ".queries.csv", pending / "query-errors.csv")
    metadata = {"cartogram": f"{destination.name}/{FILES['transport']}", "trimFactor": 0, "cartogramLineProbe": True}
    (pending / "population_density_hilo.json").write_text(json.dumps(metadata, indent=2) + "\n")
    size = sum(c["stream_bytes"] for c in checks.values())
    final_audit = dict(audit, encoding="Arrow IPC stream with replacement dictionaries", total_bytes=size,
                       geometry=geometry, files=checks, unpacked_audit="unpacked-audit.toml")
    for kind, check in checks.items():
        final_audit[f"{kind}_bytes"] = check["stream_bytes"]
        final_audit[f"{kind}_sha256"] = check["stream_sha256"]
    (pending / "audit.json").write_text(json.dumps(final_audit, indent=2) + "\n")
    approximate = (f"This export uses approximate moment packing. Protected target mass is {config['target_retained']:g}. "
                   f"The source-mean coordinate limit is {config['forward_tolerance']:g} coarse grid units. "
                   "Other query values can change. Missing-data queries can lose coverage. See query-errors.csv."
                   if "target_retained" in config else "No additional approximate moment packing is applied to this fit.")
    (pending / "README.md").write_text(f"""# Experimental native H3-6 planet, factor {audit['factor']}

This dataset is separate from H3-5. It does not replace another map.
It has {audit['sources']:,} sources, {audit['physical_targets']:,} physical target
cells, and {audit['rows']:,} transport rows. Both Arrow files total {size:,} bytes.
Factor {audit['factor']} divides each old target into {audit['factor'] ** 2} cells.
Population is {audit['population']:,.0f}. Source coverage uses native polygon
extraction, not inherited H3-5 coverage. There are {audit['labelled_sources']:,}
labelled sources. Displayed labels can be fewer because target positions collide.

## Model and checks

{audit['model']}.
The source fit uses KernelAbstractions and oneAPI. Target moment projection
and optional export packing use CPU linear programming. This is not a new
whole-planet border optimization. Existing border defects remain.

The 99.5% support ratio is {geometry['ratio995']:.6g}. Its population-capacity
lower bound is {geometry['capacity_lower995']:.6g}. The low-population source
ratio is {geometry['low_population_ratio995']:.6g}. Geometry and fit reports
record the accepted result; do not infer convergence from a small row count.
Inspect fit-countries.csv for recorded fallback counts. Cell-level solver
status remains in the research fit. A time-limited LP result is not an optimum.

{approximate}

The unpacked audit checks masses, source coverage, density, and city names.
The two stream reports compare every binary column with that checked export.
Dictionary packing changes no values or row order. Density uses Float32;
source population uses Float64. File hashes are in sha256.json.

## Reader and memory limits

Use Apache Arrow JavaScript or a reader that supports replacement dictionaries.
With Arrow.jl 2.8.1, use Arrow.Stream. Arrow.Table can join these dictionaries
incorrectly. The files are IPC streams, not footer-indexed IPC files.

This is not a phone-safe memory claim. The full native geographic layer retained
about 1.3 GB of browser backing storage in the baseline headless test, plus
about 102 MB of JavaScript heap. A smaller file does not remove that cost.
Higher factors need separate memory measurements. Keep the H3-5 map available.
Use the existing production zstd policy. No HTTP compression setting changed.
No viewport geometry option is used.

Open /?data={destination.name}/population_density_hilo.arrow in H3-MON.
The adjacent JSON selects the cartogram. Publication does not start the server
or change its default dataset.
""")
    hashes = {p.relative_to(pending).as_posix(): digest(p) for p in sorted(pending.rglob("*")) if p.is_file()}
    (pending / "sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    pending.rename(destination)
    return size


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        raise SystemExit("usage: publish_native.py RAW_EXPORT STREAM_EXPORT QUALITY NEW_DESTINATION [PACKING_AUDIT]")
    print(publish(*sys.argv[1:]))
