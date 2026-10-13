#!/usr/bin/env python3
"""Merge map-unit polygons that share a border within the same country."""
import argparse
import collections
import csv
import json
import shutil
import tempfile
from pathlib import Path

import networkx as nx
import shapely
from shapely.geometry import Polygon, mapping

from save_review import digest


def merge(features, summaries):
    by_id={f["properties"]["component_id"]:f for f in features}
    if set(by_id) != set(summaries): raise ValueError("Polygon and population IDs differ")
    graph=nx.Graph(); graph.add_nodes_from(sorted(by_id)); segments=collections.defaultdict(set)
    for label,f in by_id.items():
        for ring in f["geometry"]["coordinates"]:
            for a,b in zip(ring,ring[1:]):
                if a != b: segments[tuple(sorted((tuple(a),tuple(b))))].add(label)
    for owners in segments.values():
        owners=sorted(owners)
        for i,a in enumerate(owners):
            for b in owners[i+1:]:
                if summaries[a]["country_id"] == summaries[b]["country_id"]: graph.add_edge(a,b)
    output=[]
    for members in sorted(map(sorted,nx.connected_components(graph))):
        first=summaries[members[0]]
        if len(members) == 1:
            geometry=by_id[members[0]]["geometry"]
        else:
            polygons=[Polygon(by_id[c]["geometry"]["coordinates"][0],by_id[c]["geometry"]["coordinates"][1:]) for c in members]
            if any(not p.is_valid for p in polygons): raise ValueError("Invalid polygon in a merge")
            union=shapely.union_all(polygons,grid_size=0)
            if union.geom_type != "Polygon" or not union.is_valid:
                raise ValueError("Shared-border merge is not one valid polygon")
            if abs(union.area-sum(p.area for p in polygons)) > 1e-10*union.area:
                raise ValueError("Merged input polygons overlap in area")
            geometry=mapping(union)
        properties=dict(GU_A3=first["map_unit"] if len(members)==1 else first["country_id"],
            ADM0_A3=first["country_id"],NAME=first["name"] if len(members)==1 else first["country_id"],
            ISO_N3_EH=first["raw_country_code"],original_components=members,
            population=sum(float(summaries[c]["population"]) for c in members),
            source_cells=sum(int(summaries[c]["source_cells"]) for c in members))
        output.append(dict(type="Feature",properties=properties,geometry=geometry))
    return output


def run(polygons, components, output):
    if output.exists(): raise ValueError("Output already exists")
    with components.open() as stream: summaries={r["component_id"]:r for r in csv.DictReader(stream)}
    original=json.loads(polygons.read_text())["features"]
    features=merge(original,summaries)
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="dissolved-",dir=output.parent))
    try:
        (temp/"boundaries.geojson").write_text(json.dumps(dict(type="FeatureCollection",features=features),separators=(",",":"))+"\n")
        source=json.loads((components.parent/"manifest.json").read_text())
        metadata=dict(method="Union of exact shared-border map units within ADM0_A3; no snapping",
            input_polygons=len(original),output_polygons=len(features),
            merged_groups=sum(len(f["properties"]["original_components"])>1 for f in features),
            population=sum(f["properties"]["population"] for f in features),
            unmatched_population=source["unmatched_population"],shapely_version=shapely.__version__,
            limit="Point contacts and disconnected islands are not merged. Source coverage and country policy are unchanged.",
            inputs={str(p):digest(p) for p in [polygons,components,components.parent/"manifest.json",Path(__file__)]})
        (temp/"manifest.json").write_text(json.dumps(metadata,indent=2)+"\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return metadata


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["polygons","components","output"]: parser.add_argument(name,type=Path)
    args=parser.parse_args()
    print(json.dumps(run(args.polygons,args.components,args.output),indent=2))
