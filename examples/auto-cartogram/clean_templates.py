#!/usr/bin/env python3
"""Close narrow raster cuts inside source outlines while keeping tile counts."""
import argparse
import csv
import heapq
import json
import math
from pathlib import Path
import shutil
import tempfile

import numpy as np
from scipy.ndimage import binary_closing, binary_fill_holes
from shapely import affinity, contains_xy
from shapely.geometry import Point, Polygon, box

from geographic_baseline import simple_toggle
from review_layout import load, connectivity, holes, NEIGHBOURS
from save_review import digest
from shape_placement import place_all


def clean(cells,polygon):
    count=len(cells);centre=np.mean(list(cells),axis=0)
    guide=affinity.translate(polygon,-polygon.centroid.x,-polygon.centroid.y)
    guide=affinity.scale(guide,*(2*[math.sqrt(count/guide.area)]),origin=(0,0))
    guide=affinity.translate(guide,*centre)
    x0=min(x for x,y in cells)-2;y0=min(y for x,y in cells)-2
    grid=np.zeros((max(y for x,y in cells)-y0+3,max(x for x,y in cells)-x0+3),dtype=bool)
    for x,y in cells:grid[y-y0,x-x0]=True
    yy,xx=np.indices(grid.shape);inside=contains_xy(guide,xx+x0,yy+y0)
    filled=binary_fill_holes(grid | (binary_closing(grid,structure=np.ones((3,3))) & inside))
    yy,xx=np.nonzero(filled);result=set(zip((xx+x0).tolist(),(yy+y0).tolist()))
    if len(result)==count:return set(cells),dict(added=0,removed=0,intersection_gain=0.,accepted=False)
    distance={};queue=[]
    def priority(p):
        if p not in distance:
            point=Point(p);d=guide.boundary.distance(point);distance[p]=d if not guide.contains(point) else -d
        neighbours=sum((p[0]+dx,p[1]+dy) in result for dx,dy in NEIGHBOURS)
        return -distance[p]+.1*(neighbours-2)
    def offer(p):
        if p in result and any((p[0]+dx,p[1]+dy) not in result for dx,dy in NEIGHBOURS):heapq.heappush(queue,(priority(p),p))
    for p in sorted(result):offer(p)
    while len(result)>count and queue:
        score,p=heapq.heappop(queue)
        if p not in result or abs(score-priority(p))>1e-10 or not simple_toggle(result,p):continue
        result.remove(p)
        for dx in [-1,0,1]:
            for dy in [-1,0,1]:offer((p[0]+dx,p[1]+dy))
    if len(result)!=count or connectivity(result)!=1 or holes(result):return set(cells),dict(added=0,removed=0,intersection_gain=0.,accepted=False)
    added=result-cells;removed=cells-result
    intersection=lambda points:sum(box(x-.5,y-.5,x+.5,y+.5).intersection(guide).area for x,y in points)
    gain=intersection(added)-intersection(removed)
    perimeter=lambda points:sum((x+dx,y+dy) not in points for x,y in points for dx,dy in NEIGHBOURS)
    reduction=perimeter(cells)-perimeter(result)
    accepted=gain>1e-8 and reduction>0
    return (result if accepted else set(cells)),dict(added=len(added),removed=len(removed),intersection_gain=gain,perimeter_reduction=reduction,accepted=accepted)


def run(inputs,layout,output):
    if output.exists():raise ValueError('Use a new output directory')
    rows,tiles,_=load(inputs,layout)
    hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'validated.wkt',layout/'cells.csv']}
    scripts={p.name:digest(p) for p in [Path(__file__),Path(__file__).with_name('geographic_baseline.py'),Path(__file__).with_name('shape_placement.py')]}
    lines=(inputs/'validated.wkt').read_text().splitlines()
    polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
    if set(polygons)!=set(tiles):raise ValueError('Outline labels differ')
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 or holes(tiles[c]) for c in rows):raise ValueError('Invalid input templates')
    cleaned={};reports={}
    for c in sorted(tiles):
        cleaned[c],reports[c]=clean(tiles[c],polygons[c])
        if reports[c]['accepted']:print(c,json.dumps(reports[c]),flush=True)
    placed=place_all(cleaned,{c:np.mean(list(tiles[c]),axis=0) for c in tiles},gap=True)
    report=dict(method='Fill narrow interior raster cuts, remove boundary cells to restore exact counts, and retain only source-intersection and perimeter improvements',
        changed_components=sum(r['accepted'] for r in reports.values()),components=reports,inputs=hashes,scripts=scripts,
        limit='Templates can change shape. Source holes remain omitted. The result is a separate-component baseline, not a border-preserving map.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='clean-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(placed.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        (temp/'cleanup.json').write_text(json.dumps(report,indent=2)+'\n')
        (temp/'complete.txt').write_text('mode=geographic-baseline\ncounts=exact\ncontacts=not-preserved\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    args=parser.parse_args();run(args.inputs,args.layout,args.output)
