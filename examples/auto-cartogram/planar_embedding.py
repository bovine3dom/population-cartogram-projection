#!/usr/bin/env python3
"""Draw a planar initial dual, with optional sea regions for added edges."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path

import networkx as nx
import numpy as np


def augment(graph, embedding=None, *, sea_regions=True):
    if embedding is None:
        planar, embedding = nx.check_planarity(graph)
        if not planar:
            raise ValueError("Geographic contact graph is nonplanar")
    embedding.check_structure()
    if not sea_regions or len(graph) < 3:
        return graph.copy(), {}, embedding
    triangulated, _ = nx.algorithms.planar_drawing.triangulate_embedding(embedding, fully_triangulate=False)
    result = graph.copy()
    sea = {}
    # Added original-to-original edges would invent land borders. Subdivide
    # every such edge with a sea vertex instead; remove its tiles at export.
    added = {tuple(sorted((a,b))) for a,b in triangulated.edges if not graph.has_edge(a,b)}
    for a,b in sorted(added):
        label = "SEA:"+hashlib.sha256(f"{a}|{b}".encode()).hexdigest()[:16]
        result.add_edge(a,label); result.add_edge(label,b)
        sea[label] = (a,b)
    if not nx.is_biconnected(result):
        raise ValueError("Augmented graph is not biconnected")
    edge_sea = {pair:label for label,pair in sea.items()}
    rotation = {v:[edge_sea.get(tuple(sorted((v,n))),n) for n in triangulated.neighbors_cw_order(v)] for v in triangulated}
    rotation.update({label:list(pair) for label,pair in sea.items()})
    augmented_embedding = nx.PlanarEmbedding()
    augmented_embedding.set_data(rotation)
    augmented_embedding.check_structure()
    return result, sea, augmented_embedding


def integer_positions(graph, geography, embedding=None):
    if embedding is None:
        planar, embedding = nx.check_planarity(graph)
        if not planar:
            raise ValueError("Augmented graph is nonplanar")
    embedding.check_structure()
    positions = nx.combinatorial_embedding_to_pos(embedding)
    labels = sorted(graph)
    coordinates = np.array([positions[label] for label in labels], dtype=float)
    if len(labels) == 2:
        # Avoid an axis-aligned two-vertex graph. Upstream outer-face edges
        # can pass through the other vertex and fail its crossing assertion.
        coordinates = np.array([[0.,0.],[2.,1.]])
    target = np.array([geography[label] for label in labels], dtype=float)
    target -= target.mean(axis=0)
    # Select from eight signed axis permutations. Keep integer coordinates to
    # avoid additional near-collinear cases in upstream geometric predicates.
    candidates = [coordinates[:,axes]*[sx,sy] for axes in ([0,1],[1,0]) for sx in (-1,1) for sy in (-1,1)]
    def error(candidate):
        centred = candidate-candidate.mean(axis=0)
        denominator = np.square(centred).sum()
        scale = max(float((centred*target).sum()/denominator),0) if denominator else 1
        return float(np.square(scale*centred-target).sum())
    coordinates = min(candidates,key=error)*10
    return dict(zip(labels,coordinates.tolist()))


def degree_conflicts(edges, weights):
    graph=nx.Graph(edges)
    # A connected n-cell square shape has at most 2n+2 boundary edges.
    return [{"component_id":v,"tiles":weight,"degree":graph.degree[v],
             "minimum_tiles":(graph.degree[v]-1)//2}
            for v,weight in sorted(weights.items()) if v in graph and graph.degree[v]>2*weight+2]


def run(inputs, rotations_path=None, *, sea_regions=True):
    output_names = ["embedding.tsv", "embedding-edges.tsv", "embedding.json", "augmented.wkt", "augmented-weights.tsv"]
    if any((inputs/name).exists() for name in output_names):
        raise ValueError("Embedding files already exist")
    with (inputs/"groups.csv").open() as stream:
        shapes = {r["component_id"]:r for r in csv.DictReader(stream) if int(r["tiles"]) > 0}
    graph = nx.Graph()
    graph.add_nodes_from(sorted(shapes))
    with (inputs/"geographic-contacts.csv").open() as stream:
        for r in csv.DictReader(stream):
            if r["both_represented"] == "true":
                graph.add_edge(r["a"],r["b"])
    # The input writer emits STAGE 1, one outer ring, and zero sites per shape.
    lines = (inputs/"validated.wkt").read_text().splitlines()
    records = {}
    for start in range(2,len(lines),3):
        header = lines[start].split("\t")
        if lines[start+2] != "SITECOUNT 0":
            raise ValueError("Expected outlines without sites")
        records[header[1]] = (header,lines[start+1])
    if set(records) != set(shapes):
        raise ValueError("Outline labels differ from group table")
    geography = {label:[(float(r["west"])+float(r["east"]))/2,
                       (float(r["south"])+float(r["north"]))/2] for label,r in shapes.items()}
    prescribed = json.loads(rotations_path.read_text()) if rotations_path else None
    if prescribed is not None and (set(prescribed) != set(graph) or
            any(set(prescribed[v]) != set(graph[v]) for v in graph)):
        raise ValueError("Prescribed rotations differ from the contact graph")
    poses, sea, edges, sizes = {}, {}, set(), []
    for members in nx.connected_components(graph):
        subgraph = graph.subgraph(sorted(members)).copy()
        local_embedding = None
        if prescribed is not None:
            local_embedding = nx.PlanarEmbedding()
            local_embedding.add_nodes_from(sorted(members))
            local_embedding.set_data({v:prescribed[v] for v in sorted(members)})
        augmented, local_sea, drawing_embedding = augment(subgraph, local_embedding, sea_regions=sea_regions)
        for label,(a,b) in local_sea.items():
            geography[label] = [(x+y)/2 for x,y in zip(geography[a],geography[b])]
        poses.update(integer_positions(augmented,geography,drawing_embedding))
        sea.update(local_sea)
        edges.update(tuple(sorted(e)) for e in augmented.edges)
        sizes.append(len(subgraph))
    with (inputs/"embedding.tsv").open("w") as stream:
        for label,(x,y) in sorted(poses.items()):
            stream.write(f"{label}\t{x:.0f}\t{y:.0f}\n")
    with (inputs/"embedding-edges.tsv").open("w") as stream:
        for a,b in sorted(edges):
            stream.write(f"{a}\t{b}\n")
    with (inputs/"augmented.wkt").open("w") as stream, (inputs/"augmented-weights.tsv").open("w") as weights:
        stream.write(f"STAGE 1\nOUTLINES {len(poses)}\n")
        for index,label in enumerate(sorted(poses)):
            if label in sea:
                a,b = sea[label]
                ca = list(map(float,records[a][0][2].split()))
                cb = list(map(float,records[b][0][2].split()))
                x,y = [(u+v)/2 for u,v in zip(ca,cb)]
                d=0.0001
                ring=f"{x-d} {y-d}\t{x+d} {y-d}\t{x+d} {y+d}\t{x-d} {y+d}"
                header=[f"OUT {index}",label,f"{x} {y}","255 255 255"]
                weight=1
            else:
                original,ring=records[label]
                header=[f"OUT {index}",*original[1:]]
                weight=int(shapes[label]["tiles"])
            stream.write("\t".join(header)+"\n"+ring+"\nSITECOUNT 0\n")
            weights.write(f"{label}\t{weight}\n")
    metadata={"method":"Biconnected planar dual with temporary sea vertices; Chrobak-Payne integer drawing" if sea_regions else
                        "Original planar dual; Chrobak-Payne integer drawing",
              "sea_regions":sea_regions,
              "rotation_source":"geographic border portals" if prescribed is not None else "NetworkX planarity algorithm",
              "rotation_sha256":hashlib.sha256(rotations_path.read_bytes()).hexdigest() if rotations_path else None,
              "networkx_version":nx.__version__,"python_hash_seed":os.environ.get("PYTHONHASHSEED", "random"),
              "land_vertices":len(graph),"land_edges":graph.number_of_edges(),
              "sea_vertices":len(sea),"augmented_edges":len(edges),
              "land_degree_conflicts":degree_conflicts(graph.edges,{v:int(r["tiles"]) for v,r in shapes.items()}),
              "augmented_degree_conflicts":degree_conflicts(edges,{v:int(r["tiles"]) for v,r in shapes.items()}),
              "degree_bound":"A connected n-cell square shape has at most 2n+2 boundary edges; this is necessary, not sufficient",
              "connected_component_sizes":sorted(sizes,reverse=True),
              "sea_policy":"One temporary tile per added-edge subdivision; these are not population targets and are removed at export" if sea_regions else
                           "No added regions or contacts; the drawing algorithm adds edges only to its private copy",
              "limit":"Only one portal per border pair is retained. Outer-face choice and enclave containment are not guaranteed. Count and contact checks remain required.",
              "script_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (inputs/"embedding.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(json.dumps(metadata,indent=2))
    return metadata


if __name__ == "__main__":
    if os.environ.get("PYTHONHASHSEED") != "0":
        raise SystemExit("Run with PYTHONHASHSEED=0 for repeatable NetworkX choices")
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs",type=Path)
    parser.add_argument("--rotations",type=Path)
    parser.add_argument("--no-sea",action="store_true",help="Export only original land vertices and contacts")
    args=parser.parse_args()
    run(args.inputs,args.rotations,sea_regions=not args.no_sea)
