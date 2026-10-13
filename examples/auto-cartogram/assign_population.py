#!/usr/bin/env python3
"""Join native H3 centres to prepared polygon geometry in bounded batches."""
import argparse
import csv
import hashlib
import json
import shutil
import tempfile
import time
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.ipc as ipc
import shapely
from shapely.geometry import shape


def file_hash(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def assign_batch(polygons, longitude, latitude):
    points = shapely.points(longitude, latitude)
    tree = shapely.STRtree(points)
    parts, rows = tree.query(polygons, predicate="contains")
    owners = np.zeros(len(longitude), dtype=np.int32)
    # A centre inside two polygons is ambiguous, not two copies of population.
    unique, count = np.unique(rows, return_counts=True)
    owners[rows] = parts + 1
    owners[unique[count > 1]] = -1
    return owners


def run(inputs, output, batch_size=250000):
    if output.exists():
        raise ValueError(f"Output exists: {output}")
    started = time.monotonic()
    features = json.loads((inputs / "polygons.geojson").read_text())["features"]
    geometries = []
    skipped = []
    for feature in features:
        geom = shape(feature["geometry"])
        reason = None
        if geom.bounds[2] - geom.bounds[0] > 180:
            reason = "longitude_span_over_180"
        elif not shapely.is_valid(geom):
            reason = shapely.is_valid_reason(geom)
        if reason:
            skipped.append({**feature["properties"], "reason": reason})
            geometries.append(None)
        else:
            geometries.append(geom)
    shapely.prepare(geometries)
    geometries = np.asarray(geometries, dtype=object)
    source = ipc.open_file(pa.memory_map(str(inputs / "centres.arrow"))).read_all()
    longitude = source["longitude"].combine_chunks().to_numpy()
    latitude = source["latitude"].combine_chunks().to_numpy()
    values = source["value"].combine_chunks().to_numpy()
    owners = np.zeros(len(source), dtype=np.int32)
    populations = np.zeros(len(features))
    counts = np.zeros(len(features), dtype=np.int64)
    for start in range(0, len(source), batch_size):
        stop = min(start + batch_size, len(source))
        assigned = assign_batch(geometries, longitude[start:stop], latitude[start:stop])
        owners[start:stop] = assigned
        valid = assigned > 0
        populations += np.bincount(assigned[valid]-1, weights=values[start:stop][valid], minlength=len(features))
        counts += np.bincount(assigned[valid]-1, minlength=len(features))
        print(f"{stop}/{len(source)} centres; {time.monotonic()-started:.1f}s", flush=True)
    metadata = json.loads((inputs / "manifest.json").read_text())
    manifest = {
        "population_total": float(populations.sum()), "input_population": float(values.sum()),
        "source_cells": int(counts.sum()), "input_cells": len(source),
        "unmatched_cells": int(np.count_nonzero(owners == 0)),
        "unmatched_population": float(values[owners == 0].sum()),
        "ambiguous_cells": int(np.count_nonzero(owners == -1)),
        "ambiguous_population": float(values[owners == -1].sum()), "skipped": skipped,
        "population_year": metadata["population_year"],
        "membership": "GEOS contains on native H3-8 centres in longitude/latitude; excludes boundary points",
        "country_identity": "Natural Earth ADM0_A3, not raw numeric ISO_N3_EH",
        "shapely_version": shapely.__version__, "geos_version": shapely.geos_version_string,
        "pyarrow_version": pa.__version__, "numpy_version": np.__version__,
        "batch_size": batch_size, "elapsed_seconds": time.monotonic()-started,
        "inputs": [{"path": str(p.resolve()), "sha256": file_hash(p)} for p in
                   (inputs/"centres.arrow", inputs/"polygons.geojson", inputs/"manifest.json", Path(__file__))],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix="population-join-", dir=output.parent))
    try:
        columns = ["component_id", "country_id", "map_unit", "name", "raw_country_code",
                   "population", "source_cells", "holes", "west", "south", "east", "north"]
        with (temp / "components.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=columns)
            writer.writeheader()
            for i, feature in enumerate(features):
                geom = shape(feature["geometry"])
                west, south, east, north = geom.bounds
                row = {k: feature["properties"][k] for k in columns[:5]}
                writer.writerow({**row, "population": populations[i], "source_cells": counts[i],
                                 "holes": len(feature["geometry"]["coordinates"])-1,
                                 "west": west, "east": east, "south": south, "north": north})
        membership = pa.table({"id": source["id"], "value": source["value"], "component_index": owners})
        with ipc.new_file(str(temp / "source-membership.arrow"), membership.schema) as writer:
            writer.write_table(membership)
        unmatched = source.filter(pa.array(owners <= 0)).append_column("component_index", pa.array(owners[owners <= 0]))
        with ipc.new_file(str(temp / "unmatched.arrow"), unmatched.schema) as writer:
            writer.write_table(unmatched)
        (temp / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
        temp.rename(output)
    finally:
        if temp.exists():
            shutil.rmtree(temp)
    print(json.dumps({k:v for k,v in manifest.items() if k not in ("inputs", "skipped")}, indent=2))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--batch-size", type=int, default=250000)
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("batch-size must be positive")
    run(args.inputs, args.output, args.batch_size)
