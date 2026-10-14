#!/usr/bin/env python3
"""Report nearby-island segments blocked by land. Do not change the layout."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from shapely import transform
from shapely.geometry import Polygon,shape

from prepare_flow import equal_earth
from restore_archipelagos import clusters
from review_layout import load,read_csv
from save_review import digest


def segment_cells(start,end):
    """Return cells whose interiors the centre-to-centre segment crosses."""
    start=np.asarray(start,dtype=float);end=np.asarray(end,dtype=float);delta=end-start
    cuts=[0.,1.]
    for axis in range(2):
        if not delta[axis]:continue
        low,high=sorted([start[axis],end[axis]])
        boundaries=np.arange(np.floor(low)+.5,high,1.)
        cuts.extend(((boundaries-start[axis])/delta[axis]).tolist())
    cuts=np.unique(cuts)
    return {tuple(np.floor(start+delta*t+.5).astype(int)) for t in (cuts[:-1]+cuts[1:])/2}


def crossings(tiles,owner,edges,land):
    parents={a:np.asarray(sorted(tiles[a])) for a in {r['anchor'] for r in edges}}
    trees={a:cKDTree(points) for a,points in parents.items()};records=[]
    for edge in edges:
        c,a=edge['component'],edge['anchor'];child=np.asarray(sorted(tiles[c]))
        distances,_=trees[a].query(child);k=int(np.argmin(distances));start=child[k]
        candidates=trees[a].query_ball_point(start,float(distances[k])+1e-9)
        end=min((parents[a][j] for j in candidates),key=lambda p:(int(np.sum((p-start)**2)),tuple(p)))
        cells=segment_cells(start,end);blocked={p:owner[p] for p in cells if owner.get(p) in land}
        records.append(dict(component=c,anchor=a,start=start.tolist(),end=end.tolist(),distance=float(np.linalg.norm(end-start)),blocking_components=sorted(set(blocked.values())),blocked_cells=len(blocked)))
    return records


def run(inputs,layout,polygons,output,gap_fraction=.35):
    if output.exists():raise ValueError('Output already exists')
    if not np.isfinite(gap_fraction) or gap_fraction<=0:raise ValueError('Invalid source-gap threshold')
    rows,tiles,owner=load(inputs,layout)
    land={r[k] for r in read_csv(inputs/'geographic-contacts.csv') for k in ['a','b']}&set(tiles)
    source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    if set(source)!=set(tiles):raise ValueError('Source labels differ')
    source={c:transform(Polygon(g.exterior),lambda points:equal_earth(points)/1000) for c,g in source.items()}
    _,edges=clusters(tiles,rows,source,land,gap_fraction)
    records=crossings(tiles,owner,edges,land)
    report=dict(method='Nearest tile-centre segment for each nearby-island parent edge; no layout changes',gap_fraction=gap_fraction,segments_checked=len(records),blocked_segments=sum(bool(r['blocked_cells']) for r in records),segments=records,inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',polygons]},scripts={name:digest(Path(__file__).with_name(name)) for name in ['review_island_separation.py','restore_archipelagos.py','prepare_flow.py']},limit='A blocked segment is a review warning, not proof of a geographic error. The check uses source proximity, not country identity. It omits island pairs outside the threshold and blockers without source land borders. It checks one nearest tile-centre pair with fixed tie-breaking, not all possible paths. No connector cells or lines are added to the layout.')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--gap-fraction',type=float,default=.35)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
