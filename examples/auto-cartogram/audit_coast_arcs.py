#!/usr/bin/env python3
"""Compare the land-border neighbours at each end of a source or tile sea coast."""
import argparse
import json
from itertools import groupby
from pathlib import Path

import numpy as np
from shapely import STRtree, line_interpolate_point, transform
from shapely.geometry import Polygon, shape

from prepare_flow import equal_earth
from review_geography import exterior_water
from review_layout import load
from save_review import digest

SEA = 'SEA'
WATER = 'ENCLOSED_WATER'


def runs(labels):
    result = []
    for label in labels:
        if not result or result[-1] != label:result.append(label)
    if len(result) > 1 and result[0] == result[-1]:result.pop()
    return result


def coast_pairs(labels):
    sequence = runs(labels)
    if sequence == [SEA]:return [(SEA, SEA)]
    return [tuple(sorted((sequence[i-1], sequence[(i+1) % len(sequence)])))
            for i, label in enumerate(sequence) if label == SEA]


def tile_loops(points, owner, ocean):
    # Directed unit edges keep land on the left. At a touching corner, keep
    # the leftmost outgoing edge rather than crossing to a diagonal tile.
    edges = {}
    for x, y in points:
        sides = [((x+1,y),(2*x+1,2*y-1),(2*x+1,2*y+1)),
                 ((x,y+1),(2*x+1,2*y+1),(2*x-1,2*y+1)),
                 ((x-1,y),(2*x-1,2*y+1),(2*x-1,2*y-1)),
                 ((x,y-1),(2*x-1,2*y-1),(2*x+1,2*y-1))]
        for q, a, b in sides:
            if q not in points:
                edges[a,b] = SEA if q in ocean else owner.get(q, WATER)
    outgoing = {}
    for a,b in edges:outgoing.setdefault(a, []).append(b)
    remaining = set(edges); loops = []
    directions = {(2,0):0, (0,2):1, (-2,0):2, (0,-2):3}
    while remaining:
        start = min(remaining); edge = start; loop = []
        while True:
            remaining.remove(edge);a,b = edge
            dx,dy=b[0]-a[0],b[1]-a[1]
            loop.append(dict(a=a, b=b, outside=((a[0]+b[0]+dy)//4,(a[1]+b[1]-dx)//4), neighbour=edges[edge]))
            incoming = directions[b[0]-a[0], b[1]-a[1]]
            choices = [(b,c) for c in outgoing[b] if (b,c) in remaining or (b,c) == start]
            def rank(e):
                turn = (directions[e[1][0]-b[0],e[1][1]-b[1]]-incoming) % 4
                return ({1:0, 0:1, 3:2, 2:3}[turn], e)
            edge = min(choices, key=rank)
            if edge == start:break
        loops.append(loop)
    return loops


def sea_runs(loop):
    pivot=next((i for i,e in enumerate(loop) if e['neighbour']!=SEA),None)
    if pivot is None:return [dict(neighbours=(SEA,SEA),water_cells=sorted({e['outside'] for e in loop}),edges=len(loop))]
    ordered=loop[pivot:]+loop[:pivot]
    groups=[(label,list(items)) for label,items in groupby(ordered,key=lambda e:e['neighbour'])]
    return [dict(neighbours=tuple(sorted((groups[i-1][0],groups[(i+1)%len(groups)][0]))),
                 water_cells=sorted({e['outside'] for e in items}),edges=len(items))
            for i,(label,items) in enumerate(groups) if label==SEA]


def source_sequences(polygons, targets, samples=8192, tolerance=5e-6):
    features = json.loads(polygons.read_text())['features']
    labels = [f['properties']['component_id'] for f in features]
    geometries = [transform(Polygon(shape(f['geometry']).exterior), lambda xy: equal_earth(xy)/1000) for f in features]
    tree = STRtree(geometries);result = {}
    for target in targets:
        i = labels.index(target)
        points = line_interpolate_point(geometries[i].exterior, (np.arange(samples)+.5)/samples, normalized=True)
        hits = tree.query(points, predicate='dwithin', distance=tolerance)
        neighbours = [set() for _ in range(samples)]
        for p,j in zip(*hits):
            if j != i:neighbours[int(p)].add(labels[int(j)])
        sequence = [min(n) if n else SEA for n in neighbours]
        result[target] = dict(sequence=runs(sequence), coast_neighbour_pairs=coast_pairs(sequence),
                              ambiguous_samples=sum(len(n)>1 for n in neighbours))
    return result


def run(inputs, layout, polygons, output, targets, samples=8192):
    if output.exists() or samples < 16:raise ValueError('Use a new output and sufficient samples')
    _, tiles, owner = load(inputs, layout)
    source = source_sequences(polygons, targets, samples)
    ocean = exterior_water(owner); records = {}
    for c in targets:
        loops = tile_loops(tiles[c], owner, ocean)
        allowed = {tuple(p) for p in source[c]['coast_neighbour_pairs']}
        records[c] = dict(source=source[c], tile_loops=[], unsupported_coast_arcs=[])
        for index, loop in enumerate(loops):
            sequence = runs([e['neighbour'] for e in loop])
            pairs = coast_pairs(sequence)
            records[c]['tile_loops'].append(dict(sequence=sequence, coast_neighbour_pairs=pairs))
            records[c]['unsupported_coast_arcs'].extend(dict(loop=index, **arc) for arc in sea_runs(loop) if arc['neighbours'] not in allowed)
    report = dict(samples=samples, components=records,
                  inputs={str(p):digest(p) for p in [inputs/'groups.csv',layout/'cells.csv',polygons]},
                  script_sha256=digest(Path(__file__)),
                  limits=['Compare cyclic coast runs, not compass directions. Bays can face any direction.',
                          'Finite source sampling and tolerance can miss short borders or narrow water gaps.',
                          'Inter-component source lakes can appear as sea. This is a review diagnostic, not an ocean-basin proof.'])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('inputs','layout','polygons','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--targets',nargs='+',required=True)
    parser.add_argument('--samples',type=int,default=8192)
    run(**vars(parser.parse_args()))
