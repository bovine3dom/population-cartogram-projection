#!/usr/bin/env python3
"""Check guide polygons; use the original projected ring when simplification fails."""
import argparse
import hashlib
import json
from pathlib import Path

from shapely.geometry import Polygon
from shapely import is_valid_reason


def run(inputs):
    if (inputs/"validated.wkt").exists() or (inputs/"outline-checks.json").exists():
        raise ValueError("Validated guides already exist")
    originals=json.loads((inputs/"original-outlines.json").read_text())
    lines=(inputs/"input.wkt").read_text().splitlines()
    checks=[]
    for i in range(2,len(lines),3):
        label=lines[i].split("\t")[1]
        ring=[tuple(map(float,p.split())) for p in lines[i+1].split("\t")]
        polygon=Polygon(ring)
        if not polygon.is_valid:
            original=Polygon(originals[label])
            if not original.is_valid:
                raise ValueError(f"Invalid original projected outline {label}: {is_valid_reason(original)}")
            # Keep all shared vertices. A shape-only simplifier could erase
            # border endpoints and change native adjacency detection.
            points=list(original.exterior.coords)[:-1]
            if not original.exterior.is_ccw:
                points.reverse()
            lines[i+1]="\t".join(f"{x} {y}" for x,y in points)
            checks.append({"component_id":label,"reason":is_valid_reason(polygon),
                           "simplified_vertices":len(ring),"original_vertices":len(points)})
    metadata={"fallbacks":checks,"method":"Invalid simplified guides use original projected outer rings",
              "source_sha256":hashlib.sha256((inputs/"input.wkt").read_bytes()).hexdigest(),
              "script_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (inputs/"outline-checks.json").write_text(json.dumps(metadata,indent=2)+"\n")
    (inputs/"validated.wkt").write_text("\n".join(lines)+"\n")
    print(f"Validated outlines: {len(checks)} original-ring fallbacks")
    return metadata


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs",type=Path)
    run(parser.parse_args().inputs)
