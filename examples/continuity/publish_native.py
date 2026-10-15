"""Publish audited native Arrow IPC files without export row reduction."""
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


def check_file(path):
    # IPC files cannot contain replacement dictionaries. IPC streams can.
    with path.open("rb") as stream:
        if path.stat().st_size < 12 or stream.read(6) != b"ARROW1":
            raise ValueError("Expected an Arrow IPC file, not a stream")
        stream.seek(-6, 2)
        if stream.read() != b"ARROW1":
            raise ValueError("Missing Arrow IPC file footer")


def publish(export, quality, destination):
    export, quality, destination = map(Path, (export, quality, destination))
    pending = destination.with_name(destination.name + ".pending")
    if destination.exists() or pending.exists():
        raise ValueError("Destination or staging directory exists")
    audit = toml(export / "audit.toml")
    geometry = toml(quality / "geometry.toml")
    config = toml(export / "fit-input.toml")
    if "target_retained" in config or "forward_tolerance" in config:
        raise ValueError("Row-reduced exports are no longer supported; use the full fitted mapping")
    if audit["parts_sha256"] != geometry["parts_sha256"] or audit["factor"] != geometry["factor"]:
        raise ValueError("Geometry and binary inputs differ")
    if audit["resolution"] != 6 or audit["countries"] != 206:
        raise ValueError("Expected a complete native planet")
    for kind, name in FILES.items():
        path = export / name
        check_file(path)
        if digest(path) != audit[f"{kind}_sha256"] or path.stat().st_size != audit[f"{kind}_bytes"]:
            raise ValueError(f"Binary audit differs: {kind}")
    pending.mkdir(parents=True)
    for kind, name in FILES.items():
        shutil.copy2(export / name, pending / name)
        if digest(pending / name) != audit[f"{kind}_sha256"]:
            raise ValueError("Staged binary changed")
    for name in ("audit.toml", "fit-input.toml", "fit-countries.csv", "country-mass.csv"):
        shutil.copy2(export / name, pending / name)
    shutil.copytree(quality, pending / "geometry")
    metadata = {"cartogram": f"{destination.name}/{FILES['transport']}", "trimFactor": 0, "cartogramLineProbe": True}
    (pending / "population_density_hilo.json").write_text(json.dumps(metadata, indent=2) + "\n")
    size = sum(audit[f"{kind}_bytes"] for kind in FILES)
    final_audit = dict(audit, encoding="Arrow IPC file", total_bytes=size, geometry=geometry)
    (pending / "audit.json").write_text(json.dumps(final_audit, indent=2) + "\n")
    (pending / "README.md").write_text(f"""# Experimental native H3-6 planet, factor {audit['factor']}

This dataset is separate from H3-5. It has {audit['sources']:,} source cells,
{audit['physical_targets']:,} physical target cells, and {audit['rows']:,}
transport rows. Both Arrow files total {size:,} bytes. Population is
{audit['population']:,.0f}. All {audit['labelled_sources']:,} labelled sources
are retained. Displayed labels can be fewer because target positions collide.

## Model and checks

{audit['model']}.
The native source fit uses KernelAbstractions and oneAPI. Target subdivision
uses CPU linear programming. This is not a new global border-optimization
pass. Existing border and orientation defects remain.

This export uses the saved fitted mapping without additional row reduction.
It does not apply an export moment-packing step. Existing fit checkpoints can
retain the numerical sparsification policy used when they were created.
The 99.5% support ratio is {geometry['ratio995']:.6g}. The low-population source
ratio is {geometry['low_population_ratio995']:.6g}.

The binary audit checks source coverage, country masses, target weights,
density, city names, and every serialized column. Density uses Float32.
Population uses {audit.get('population_type', 'Float64')}. A narrower population
type is used only when every value is exactly preserved. See audit.json,
fit-input.toml, fit-countries.csv, geometry/, and sha256.json.

## Format and browser limits

Both outputs are ordinary Arrow IPC files. Ordinary dictionary encoding is
lossless. There are no per-batch replacement dictionaries. Arrow.Table and
Apache Arrow JavaScript can read these files.

The native geographic layer requires substantial browser memory. Previous
checks retained 1.3 to 1.6 GB of backing storage, plus JavaScript heap. These
files are not established as phone-safe. Keep H3-5 available. The existing
production zstd policy is unchanged. No viewport geometry option is used.

Open /?data={destination.name}/population_density_hilo.arrow in H3-MON.
The adjacent JSON selects the cartogram. Publication does not start the server
or change its default dataset.
""")
    hashes = {p.relative_to(pending).as_posix(): digest(p) for p in sorted(pending.rglob("*")) if p.is_file()}
    (pending / "sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    pending.rename(destination)
    return size


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: publish_native.py EXPORT QUALITY NEW_DESTINATION")
    print(publish(*sys.argv[1:]))
