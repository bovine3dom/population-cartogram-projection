#!/usr/bin/env python3
"""Combine a verified regional block fit with unchanged mainland context."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import subprocess

import networkx as nx
from shapely import affinity, union_all
from shapely.geometry import mapping

from review_flow import draw, read_shapes
from review_layout import read_csv
from run_kontur_planet import clean_overlaps
from save_review import digest


def run(root,regional,output):
    if output.exists():
        raise ValueError('Use a new output directory')
    report_path = regional/'experiment.json'
    report = json.loads(report_path.read_text())
    case = next(r for r in report['cases'] if r['name']=='separator')
    path = regional/'separator/components.geojson'
    if not case['complete'] or case['missing_contacts'] or digest(path)!=case['geometry_sha256']:
        raise ValueError('Regional guide is not verified')
    inputs = root/'world-55000-dissolved-input'
    baseline = root/'kontur-patch-flow-200-floor/blend-0.9/components.geojson'
    native_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    native = read_shapes(native_path)
    rows = {r['component_id']:r for r in read_csv(inputs/'groups.csv')}
    original = read_shapes(baseline)
    scale = math.sqrt(sum(int(rows[c]['tiles']) for c in original)/sum(g.area for g in original.values()))
    original = {c:affinity.scale(g,scale,scale,origin=(0,0)) for c,g in original.items()}
    changed = read_shapes(path)
    if not changed.keys() <= original.keys():
        raise ValueError('Regional guide adds an unknown component')
    shapes = dict(original);shapes.update(changed)
    cuts = {tuple(sorted((r['a'],r['b']))) for r in report['cuts']}
    contacts = read_csv(inputs/'geographic-contacts.csv')
    graph = nx.Graph();graph.add_nodes_from(shapes)
    graph.add_edges_from((r['a'],r['b']) for r in contacts if r['a'] in shapes and r['b'] in shapes and tuple(sorted((r['a'],r['b']))) not in cuts)
    movements = []
    for part in nx.connected_components(graph):
        if part & changed.keys():
            continue
        block = union_all([shapes[c] for c in part])
        occupied = union_all([g for c,g in shapes.items() if c not in part])
        if block.intersection(occupied).area<=1e-6:
            continue
        anchor = min(changed,key=lambda c:min(native[c].distance(native[d]) for d in part))
        dx = changed[anchor].centroid.x-original[anchor].centroid.x
        dy = changed[anchor].centroid.y-original[anchor].centroid.y
        offsets = sorted(((x,y) for x in range(-80,81,2) for y in range(-80,81,2)),key=lambda p:p[0]**2+p[1]**2)
        for x,y in offsets:
            shifted = affinity.translate(block,dx+x,dy+y)
            if shifted.distance(occupied)>=.5:
                break
        else:
            raise ValueError('Cannot place a context group without overlap')
        for c in part:
            shapes[c] = affinity.translate(shapes[c],dx+x,dy+y)
        movements.append(dict(components=sorted(part),anchor=anchor,shift=[dx+x,dy+y]))
    shapes,cleanup = clean_overlaps(shapes)
    output.mkdir(parents=True)
    cut_inputs = output/'inputs'
    shutil.copytree(inputs,cut_inputs)
    with (cut_inputs/'geographic-contacts.csv').open('w',newline='') as stream:
        writer = csv.DictWriter(stream,fieldnames=list(contacts[0]),lineterminator='\n')
        writer.writeheader();writer.writerows(r for r in contacts if tuple(sorted((r['a'],r['b']))) not in cuts)
    geometry = output/'guide.geojson'
    geometry.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in sorted(shapes.items())]),separators=(',',':'))+'\n')
    record = dict(cuts=sorted(cuts),components=len(shapes),movements=movements,cleanup=cleanup,geometry_sha256=digest(geometry),
                  inputs={str(p):digest(p) for p in [report_path,path,baseline,native_path,inputs/'groups.csv',inputs/'geographic-contacts.csv',cut_inputs/'geographic-contacts.csv']},
                  script_sha256=digest(Path(__file__)),limits=['Experimental whole-world mainland guide. No production export.',
                  'Only the regional separator fit replaces the saved mainland shapes. Other groups keep their shapes.',
                  'If a context group overlaps the new region, move the whole group with its nearest source regional anchor, then search nearby empty space.',
                  'A separate contact input removes only the recorded cuts. All tile stages must use that input.',
                  'The source density policy is relaxed. Read the regional record before interpreting the cut set.'])
    (output/'guide-record.json').write_text(json.dumps(record,indent=2)+'\n')
    draw(output/'review.svg',shapes,rows,'World mainland guide: complete early separator',
         f'{len(cuts)} explicit cuts. Uncut regional borders remain. Context groups keep their shapes. No tile fit yet.',
         method='Independent connected-group Kontur flow before assembly.')
    subprocess.run(['rsvg-convert',str(output/'review.svg'),'-o',str(output/'review.png')],check=True)
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('regional',type=Path)
    parser.add_argument('output',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
