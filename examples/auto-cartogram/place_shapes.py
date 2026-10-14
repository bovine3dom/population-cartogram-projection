#!/usr/bin/env python3
"""Place intact source-shaped tile regions near geographic or layout centres."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile
import time

from shapely.geometry import Polygon

from shape_placement import place
from review_layout import load, NEIGHBOURS, connectivity, holes
from save_review import digest


def run(inputs,templates,output,anchors=None,spacing=1.,gap=False,geometry_anchors=None,sites=None):
    if output.exists():raise ValueError('Output already exists')
    if not math.isfinite(spacing) or spacing<=0:raise ValueError('Invalid spacing')
    if sum(value is not None for value in [anchors,geometry_anchors,sites])>1:raise ValueError('Choose one anchor source')
    rows,tiles,_=load(inputs,templates)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 or holes(tiles[c]) for c in rows):
        raise ValueError('Templates must have exact counts, one connected part, and no holes')
    started=time.monotonic()
    if geometry_anchors is not None:
        from review_flow import read_shapes
        geometries=read_shapes(geometry_anchors)
        if set(geometries)!=set(tiles):raise ValueError('Geometry anchor labels differ')
        scale=spacing*math.sqrt(sum(map(len,tiles.values()))/sum(g.area for g in geometries.values()))
        desired={c:(g.centroid.x*scale,g.centroid.y*scale) for c,g in geometries.items()}
    elif anchors is not None:
        _,anchor_tiles,_=load(inputs,anchors)
        desired={c:(sum(x for x,y in p)/len(p)*spacing,sum(y for x,y in p)/len(p)*spacing) for c,p in anchor_tiles.items()}
    else:
        lines=(inputs/'validated.wkt').read_text().splitlines()
        polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
        scale=spacing*math.sqrt(sum(map(len,tiles.values()))/sum(p.area for p in polygons.values()))
        if sites:
            from review_layout import read_csv
            site_rows=read_csv(sites);positions={r['component_id']:(float(r['x']),float(r['y'])) for r in site_rows}
            if len(positions)!=len(site_rows) or set(positions)!=set(tiles):raise ValueError('Site labels differ or repeat')
            if any(not math.isfinite(v) for point in positions.values() for v in point):raise ValueError('Invalid site coordinates')
            desired={c:(x*scale,y*scale) for c,(x,y) in positions.items()}
        else:desired={c:(p.centroid.x*scale,p.centroid.y*scale) for c,p in polygons.items()}
    blocked=set();result={}
    for c in sorted(tiles,key=lambda c:(-len(tiles[c]),c)):
        moved=place(tiles[c],desired[c],blocked);result[c]=moved;blocked.update(moved)
        if gap:blocked.update((x+dx,y+dy) for x,y in moved for dx,dy in NEIGHBOURS)
        print(f'{len(result)}/{len(tiles)}: {c}',flush=True)
    metadata=dict(method='Integer translations of intact source-shaped templates; no border paths',
        spacing=spacing,gap=gap,anchors='continuous geometry' if geometry_anchors else 'layout' if anchors else 'projected sites' if sites else 'source geographic centres',elapsed_seconds=time.monotonic()-started,
        inputs={str(p):digest(p) for p in [templates/'cells.csv',inputs/'validated.wkt',inputs/'groups.csv']+([anchors/'cells.csv'] if anchors else [geometry_anchors] if geometry_anchors else [sites] if sites else [])},
        scripts={p.name:digest(p) for p in [Path(__file__),Path(__file__).with_name('shape_placement.py')] },
        limit='Greedy placement can change geographic order and contacts. Templates omit source holes. Counts and individual tile shapes do not change.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='placed-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        (temp/'placement.json').write_text(json.dumps(metadata,indent=2)+'\n')
        (temp/'complete.txt').write_text('mode=shape-placement\ncounts=exact\ncontacts=not-required\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return metadata


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','templates','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--anchors',type=Path);parser.add_argument('--spacing',type=float,default=1.)
    parser.add_argument('--gap',action='store_true');parser.add_argument('--geometry-anchors',type=Path)
    parser.add_argument('--sites',type=Path,help='CSV with component_id,x,y in Equal Earth coordinates at radius 1')
    args=parser.parse_args();print(json.dumps(run(**vars(args)),indent=2))
