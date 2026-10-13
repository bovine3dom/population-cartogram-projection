#!/usr/bin/env python3
"""Build a contact rotation system from source boundary traversal, not graph order."""
import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path

import networkx as nx


def rotations(features, labels):
    polygons={f["properties"]["component_id"]:f["geometry"]["coordinates"] for f in features
              if f["properties"]["component_id"] in labels}
    if set(polygons) != set(labels):
        raise ValueError("Source polygons do not match layout labels")
    def edge(a,b):
        return tuple(sorted((tuple(a),tuple(b))))
    segments=collections.defaultdict(set)
    for label,rings in polygons.items():
        for ring in rings:
            for a,b in zip(ring,ring[1:]):
                if a != b:
                    segments[edge(a,b)].add(label)
    portals={}
    for segment,owners in sorted(segments.items()):
        owners=sorted(owners)
        for i,a in enumerate(owners):
            for b in owners[i+1:]:
                portals.setdefault((a,b),segment)
    result={}
    for label,rings in polygons.items():
        neighbours=[]
        for index,ring in enumerate(rings):
            local=[]
            for a,b in zip(ring,ring[1:]):
                if a != b:
                    for other in sorted(segments[edge(a,b)]-{label}):
                        if edge(a,b) != portals[tuple(sorted((label,other)))]:
                            continue
                        if not local or local[-1] != other:
                            local.append(other)
            area=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(ring,ring[1:]))
            # Traverse outer boundary clockwise, holes counterclockwise.
            if (index == 0 and area > 0) or (index > 0 and area < 0):
                local.reverse()
            if len(local)>1 and local[0] == local[-1]:
                local.pop()
            neighbours.extend(local)
        result[label]=list(dict.fromkeys(neighbours))
    return result


def run(polygons, inputs, output):
    if output.exists():
        raise ValueError("Output already exists")
    with (inputs/"groups.csv").open() as stream:
        labels={r["component_id"] for r in csv.DictReader(stream) if int(r["tiles"]) > 0}
    features=json.loads(polygons.read_text())["features"]
    order=rotations(features,labels)
    graph=nx.Graph()
    graph.add_nodes_from(sorted(labels))
    with (inputs/"geographic-contacts.csv").open() as stream:
        graph.add_edges_from((r["a"],r["b"]) for r in csv.DictReader(stream) if r["both_represented"] == "true")
    if any(set(order[v]) != set(graph[v]) for v in graph):
        raise ValueError("Boundary traversal differs from recorded contacts")
    checks=[]
    for members in nx.connected_components(graph):
        embedding=nx.PlanarEmbedding()
        embedding.add_nodes_from(sorted(members))
        embedding.set_data({v:order[v] for v in sorted(members)})
        error=None
        try:
            embedding.check_structure()
        except nx.NetworkXException as exc:
            error=str(exc)
        checks.append({"vertices":len(members),"valid":error is None,"error":error})
    output.mkdir(parents=True)
    (output/"rotations.json").write_text(json.dumps(order,sort_keys=True,indent=2)+"\n")
    (output/"checks.json").write_text(json.dumps(checks,indent=2)+"\n")
    hashes={}
    for path in [polygons,inputs/"groups.csv",inputs/"geographic-contacts.csv",Path(__file__)]:
        with path.open("rb") as stream:
            hashes[str(path)]=hashlib.file_digest(stream,"sha256").hexdigest()
    (output/"manifest.json").write_text(json.dumps({"method":"One shared border segment per neighbour pair, selected consistently on both sides",
        "limit":"Other shared segments are discarded. Outer-face and enclave containment are not fixed.","inputs":hashes},indent=2)+"\n")
    print(json.dumps([c for c in checks if c["vertices"]>1],indent=2))
    return order,checks


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["polygons","inputs","output"]:
        parser.add_argument(name,type=Path)
    args=parser.parse_args()
    run(args.polygons,args.inputs,args.output)
