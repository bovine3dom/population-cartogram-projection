#!/usr/bin/env python3
"""Place nearby island groups together without connector cells."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from shapely import STRtree,transform
from shapely.geometry import Polygon,shape

from place_islands import place_islands,tile_contacts
from prepare_flow import equal_earth
from review_layout import load,read_csv
from save_review import digest
from shape_placement import place


def clusters(tiles,rows,source,land,gap_fraction,bridge_groups=False):
    population={c:float(rows[c]['group_population']) for c in tiles};parents={};edges=[];nearest={}
    for c in sorted(set(tiles)-land):
        larger=sorted(a for a in tiles if population[a]>population[c])
        if not larger:continue
        tree=STRtree([source[a] for a in larger]);anchor=min(larger[int(i)] for i in tree.query_nearest(source[c],all_matches=True))
        nearest[c]=anchor;gap=source[c].distance(source[anchor])
        if anchor not in land and gap<=gap_fraction*np.sqrt(source[anchor].area):
            parents[c]=anchor;edges.append(dict(component=c,anchor=anchor,source_gap=gap))
    def root(c):
        while c in parents:c=parents[c]
        return c
    groups={}
    for c in sorted(set(tiles)-land):groups.setdefault(root(c),[]).append(c)
    if bridge_groups:
        changed=True
        while changed:
            changed=False
            for c,members in sorted(list(groups.items()),key=lambda item:(population[item[0]],item[0])):
                anchor=nearest.get(c)
                if anchor is None or anchor in land:continue
                target=root(anchor)
                if target==c:continue
                gap,a,b=min((source[a].distance(source[b]),a,b) for a in members for b in groups[target])
                if gap>gap_fraction*np.sqrt(max(source[a].area,source[b].area)):continue
                parents[c]=target;groups[target].extend(members);del groups[c];changed=True
                edges.append(dict(component=a,anchor=b,source_gap=gap,bridge_roots=[c,target]))
    return {c:sorted(members) for c,members in groups.items()},edges


def separation_bounds(local,tiles,rows,source,land,radius_km):
    """Retain definite source box separations from nearby land components."""
    lower=np.full(2,-np.inf);upper=np.full(2,np.inf);constraints=[]
    land_bounds={}
    for other in land:
        points=np.asarray(list(tiles[other]));land_bounds[other]=(points.min(axis=0),points.max(axis=0))
    for c,points in sorted(local.items()):
        points=np.asarray(list(points));lo=points.min(axis=0);hi=points.max(axis=0)
        for other in sorted(land):
            distance=6371*source[c].distance(source[other])
            if distance>radius_km:continue
            fixed_lo,fixed_hi=land_bounds[other]
            for axis,(low,high) in enumerate([('west','east'),('south','north')]):
                a0,a1=float(rows[c][low]),float(rows[c][high]);b0,b1=float(rows[other][low]),float(rows[other][high])
                if axis==0 and abs((a0+a1-b0-b1)/2)>180:continue
                if a0>b1:
                    bound=int(fixed_hi[axis]+2-lo[axis]);lower[axis]=max(lower[axis],bound);direction='positive'
                elif a1<b0:
                    bound=int(fixed_lo[axis]-2-hi[axis]);upper[axis]=min(upper[axis],bound);direction='negative'
                else:continue
                constraints.append(dict(component=c,land_component=other,axis=axis,direction=direction,translation_bound=bound,approximate_source_distance_km=distance))
    return np.array([lower,upper]),constraints


def run(inputs,layout,polygons,output,gap_fraction=.2,land_radius_km=500.,minimum_tiles=16,maximum_shift_scale=2.,bridge_groups=False):
    if output.exists():raise ValueError('Output already exists')
    if not np.isfinite([gap_fraction,land_radius_km,maximum_shift_scale]).all() or min(gap_fraction,land_radius_km,maximum_shift_scale)<=0 or minimum_tiles<1:raise ValueError('Invalid archipelago settings')
    rows,tiles,owner=load(inputs,layout)
    if any(len(points)!=int(rows[c]['tiles']) for c,points in tiles.items()):raise ValueError('Exact input budgets required')
    contacts=read_csv(inputs/'geographic-contacts.csv');land={r[k] for r in contacts for k in ['a','b']}&set(tiles)
    required={tuple(sorted((r['a'],r['b']))) for r in contacts if r['both_represented']=='true'};before=tile_contacts(owner)
    source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    source={c:transform(Polygon(g.exterior),lambda points:equal_earth(points)/1000) for c,g in source.items()}
    if set(source)!=set(tiles):raise ValueError('Source labels differ')
    groups,edges=clusters(tiles,rows,source,land,gap_fraction,bridge_groups)
    groups={root:members for root,members in groups.items() if len(members)>1 and sum(len(tiles[c]) for c in members)>=minimum_tiles}
    lines=(inputs/'validated.wkt').read_text().splitlines()
    area=sum(Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]).area for i in range(2,len(lines),3))
    total=sum(map(len,tiles.values()));scale=np.sqrt(total/area);result={c:set(points) for c,points in tiles.items()};records=[]
    for root,members in sorted(groups.items(),key=lambda item:(-sum(len(tiles[c]) for c in item[1]),item[0])):
        local,anchors=place_islands({c:tiles[c] for c in members},{c:rows[c] for c in members},{c:source[c] for c in members},{root},scale,.1*np.sqrt(total))
        bounds,constraints=separation_bounds(local,result,rows,source,land,land_radius_km)
        record=dict(root=root,components=members,coast_anchors=anchors,separation_constraints=constraints,translation_bounds=[[float(v) if np.isfinite(v) else None for v in row] for row in bounds]);records.append(record)
        if np.any(bounds[0]>bounds[1]):record['not_moved']='Inconsistent geographic separation bounds';continue
        occupied={point for c,points in result.items() if c not in members for point in points}
        blocked=occupied|{(x+dx,y+dy) for x,y in occupied for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]}
        union=set().union(*local.values());desired=np.mean(list(set().union(*(tiles[c] for c in members))),axis=0)
        try:moved=place(union,desired,blocked,maximum_radius=512,translation_bounds=bounds)
        except ValueError as error:record['not_moved']=str(error);continue
        shift=np.asarray(min(moved))-np.asarray(min(union))
        if {(x+int(shift[0]),y+int(shift[1])) for x,y in union}!=moved:raise AssertionError('Group placement is not a translation')
        limit=maximum_shift_scale*np.sqrt(sum(len(tiles[c]) for c in members))
        record.update(proposed_translation=shift.tolist(),maximum_translation=limit)
        if np.linalg.norm(shift)>limit:record['not_moved']='Group translation exceeds displacement limit';continue
        for c,points in local.items():result[c]={(x+int(shift[0]),y+int(shift[1])) for x,y in points}
        record['group_translation']=shift.tolist()
    for c,points in result.items():
        shift=np.asarray(min(points))-np.asarray(min(tiles[c]))
        if {(x+int(shift[0]),y+int(shift[1])) for x,y in tiles[c]}!=points:raise AssertionError('Island shape changed')
    if any(result[c]!=tiles[c] for c in land):raise AssertionError('Mainland moved')
    after_owner={p:c for c,points in result.items() for p in points};after=tile_contacts(after_owner)
    if len(after_owner)!=total or after-required-before or after&required!=before&required:raise AssertionError('Overlap or source contacts changed')
    report=dict(method='Nearby island groups placed together with source-axis separation from nearby land; no country-identity links',gap_fraction=gap_fraction,land_radius_km=land_radius_km,minimum_tiles=minimum_tiles,maximum_shift_scale=maximum_shift_scale,bridge_groups=bridge_groups,cluster_edges=edges,groups=records,moved_components=sum(result[c]!=tiles[c] for c in tiles),failed_groups=sum('not_moved' in r for r in records),inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',inputs/'validated.wkt',layout/'cells.csv',polygons]},scripts={name:digest(Path(__file__).with_name(name)) for name in ['restore_archipelagos.py','place_islands.py','shape_placement.py','prepare_flow.py']},limit='Proximity groups can cross country IDs. No cells join separate islands. Nearby-land distances use Equal Earth planar distance times Earth radius, not geodesic distance. Inconsistent or blocked groups remain unchanged and are reported. Preserving axis separation does not prove good geographic placement.')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    report['cells_sha256']=digest(output/'cells.csv');(output/'archipelagos.json').write_text(json.dumps(report,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=archipelago-placement\ncounts=exact\ncontacts=land-unchanged\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--gap-fraction',type=float,default=.2)
    parser.add_argument('--land-radius-km',type=float,default=500.)
    parser.add_argument('--minimum-tiles',type=int,default=16)
    parser.add_argument('--maximum-shift-scale',type=float,default=2.)
    parser.add_argument('--bridge-groups',action='store_true',help='Merge nearby groups along existing larger-island parent choices; retain roots attached to land')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
