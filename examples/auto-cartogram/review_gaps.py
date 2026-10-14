#!/usr/bin/env python3
"""Measure empty-space proxies and draw their locations, including open gaps."""
import argparse
import csv
import html
import json
import math
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_closing, binary_fill_holes, label

from save_review import digest
from review_layout import country_color


def read_cells(path,owid=False):
    with path.open(newline='') as stream:
        if owid:rows=[(int(x),int(y),c) for x,y,c in csv.reader(stream)]
        else:rows=[(int(r['x']),int(r['y']),r['component_id']) for r in csv.DictReader(stream)]
    if not rows:raise ValueError('Empty layout')
    steps=[]
    for axis in (0,1):
        values=sorted({r[axis] for r in rows})
        steps.append(math.gcd(*(b-a for a,b in zip(values,values[1:]))) or 1)
    # OWID uses a two-unit square lattice. Generator cells already use unit steps.
    step=math.gcd(*steps) if owid else 1
    x0=min(x for x,y,c in rows);y0=min(y for x,y,c in rows)
    owners={};conflicts=set();duplicates=set()
    for x,y,c in rows:
        p=((x-x0)//step,(-1 if owid else 1)*(y-y0)//step)
        if p in owners:
            duplicates.add(p)
            if owners[p]!=c:conflicts.add(p)
        owners[p]=c
    if duplicates and not owid:raise ValueError('Overlapping cells')
    return owners,dict(input_grid_step=step,input_rows=len(rows),duplicate_coordinates=len(duplicates),conflicting_coordinates=len(conflicts))


def measure(owners,radii=(1,2,4,8)):
    if not owners or any(r<1 for r in radii):raise ValueError('Need cells and positive radii')
    pad=max(radii)+2;x0=min(x for x,y in owners)-pad;y0=min(y for x,y in owners)-pad
    shape=(max(y for x,y in owners)-y0+pad+1,max(x for x,y in owners)-x0+pad+1)
    land=np.zeros(shape,dtype=bool)
    for x,y in owners:land[y-y0,x-x0]=True
    enclosed=binary_fill_holes(land)&~land
    labels,count=label(enclosed);sizes=np.bincount(labels.ravel())[1:]
    coast=sum((x+dx,y+dy) not in owners for x,y in owners for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)])
    masks={};scales=[]
    for radius in radii:
        yy,xx=np.mgrid[-radius:radius+1,-radius:radius+1]
        closed=binary_closing(land,structure=xx*xx+yy*yy<=radius*radius)
        added=closed&~land;masks[radius]=added
        scales.append(dict(radius_tiles=radius,radius_over_sqrt_land=radius/math.sqrt(len(owners)),
            added_empty_cells=int(added.sum()),added_over_land=float(added.sum()/len(owners)),
            open_empty_cells=int((added&~enclosed).sum())))
    report=dict(tiles=len(owners),enclosed_empty_regions=int(count),enclosed_empty_cells=int(enclosed.sum()),
        largest_enclosed_empty_region=int(sizes.max()) if count else 0,
        land_sea_edges=coast,land_sea_edges_over_sqrt_land=coast/math.sqrt(len(owners)),closing=scales,
        limit='Empty-space proxies, not a classification of phantom holes. Real lakes, straits, bays, and ocean gaps can be counted. Compare the masks visually. No country labels or source coast geometry enter these measurements.')
    return report,land,enclosed,masks,(x0,y0)


def draw(path,land,enclosed,masks,title):
    width=1500;height=1000;scale=min((width-40)/land.shape[1],(height-150)/land.shape[0])
    parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        '<rect width="100%" height="100%" fill="#faf9f6"/>',
        f'<text x="20" y="35" font-family="sans-serif" font-size="24">{html.escape(title)}</text>',
        '<text x="20" y="65" font-family="sans-serif" font-size="16">Grey: land. Red: enclosed empty space. Orange: closing proxy, including open gaps. Not all marked water is artificial.</text>']
    for mask,color in [(land,'#666'),(masks[max(masks)],'#e9a23b'),(enclosed,'#c53b40')]:
        yy,xx=np.nonzero(mask)
        commands=[f'M{20+x*scale:.3f},{100+(land.shape[0]-1-y)*scale:.3f}h{scale:.3f}v{scale:.3f}h-{scale:.3f}z' for y,x in zip(yy,xx)]
        parts.append(f'<path fill="{color}" d="{" ".join(commands)}"/>')
    path.write_text('\n'.join(parts)+'</svg>\n')


def draw_layout(path,owners,title,names,country_ids):
    width,height=1800,1120
    xmin=min(x for x,y in owners)-1;xmax=max(x for x,y in owners)+1
    ymin=min(y for x,y in owners)-1;ymax=max(y for x,y in owners)+1
    scale=min((width-80)/(xmax-xmin),(height-150)/(ymax-ymin))
    tx=lambda x:40+(x-xmin)*scale;ty=lambda y:110+(ymax-y)*scale
    countries={}
    for p,c in owners.items():countries.setdefault(country_ids.get(c,c),set()).add(p)
    parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        '<rect width="100%" height="100%" fill="#faf9f6"/>',
        f'<text x="40" y="40" font-family="sans-serif" font-size="27">{html.escape(title)}</text>',
        '<text x="40" y="70" font-family="sans-serif" font-size="16">Layout comparison only. Country colours and population scope can differ. See the numeric checks.</text>']
    for c,points in sorted(countries.items()):
        commands=[f'M{tx(x-.5):.3f},{ty(y+.5):.3f}h{scale:.3f}v{scale:.3f}h-{scale:.3f}z' for x,y in sorted(points)]
        parts.append(f'<path fill="{country_color(c)}" d="{" ".join(commands)}"/>')
    boxes=[]
    for c,points in sorted(countries.items(),key=lambda item:(-len(item[1]),item[0])):
        if len(points)*scale*scale<1200:continue
        cx=sum(x for x,y in points)/len(points);cy=sum(y for x,y in points)/len(points)
        x,y=min(points,key=lambda p:((p[0]-cx)**2+(p[1]-cy)**2,p))
        text=names.get(c,c);px,py=tx(x),ty(y);half=len(text)*3.5
        box=(px-half,py-10,px+half,py+4)
        if any(not(box[2]<b[0] or b[2]<box[0] or box[3]<b[1] or b[3]<box[1]) for b in boxes):continue
        boxes.append(box)
        parts.append(f'<text x="{px:.3f}" y="{py:.3f}" text-anchor="middle" font-family="sans-serif" font-size="12" paint-order="stroke" stroke="#faf9f6" stroke-width="2">{html.escape(text)}</text>')
    path.write_text('\n'.join(parts)+'</svg>\n')


def run(cells,output,owid=False,title='Empty-space review',radii=(1,2,4,8),names=None,groups=None):
    if output.exists():raise ValueError('Output already exists')
    hashes=dict(cells_sha256=digest(cells),script_sha256=digest(Path(__file__)))
    labels={};country_ids={}
    if groups:
        hashes['groups_sha256']=digest(groups)
        with groups.open(newline='') as stream:country_ids={r['component_id']:r['country_id'] for r in csv.DictReader(stream)}
    if names:
        hashes['names_sha256']=digest(names)
        with names.open(newline='') as stream:labels={str(int(r['code'])):r['name'] for r in csv.DictReader(stream)}
    owners,source=read_cells(cells,owid);report,land,enclosed,masks,origin=measure(owners,radii)
    report.update(**hashes,**source,owid=owid)
    output.mkdir(parents=True)
    (output/'gaps.json').write_text(json.dumps(report,indent=2)+'\n')
    draw(output/'gaps.svg',land,enclosed,masks,title)
    draw_layout(output/'layout.svg',owners,title,labels,country_ids)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cells',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--owid',action='store_true');parser.add_argument('--title',default='Empty-space review')
    parser.add_argument('--radii',type=int,nargs='+',default=[1,2,4,8]);parser.add_argument('--names',type=Path);parser.add_argument('--groups',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
