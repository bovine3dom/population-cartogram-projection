#!/usr/bin/env python3
"""Place isolated components near an eligible source component's coast."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile

import numpy as np
from shapely import STRtree, transform
from shapely.geometry import Polygon, shape
from shapely.ops import nearest_points

from coast_anchors import template_point
from prepare_flow import equal_earth
from review_layout import load, read_csv, connectivity, holes
from save_review import digest
from shape_placement import place


def place_islands(tiles,rows,source,land_components,scale,ocean_length,maximum_population=None,fixed_land_anchors=False):
    population={c:float(rows[c]['group_population']) for c in tiles}
    if maximum_population is not None:land_components=land_components|{c for c in tiles if population[c]>=maximum_population}
    local={c:np.array(sorted(points),dtype=float) for c,points in tiles.items()}
    centres={c:points.mean(axis=0) for c,points in local.items()}
    local={c:points-centres[c] for c,points in local.items()}
    factors={c:np.sqrt(len(tiles[c])/source[c].area) for c in tiles}
    source_centres={c:np.array(p.centroid.coords[0]) for c,p in source.items()}
    result={c:set(points) for c,points in tiles.items() if c in land_components}
    occupied=set().union(*result.values()) if result else set()
    blocked=occupied|{(x+dx,y+dy) for x,y in occupied for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]}
    records=[]
    for c in sorted(set(tiles)-land_components,key=lambda c:(-population[c],c)):
        larger=sorted(a for a in tiles if population[a]>population[c] or (fixed_land_anchors and a in land_components))
        target=centres[c];anchor=None;source_gap=None;mapped_gap=None
        if larger:
            tree=STRtree([source[a] for a in larger])
            anchor=min(larger[int(i)] for i in tree.query_nearest(source[c],all_matches=True))
            pa,pb=nearest_points(source[anchor].boundary,source[c].boundary)
            pa=np.array(pa.coords[0]);pb=np.array(pb.coords[0]);gap=(pb-pa)*scale
            source_gap=float(np.linalg.norm(gap))
            if ocean_length and source_gap:gap*=ocean_length*np.arcsinh(source_gap/ocean_length)/source_gap
            mapped_gap=float(np.linalg.norm(gap))
            offsets=[template_point(local[a],(point-source_centres[a])*factors[a]) for a,point in [(anchor,pa),(c,pb)]]
            anchor_centre=np.mean(list(result[anchor]),axis=0)
            target=anchor_centre+offsets[0]-offsets[1]+gap
        moved=place(tiles[c],target,blocked);result[c]=moved
        blocked.update(moved);blocked.update((x+dx,y+dy) for x,y in moved for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)])
        actual=np.mean(list(moved),axis=0)
        records.append(dict(component_id=c,anchor=anchor,source_gap_tiles=source_gap,mapped_gap_tiles=mapped_gap,
            desired_x=float(target[0]),desired_y=float(target[1]),actual_x=float(actual[0]),actual_y=float(actual[1]),
            placement_shift=float(np.linalg.norm(actual-target))))
    return result,records


def tile_contacts(owner):
    return {tuple(sorted((c,owner[q]))) for (x,y),c in owner.items() for q in [(x+1,y),(x,y+1)] if q in owner and owner[q]!=c}


def run(inputs,layout,polygons,output,ocean_scale=.1,max_population_fraction=.01,allow_partial_counts=False,preserve_mainland_defects=False,fixed_land_anchors=False):
    if output.exists() or not np.isfinite(ocean_scale) or ocean_scale<0 or not 0<max_population_fraction<=1:raise ValueError('Use a new output, a nonnegative ocean scale, and a population fraction in (0,1]')
    rows,tiles,owner=load(inputs,layout)
    error=sum(abs(len(tiles[c])-int(rows[c]['tiles'])) for c in rows)
    if error and not allow_partial_counts:raise ValueError('Input counts are partial; enable explicitly')
    contacts=read_csv(inputs/'geographic-contacts.csv')
    required={tuple(sorted((r['a'],r['b']))) for r in contacts if r['both_represented']=='true'}
    actual=tile_contacts(owner)
    land_components={r[k] for r in contacts for k in ['a','b']}
    maximum_population=max_population_fraction*sum(float(r['group_population']) for r in rows.values())
    fixed=(land_components&set(tiles))|{c for c in tiles if float(rows[c]['group_population'])>=maximum_population}
    invalid={c for c in rows if connectivity(tiles[c])!=1 or holes(tiles[c])}
    if invalid-(fixed if preserve_mainland_defects else set()):raise ValueError('Invalid input shapes')
    if actual-required and not preserve_mainland_defects:raise ValueError('Initial layout has false contacts')
    source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    source={c:transform(Polygon(p.exterior),lambda points:equal_earth(points)/1000) for c,p in source.items()}
    lines=(inputs/'validated.wkt').read_text().splitlines()
    area=sum(Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]).area for i in range(2,len(lines),3))
    total=sum(map(len,tiles.values()));scale=np.sqrt(total/area);ocean_length=ocean_scale*np.sqrt(total)
    parent_files=[layout/name for name in ['stress.json','relax.json','placement.json','compact.json','partition.json','parent-partition.json','repair-partition.json'] if (layout/name).exists()]
    parent_records={p.name:json.loads(p.read_text()) for p in parent_files}
    for record in list(parent_records.values()):
        for name,expected in record.get('inputs',{}).items():
            p=Path(name)
            if p.name!='stress.json':continue
            if digest(p)!=expected:raise ValueError('Parent position record changed')
            parent_files.append(p);parent_records['initial-stress.json']=json.loads(p.read_text())
    hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',inputs/'validated.wkt',layout/'cells.csv',polygons]+parent_files}
    scripts={p.name:digest(p) for p in [Path(__file__)]+[Path(__file__).with_name(n) for n in ['coast_anchors.py','shape_placement.py','prepare_flow.py']]}
    result,records=place_islands(tiles,rows,source,land_components,scale,ocean_length,maximum_population,fixed_land_anchors)
    new_owner={p:c for c,points in result.items() for p in points};after=tile_contacts(new_owner)
    if len(new_owner)!=total or any(len(result[c])!=len(tiles[c]) for c in tiles):raise AssertionError('Counts or overlap changed')
    if any(result[c]!=tiles[c] for c in fixed):raise AssertionError('Fixed mainland changed')
    if after-required-actual or after&required!=actual&required:raise AssertionError('Island placement changed source borders or added false contacts')
    report=dict(method='Keep components with source land borders or population at or above the threshold fixed. Place smaller isolated components from largest population to smallest, near the nearest eligible source coast. Larger components are eligible; fixed components are also eligible when fixed_land_anchors is enabled. No country-membership links.',fixed_land_anchors=fixed_land_anchors,
        max_population_fraction=max_population_fraction,maximum_population=maximum_population,absolute_tile_error=error,allow_partial_counts=allow_partial_counts,preserve_mainland_defects=preserve_mainland_defects,unchanged_invalid_fixed_components=sorted(invalid&fixed),initial_false_contacts=len(actual-required),final_false_contacts=len(after-required),source_contacts_unchanged=True,eligible_isolated_components=len(records),moved_components=sum(result[c]!=tiles[c] for c in tiles),
        ocean_scale=ocean_scale,maximum_placement_shift=max((r['placement_shift'] for r in records),default=0.),
        inputs=hashes,scripts=scripts,parent_layout_records=parent_records,limit='A nearest-coast hierarchy is a position heuristic, not a proof of correct geography. Counts and tile shapes are unchanged. No native-resolution transport is approved.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='islands-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        with (temp/'island-anchors.csv').open('w',newline='') as stream:
            if records:
                writer=csv.DictWriter(stream,fieldnames=list(records[0]));writer.writeheader();writer.writerows(records)
        (temp/'island-placement.json').write_text(json.dumps(report,indent=2)+'\n')
        (temp/'complete.txt').write_text(f'mode=island-placement\ncounts={"partial" if error else "exact"}\ncontacts=land-unchanged\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--ocean-scale',type=float,default=.1)
    parser.add_argument('--max-population-fraction',type=float,default=.01)
    parser.add_argument('--allow-partial-counts',action='store_true')
    parser.add_argument('--fixed-land-anchors',action='store_true',help='Allow a nearer fixed coast to anchor an island even when its population is smaller')
    parser.add_argument('--preserve-mainland-defects',action='store_true',help='Allow existing defects in fixed mainlands; do not add false contacts')
    run(**vars(parser.parse_args()))
