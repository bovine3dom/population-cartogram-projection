#!/usr/bin/env python3
"""Translate small shared islands with nearby-island direction constraints."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.optimize import linprog
from scipy.sparse import lil_matrix
from shapely import transform, union_all
from shapely.geometry import shape

from partition_land import contact_groups
from place_islands import tile_contacts
from prepare_flow import equal_earth
from review_layout import load, read_csv
from save_review import digest
from shape_placement import place


def directions(tiles, native, source, fixed, radius_km, minimum_degrees):
    labels=sorted(tiles);centres={c:np.mean(list(points),axis=0) for c,points in tiles.items()}
    extents={c:(np.min(list(points),axis=0),np.max(list(points),axis=0)) for c,points in tiles.items()}
    geographic={c:(g.bounds,g.centroid.coords[0]) for c,g in native.items()};edges=[]
    for i,a in enumerate(labels):
        for b in labels[i+1:]:
            if a in fixed and b in fixed:continue
            if 6371*source[a].distance(source[b])>radius_km:continue
            for axis in range(2):
                delta=geographic[b][1][axis]-geographic[a][1][axis]
                if abs(delta)<minimum_degrees or (axis==0 and abs(delta)>180):continue
                left,right=(a,b) if delta>0 else (b,a)
                separated=geographic[left][0][axis+2]<geographic[right][0][axis]
                centre_bound=int(np.floor(centres[right][axis]-centres[left][axis]-1))
                bound=int(extents[right][0][axis]-extents[left][1][axis]-2) if separated else centre_bound
                edges.append(dict(a=left,b=right,axis=axis,bound=bound,centre_bound=centre_bound,separated=separated))
    return edges


def propose(tiles,fixed,edges,weight,shift_scale):
    labels=sorted(tiles);indices={c:j for j,c in enumerate(labels)};n=len(labels)
    shifts={c:np.zeros(2,dtype=int) for c in labels};records=[]
    if not labels:return shifts,records
    for axis in range(2):
        selected=[e for e in edges if e['axis']==axis];k=len(selected)
        matrix=lil_matrix((2*n+k,2*n+k));rhs=np.zeros(2*n+k);cost=np.zeros(2*n+k);bounds=[]
        for c,j in indices.items():
            limit=int(shift_scale*np.sqrt(len(tiles[c])));bounds.append((0,0) if c in fixed else (-limit,limit))
            cost[n+j]=np.sqrt(len(tiles[c]))
            matrix[2*j,j]=1;matrix[2*j,n+j]=-1;matrix[2*j+1,j]=-1;matrix[2*j+1,n+j]=-1
        bounds += [(0,None)]*(n+k)
        for j,edge in enumerate(selected):
            row=2*n+j;a,b=edge['a'],edge['b']
            matrix[row,indices[a]]=1;matrix[row,indices[b]]=-1;matrix[row,2*n+j]=-1
            rhs[row]=edge['bound'];cost[2*n+j]=weight*np.sqrt(min(len(tiles[a]),len(tiles[b])))
        result=linprog(cost,A_ub=matrix.tocsr(),b_ub=rhs,bounds=bounds,method='highs')
        if not result.success:raise ValueError(result.message)
        for c,j in indices.items():shifts[c][axis]=int(round(result.x[j]))
        records.append(dict(axis=axis,objective=float(result.fun),rounding_error=float(np.max(np.abs(result.x[:n]-np.rint(result.x[:n]))))))
    return shifts,records


def pack(tiles,fixed,edges,shifts,shift_scale):
    result={c:set(tiles[c]) for c in fixed};accepted={c:np.zeros(2,dtype=int) for c in fixed};records=[]
    def halo(points):return {(x+dx,y+dy) for x,y in points for dx,dy in [(0,0),(1,0),(-1,0),(0,1),(0,-1)]}
    blocked=halo(set().union(*result.values()))
    for c in sorted(set(tiles)-fixed,key=lambda c:(-len(tiles[c]),c)):
        limit=int(shift_scale*np.sqrt(len(tiles[c])));bounds=np.array([[-limit,-limit],[limit,limit]],dtype=float)
        for edge in edges:
            a,b,axis,bound=[edge[k] for k in ['a','b','axis','centre_bound']]
            if c==a and b in accepted:bounds[1,axis]=min(bounds[1,axis],accepted[b][axis]+bound)
            elif c==b and a in accepted:bounds[0,axis]=max(bounds[0,axis],accepted[a][axis]-bound)
        if np.any(bounds[0]>bounds[1]):raise ValueError(f'Conflicting island direction bounds: {c}')
        result[c]=place(tiles[c],np.mean(list(tiles[c]),axis=0)+shifts[c],blocked,maximum_radius=512,translation_bounds=bounds)
        accepted[c]=np.asarray(min(result[c]))-np.asarray(min(tiles[c]));blocked.update(halo(result[c]))
        records.append(dict(component=c,translation=accepted[c].tolist(),bounds=bounds.tolist()))
    return result,records


def run(inputs,layout,polygons,output,maximum_area_fraction=.01,minimum_tiles=16,radius_km=1000.,minimum_degrees=3.,weight=10.,shift_scale=6.):
    if output.exists():raise ValueError('Output already exists')
    values=[maximum_area_fraction,radius_km,minimum_degrees,weight,shift_scale]
    if not np.isfinite(values).all() or min(values)<=0 or maximum_area_fraction>=1 or minimum_tiles<1:raise ValueError('Invalid shared-island position settings')
    rows,tiles,owner=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) for c in tiles):raise ValueError('Exact input counts required')
    contacts=read_csv(inputs/'geographic-contacts.csv')
    required={tuple(sorted((r['a'],r['b']))) for r in contacts if r['both_represented']=='true'}
    native={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    if set(native)!=set(tiles):raise ValueError('Source labels differ')
    source={c:transform(g,lambda xy:equal_earth(xy)/1000) for c,g in native.items()};area=sum(g.area for g in source.values())
    groups=[g for g in contact_groups(list(required)) if sum(source[c].area for c in g)<maximum_area_fraction*area and sum(len(tiles[c]) for c in g)>=minimum_tiles]
    movable=set().union(*map(set,groups));groups += [[c] for c in sorted(set(tiles)-movable)]
    members={min(g):g for g in groups};bodies={c:set().union(*(tiles[m] for m in g)) for c,g in members.items()}
    fixed={c for c,g in members.items() if len(g)==1};checked={c:points for c,points in bodies.items() if len(points)>=minimum_tiles}
    edges=directions(checked,{c:union_all([native[m] for m in members[c]]) for c in checked},{c:union_all([source[m] for m in members[c]]) for c in checked},fixed,radius_km,minimum_degrees)
    shifts,solver=propose(checked,fixed,edges,weight,shift_scale)
    placed,packing=pack(bodies,fixed,edges,shifts,shift_scale);result={}
    for c,group in members.items():
        shift=np.asarray(min(placed[c]))-np.asarray(min(bodies[c]))
        if {(x+int(shift[0]),y+int(shift[1])) for x,y in bodies[c]}!=placed[c]:raise AssertionError('Body shape changed')
        for member in group:result[member]={(x+int(shift[0]),y+int(shift[1])) for x,y in tiles[member]}
    after_owner={p:c for c,points in result.items() for p in points};before=tile_contacts(owner);after=tile_contacts(after_owner)
    if len(after_owner)!=sum(map(len,tiles.values())) or after-required-before or after&required!=before&required:raise AssertionError('Overlap or contacts changed')
    if any(result[c]!=tiles[c] for c in set(tiles)-movable):raise AssertionError('Fixed component moved')
    report=dict(method='Small source land-border groups translated as rigid bodies; soft box separation followed by exact-shape packing with centre-order constraints',maximum_area_fraction=maximum_area_fraction,minimum_tiles=minimum_tiles,radius_km=radius_km,minimum_degrees=minimum_degrees,weight=weight,shift_scale=shift_scale,members={c:g for c,g in members.items() if len(g)>1},edges=edges,solver=solver,packing=packing,inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',polygons]},scripts={n:digest(Path(__file__).with_name(n)) for n in ['place_shared_islands.py','partition_land.py','place_islands.py','prepare_flow.py','shape_placement.py']},limit='Experimental. The area threshold is not an island classification. Distance is planar Equal Earth distance times Earth radius. Source centroid order does not prove correct positions. Box separation is a soft target. Each translation axis is bounded separately. A failed packing stops without a layout. No cells or connector paths are added.')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    report['cells_sha256']=digest(output/'cells.csv');(output/'shared-island-positions.json').write_text(json.dumps(report,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=shared-island-positions\ncounts=exact\ncontacts=source-unchanged\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--maximum-area-fraction',type=float,default=.01)
    parser.add_argument('--minimum-tiles',type=int,default=16)
    for name,default in [('radius-km',1000.),('minimum-degrees',3.),('weight',10.),('shift-scale',6.)]:parser.add_argument('--'+name,type=float,default=default)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
