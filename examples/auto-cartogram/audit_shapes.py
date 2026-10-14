#!/usr/bin/env python3
"""Measure thin tile regions and check the source of required land contacts."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_opening, label
from shapely import affinity, transform, union_all
from shapely.geometry import shape, box
from prepare_flow import equal_earth

from review_layout import load, read_csv, quality
from save_review import digest


def thin_shape(cells):
    x0=min(x for x,y in cells)-1; y0=min(y for x,y in cells)-1
    grid=np.zeros((max(y for x,y in cells)-y0+2,max(x for x,y in cells)-x0+2),dtype=bool)
    for x,y in cells: grid[y-y0,x-x0]=True
    opened=binary_opening(grid,structure=np.ones((3,3),dtype=bool))
    narrow=grid & ~opened
    parts,n=label(narrow)
    sizes=np.bincount(parts.ravel())[1:]
    blocks=set()
    for x,y in cells:
        square={(x,y),(x+1,y),(x,y+1),(x+1,y+1)}
        if square <= cells: blocks.update(square)
    return dict(**quality(cells),opening_loss=int(narrow.sum()),opening_loss_share=float(narrow.sum()/len(cells)),
        largest_opening_loss_patch=int(sizes.max()) if n else 0,
        cells_outside_two_by_two=len(cells-blocks))


def outline_similarity(cells,polygon):
    centre=polygon.centroid;n=len(cells)
    target=(sum(x for x,y in cells)/n,sum(y for x,y in cells)/n)
    scale=(n/polygon.area)**.5
    guide=affinity.translate(affinity.scale(affinity.translate(polygon,-centre.x,-centre.y),scale,scale,origin=(0,0)),*target)
    actual=union_all([box(x-.5,y-.5,x+.5,y+.5) for x,y in cells])
    intersection=actual.intersection(guide).area
    return intersection/(actual.area+guide.area-intersection)


def run(inputs, layout, polygons, output, outlines=False):
    if output.exists(): raise ValueError("Output already exists")
    shapes,tiles,_=load(inputs,layout)
    geo={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features']}
    primary={}
    for c,r in shapes.items():
        country=r['country_id']
        if country not in primary or float(r['group_population'])>float(shapes[primary[country]]['group_population']):primary[country]=c
    edges=[]
    for r in read_csv(inputs/'geographic-contacts.csv'):
        if r['both_represented']!='true':continue
        a,b=r['a'],r['b']
        shared=geo[a].boundary.intersection(geo[b].boundary).length
        if shared<=0: raise ValueError(f"Required contact has no shared source border: {a}, {b}")
        edges.append(dict(a=a,b=b,country_a=shapes[a]['country_id'],country_b=shapes[b]['country_id'],
            shared_source_border=True,secondary_component=any(primary[shapes[c]['country_id']]!=c for c in [a,b])))
    regions=[dict(component_id=c,country_id=shapes[c]['country_id'],primary_component=primary[shapes[c]['country_id']]==c,
        requested=int(shapes[c]['tiles']),actual=len(tiles[c]),**thin_shape(tiles[c])) for c in sorted(tiles)]
    if outlines:
        for row in regions:
            c=row['component_id'];row['source_outline_iou']=outline_similarity(tiles[c],transform(geo[c],equal_earth))
    large=[r for r in regions if r['actual']>=25]
    total=sum(r['actual'] for r in large)
    summary=dict(required_contacts=len(edges),same_country_contacts=sum(r['country_a']==r['country_b'] for r in edges),
        contacts_involving_secondary_components=sum(r['secondary_component'] for r in edges),
        opening_loss_share_for_regions_at_least_25_tiles=sum(r['opening_loss'] for r in large)/total if total else None,
        one_cell_detail_share_for_regions_at_least_25_tiles=sum(r['cells_outside_two_by_two'] for r in large)/total if total else None,
        minimum_region_tiles_for_summary=25,
        limit='Opening loss includes natural coasts and narrow countries. It is a diagnostic, not a proof of artificial connectors. Secondary means not the largest population group of its country; it does not mean overseas.',
        inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',polygons]},
        script_sha256=digest(Path(__file__)))
    if outlines:
        summary['tile_weighted_outline_iou_for_regions_at_least_25_tiles']=sum(r['actual']*r['source_outline_iou'] for r in large)/total if total else None
        summary['outline_rule']='Equal Earth source geometry with holes; isotropic scale to actual cell area and translation to cell centroid. No rotation fit. IoU includes raster and source-hole differences.'
    output.mkdir(parents=True)
    for name,data in [('regions.csv',regions),('contacts.csv',edges)]:
        with (output/name).open('w',newline='') as stream:
            if data:
                writer=csv.DictWriter(stream,fieldnames=list(data[0]));writer.writeheader();writer.writerows(data)
    (output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
    return summary


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--outlines',action='store_true')
    args=parser.parse_args();run(args.inputs,args.layout,args.polygons,args.output,args.outlines)
