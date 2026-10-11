"""List selected country pairs with shared Natural Earth boundary segments."""
import csv
import itertools
import json
import sys
from collections import defaultdict
from pathlib import Path

if len(sys.argv) < 4:
    raise SystemExit("usage: shared_borders.py BOUNDARY.geojson NEW_OUTPUT.csv COUNTRY_CODES...")
boundary, output = map(Path, sys.argv[1:3])
codes = set(map(int, sys.argv[3:]))
if output.exists():
    raise SystemExit(f"refusing to overwrite {output}")
segments = defaultdict(set)
with boundary.open() as stream:
    features = json.load(stream)["features"]
for feature in features:
    try:
        code = int(feature["properties"]["ISO_N3_EH"])
    except (ValueError, TypeError):
        continue
    if code not in codes:
        continue
    geometry = feature["geometry"]
    polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    for polygon in polygons:
        for ring in polygon:
            points = [tuple(round(value, 7) for value in point[:2]) for point in ring]
            for a, b in zip(points, points[1:]):
                if a != b:
                    segments[tuple(sorted((a, b)))].add(code)
pairs = defaultdict(int)
for owners in segments.values():
    for pair in itertools.combinations(sorted(owners), 2):
        pairs[pair] += 1
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["country_a", "country_b", "shared_segments"])
    for (a, b), count in sorted(pairs.items()):
        writer.writerow([a, b, count])
print(f"Wrote {len(pairs)} pairs to {output}")
