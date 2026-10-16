#!/usr/bin/env python3
"""Test source-guided coastal cover without changing any component budget."""
import argparse
import heapq
import csv
import json
from pathlib import Path
import shutil

from audit_coast_arcs import tile_loops, sea_runs
from compact_regions import adjacent
from dock_true_borders import contacts
from lake_vacancies import VacancyLayout
from restore_reference_water import enclosed
from review_geography import exterior_water, water_edges
from review_layout import connectivity, load, read_csv
from save_review import digest


def shield(tiles, required, inland, cover, mandatory, band=2):
    owner={p:c for c,points in tiles.items() for p in points}
    original_contacts=contacts(owner); ocean=exterior_water(owner)
    mandatory=set(mandatory)
    if not mandatory or not mandatory<=ocean or cover in inland:
        raise ValueError('Use exterior-water cells and a coastal cover component')
    allowed=set(mandatory)
    for _ in range(band):allowed|={q for p in allowed for q in adjacent(p) if q in ocean}
    allowed={p for p in allowed if all(owner.get(q) in (None,cover)
             or tuple(sorted((cover,owner[q]))) in required|original_contacts for q in adjacent(p))}
    if not mandatory<=allowed:raise ValueError('Required cover would create a false border')
    starts=sorted(p for p in allowed if any(owner.get(q)==cover for q in adjacent(p)))
    previous={p:None for p in starts}
    distance={p:(int(p not in mandatory),1) for p in starts}
    queue=[(*distance[p],p) for p in starts];heapq.heapify(queue)
    while queue:
        cost,hops,p=heapq.heappop(queue)
        if (cost,hops)!=distance[p]:continue
        for q in adjacent(p):
            candidate=(cost+int(q not in mandatory),hops+1)
            if q in allowed and (q not in distance or candidate<distance[q]):
                distance[q]=candidate;previous[q]=p;heapq.heappush(queue,(*candidate,q))
    if not mandatory<=previous.keys():raise ValueError('Coastal band cannot reach every required cell')
    added=set()
    for p in sorted(mandatory):
        while p is not None and p not in added:added.add(p);p=previous[p]
    trial=dict(tiles);trial[cover]=tiles[cover]|added
    state=VacancyLayout(trial,required,inland)
    water=enclosed(owner)
    if enclosed(state.owners)!=water:raise ValueError('Cover encloses or removes existing water')
    pinned={q for p in water for q in adjacent(p)}-water
    removed=[]
    for _ in added:
        choices=[]
        for p in (tiles[cover]&state.tiles[cover])-pinned:
            neighbours=adjacent(p)
            if not any(q in state.exterior for q in neighbours):continue
            if any(state.owners.get(q) not in (None,cover) for q in neighbours):continue
            degree=sum(state.owners.get(q)==cover for q in neighbours)
            distance=min(abs(p[0]-q[0])+abs(p[1]-q[1]) for q in mandatory)
            choices.append((degree,-distance,p))
        for _,_,p in sorted(choices):
            undo=state.update({p:None})
            if connectivity(state.tiles[cover])!=1:
                state.update(undo);continue
            state.exterior.add(p);removed.append(p);break
        else:raise ValueError('Insufficient removable coastal cover cells')
    after=contacts(state.owners)
    if (original_contacts&required)-after or after-required-original_contacts:raise AssertionError('Border regression')
    if enclosed(state.owners)!=water:raise AssertionError('Enclosed water changed')
    assert all(len(state.tiles[c])==len(tiles[c]) for c in tiles)
    assert all(state.owners.get(q)==owner.get(q) for q in pinned)
    before_coast=water_edges(tiles,owner,ocean)
    after_coast=water_edges(state.tiles,state.owners,exterior_water(state.owners))
    if any(after_coast[c]['exterior_water_edges']>before_coast[c]['exterior_water_edges'] for c in inland & set(tiles)):
        raise ValueError('Another inland coast grew')
    if any(before_coast[c]['exterior_water_edges'] and not after_coast[c]['exterior_water_edges'] for c in set(tiles)-inland):
        raise ValueError('A source coastal component lost sea access')
    return state.tiles,dict(cover=cover,added=sorted(added),removed=removed,
                           gained_true=sorted((after&required)-original_contacts))


def run(inputs,layout,source_coasts,coast_audit,output,target,cover,band=2):
    if output.exists() or band<0:raise ValueError('Use a new output and non-negative band')
    rows,tiles,owner=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 for c in tiles):
        raise ValueError('Exact connected starting components required')
    audit=json.loads(coast_audit.read_text())
    if audit['inputs'].get(str(layout/'cells.csv'))!=digest(layout/'cells.csv'):raise ValueError('Coast audit layout differs')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    inland={r['component_id'] for r in read_csv(source_coasts) if int(r['uncovered_samples'])==0}
    allowed={tuple(p) for p in audit['components'][target]['source']['coast_neighbour_pairs']}
    if not any(target in p for p in audit['components'][cover]['source']['coast_neighbour_pairs']):
        raise ValueError('Cover is not a source coastal continuation of the target')
    ocean=exterior_water(owner);mandatory=set();shielded=set();arcs=[]
    for loop in tile_loops(tiles[target],owner,ocean):
        for arc in sea_runs(loop):
            ends=set(arc['neighbours'])
            if arc['neighbours'] not in allowed and cover in ends and ends & inland:
                mandatory.update(arc['water_cells']);shielded.update(ends&inland);arcs.append(arc)
    for c in shielded:mandatory|={q for p in tiles[c] for q in adjacent(p) if q in ocean}
    result,move=shield(tiles,required,inland,cover,mandatory,band)
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    for name in ('lake-cells.csv','lake-placement.json'):
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record=dict(target=target,band=band,shielded_inland=sorted(shielded),unsupported_arcs=arcs,move=move,
                inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',source_coasts,coast_audit]
                        +[layout/n for n in ('lake-cells.csv','lake-placement.json') if (layout/n).exists()]},
                script_sha256=digest(Path(__file__)),cells_sha256=digest(output/'cells.csv'),
                limits=['Source coastal-arc continuation selects the cover. No country-specific branch.',
                        'Coastal growth takes an equal number of cells from the same component. No other component moves.',
                        'Exact counts, true borders, enclosed water and its shores are retained. No new false border pair.',
                        'This can make a long thin coast. Shape and population distortion still need review. No production approval.'])
    (output/'coast-shield.json').write_text(json.dumps(record,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=source-coastal-cover\ncounts=exact\napproval=none\n')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('inputs','layout','source_coasts','coast_audit','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--target',required=True);parser.add_argument('--cover',required=True)
    parser.add_argument('--band',type=int,default=2)
    run(**vars(parser.parse_args()))
