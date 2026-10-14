#!/usr/bin/env python3
"""Compare two tile templates against the full source outline without a display."""
import argparse
import html
import json
from pathlib import Path
import subprocess

import numpy as np
from shapely import affinity, transform, union_all
from shapely.geometry import box, shape

from prepare_flow import equal_earth
from review_layout import load
from save_review import digest


def run(inputs,before,after,polygons,country,output):
    rows,old,_=load(inputs,before);_,new,_=load(inputs,after)
    component=max((c for c in rows if rows[c]['country_id']==country),key=lambda c:(len(old[c]),c))
    source=next(shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id']==component)
    source=transform(source,equal_earth)
    source=affinity.translate(source,-source.centroid.x,-source.centroid.y)
    source=affinity.scale(source,*(2*[np.sqrt(len(old[component])/source.area)]),origin=(0,0))
    lands=[]
    for tiles in [old,new]:
        points=np.array(sorted(tiles[component]),dtype=float);points-=points.mean(axis=0)
        lands.append(union_all([box(x-.5,y-.5,x+.5,y+.5) for x,y in points]))
    bounds=union_all([source]+lands).bounds;x0,y0,x1,y1=bounds;scale=max(x1-x0,y1-y0)
    similarities=[land.intersection(source).area/land.union(source).area for land in lands]
    parts=['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1150">',
        '<rect width="1800" height="1150" fill="#faf9f6"/>',
        f'<text x="40" y="40" font-family="sans-serif" font-size="26">{html.escape(country)}: template cleanup; {len(old[component]):,} tiles</text>',
        '<text x="40" y="70" font-family="sans-serif" font-size="16">Pink: tile shape. Green: full source outline. Shapes are centred and scaled to the same area.</text>']
    for i,(title,land,iou) in enumerate(zip(['Before','After'],lands,similarities)):
        parts.append(f'<text x="{40+900*i}" y="105" font-family="sans-serif" font-size="20">{title}; outline intersection / union: {iou:.4f}</text>')
        parts.append(f'<svg x="{20+900*i}" y="125" width="860" height="980" viewBox="{x0-.02*scale} {-y1-.02*scale} {x1-x0+.04*scale} {y1-y0+.04*scale}"><g transform="scale(1,-1)">')
        parts.append(land.svg(fill_color='#dbadb7',opacity=1).replace('stroke-width="2.0"','stroke-width="0.05"'))
        parts.append(source.boundary.svg().replace('stroke-width="2.0"','stroke-width="0.2"'))
        parts.append('</g></svg>')
    parts.append('<text x="40" y="1130" font-family="sans-serif" font-size="15">Sources: Natural Earth outlines and the prepared population tile budget. This check does not approve world positions.</text></svg>')
    output.mkdir(parents=True,exist_ok=False);(output/'review.svg').write_text('\n'.join(parts)+'\n')
    subprocess.run(['rsvg-convert',str(output/'review.svg'),'-o',str(output/'review.png')],check=True)
    report=dict(component=component,country=country,before_tiles=len(old[component]),after_tiles=len(new[component]),before_outline_iou=similarities[0],after_outline_iou=similarities[1],
        inputs={str(p):digest(p) for p in [inputs/'groups.csv',before/'cells.csv',after/'cells.csv',polygons]},script_sha256=digest(Path(__file__)))
    (output/'metrics.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','before','after','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--country',required=True)
    args=parser.parse_args();run(args.inputs,args.before,args.after,args.polygons,args.country,args.output)
