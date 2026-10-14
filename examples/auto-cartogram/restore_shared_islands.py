#!/usr/bin/env python3
"""Restore small land-border groups from their shared geographic outlines."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.ndimage import distance_transform_edt

from land_envelope import build
from partition_land import contact_groups,partition
from repair_partition import Repair
from review_flow import read_shapes
from review_layout import load,read_csv,connectivity
from save_review import digest
from shape_placement import place


def template(geometry,budgets,sigma=.65,guide=8.):
    """Make one exact-budget landmass; do not add paths to old fragments."""
    # Use the same area scale for all countries on this landmass.
    from shapely import affinity,contains_xy
    scale=np.sqrt(sum(budgets.values())/sum(g.area for g in geometry.values()))
    centre=np.mean([g.centroid.coords[0] for g in geometry.values()],axis=0)
    shapes={c:affinity.scale(affinity.translate(g,-centre[0],-centre[1]),scale,scale,origin=(0,0)) for c,g in geometry.items()}
    tiles={}
    for c,g in shapes.items():
        xmin,ymin,xmax,ymax=g.bounds
        yy,xx=np.mgrid[int(np.floor(ymin)):int(np.ceil(ymax))+1,int(np.floor(xmin)):int(np.ceil(xmax))+1]
        mask=contains_xy(g,xx,yy);tiles[c]=set(zip(xx[mask].tolist(),yy[mask].tolist()))
        if not tiles[c]:
            point=g.representative_point();tiles[c]={(round(point.x),round(point.y))}
    points=np.array(sorted(set().union(*tiles.values())));lower=points.min(axis=0)-16;upper=points.max(axis=0)+16
    origin=tuple(lower.tolist());shape=tuple((upper-lower+1)[::-1].tolist())
    mask,envelope=build(tiles,set(),origin,shape,sigma,count=sum(budgets.values()),dock=True)
    yy,xx=np.nonzero(mask);points=np.column_stack((xx+origin[0],yy+origin[1]));labels=sorted(tiles)
    centres=np.array([shapes[c].centroid.coords[0] for c in labels]);costs=((points[:,None,:]-centres[None,:,:])**2).sum(axis=2)
    for i,c in enumerate(labels):
        raw=np.zeros(shape,dtype=bool)
        for x,y in tiles[c]:raw[y-origin[1],x-origin[0]]=True
        costs[:,i]+=guide*distance_transform_edt(~raw)[yy,xx]**2
    assignment,solver=partition(costs,[budgets[c] for c in labels])
    state=Repair({c:set(map(tuple,points[assignment==i].tolist())) for i,c in enumerate(labels)})
    swaps=[]
    for _ in range(100):
        move=state.step()
        if move is None:break
        swaps.append(move)
    relocations=[]
    for c in sorted(labels,key=lambda c:(-state.fragments(c),c)):
        if len(state.parts[c])>1:relocations.append(state.relocate(c,borrow=True))
    if state.report()['disconnected_regions'] or connectivity(set(state.owners))!=1:raise ValueError('Shared island template is not connected')
    if any(len(state.tiles[c])!=budgets[c] for c in labels):raise AssertionError('Template budget changed')
    return state.tiles,dict(scale=scale,envelope=envelope,solver=solver,swaps=swaps,relocations=relocations)


def run(inputs,layout,geometry,output,maximum_area_fraction=.01,sigma=.65,guide=8.):
    if output.exists():raise ValueError('Output already exists')
    if not np.isfinite([maximum_area_fraction,sigma,guide]).all() or not 0<maximum_area_fraction<1 or sigma<=0 or guide<0:raise ValueError('Invalid shared-island settings')
    rows,tiles,_=load(inputs,layout);budgets={c:int(r['tiles']) for c,r in rows.items()}
    if any(len(points)!=budgets[c] or connectivity(points)!=1 for c,points in tiles.items()):raise ValueError('Exact connected input required')
    source=read_shapes(geometry)
    pairs=[(r['a'],r['b']) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true']
    groups=contact_groups(pairs)
    if any(c not in source for group in groups for c in group):raise ValueError('Missing source land-border component')
    area=sum(source[c].area for group in groups for c in group)
    selected=[group for group in groups if sum(source[c].area for c in group)<=maximum_area_fraction*area]
    selected.sort(key=lambda group:(-sum(budgets[c] for c in group),group))
    movable={c for group in selected for c in group};result={c:set(points) for c,points in tiles.items() if c not in movable}
    blocked={q for points in result.values() for x,y in points for q in [(x,y),(x+1,y),(x-1,y),(x,y+1),(x,y-1)]};records=[]
    for group in selected:
        local,record=template({c:source[c] for c in group},{c:budgets[c] for c in group},sigma,guide)
        union=set().union(*local.values());desired=np.mean(list(set().union(*(tiles[c] for c in group))),axis=0)
        placed=place(union,desired,blocked);shift=np.array(min(placed))-np.array(min(union))
        if {(x+int(shift[0]),y+int(shift[1])) for x,y in union}!=placed:raise AssertionError('Template placement is not a translation')
        for c,points in local.items():result[c]={(x+int(shift[0]),y+int(shift[1])) for x,y in points}
        blocked.update(q for x,y in placed for q in [(x,y),(x+1,y),(x-1,y),(x,y+1),(x,y-1)])
        records.append(dict(components=group,translation=shift.tolist(),source_area_fraction=sum(source[c].area for c in group)/area,template=record))
    if any(len(result[c])!=budgets[c] or connectivity(result[c])!=1 for c in tiles):raise AssertionError('Invalid final component')
    if sum(map(len,result.values()))!=len(set().union(*result.values())):raise AssertionError('Final overlap')
    report=dict(method='Shared geographic templates for small source land-border groups; whole-group translations',maximum_area_fraction=maximum_area_fraction,sigma=sigma,guide=guide,landmasses=records,unchanged_components=sorted(set(tiles)-movable),inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',geometry,layout/'cells.csv']},scripts={n:digest(Path(__file__).with_name(n)) for n in ['restore_shared_islands.py','land_envelope.py','partition_land.py','repair_partition.py','shape_placement.py']},limit='Area threshold is a geometric selection rule, not an island classification. Shared-country boundaries can change. The local partition can lose source borders. Unselected components stay unchanged. No country-identity links or connector paths are added.')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    report['cells_sha256']=digest(output/'cells.csv')
    (output/'shared-islands.json').write_text(json.dumps(report,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=shared-island-templates\ncounts=exact\ncontacts=unconstrained\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','geometry','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--maximum-area-fraction',type=float,default=.01)
    parser.add_argument('--sigma',type=float,default=.65)
    parser.add_argument('--guide',type=float,default=8.)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
