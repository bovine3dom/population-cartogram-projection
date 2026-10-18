#!/usr/bin/env python3
"""Allow joint border movement and whole-island packing in an OWID trial."""
import argparse
import csv
import json
from pathlib import Path
import shutil

import numpy as np

from audit_owid_budgets import parts, write_csv
from compact_regions import adjacent
from dock_true_borders import contacts
from fit_local_coasts import fit
from geographic_baseline import grow
from resize_owid_islands import outline, visible_budgets
from restore_reference_water import enclosed
from review_layout import connectivity
from save_review import digest
from shape_placement import place


def rows(path):
    with path.open() as stream:return list(csv.DictReader(stream))


def owners(tiles):return {p:c for c,points in tiles.items() for p in points}


def group_budgets(matches, country):
    selected=[r for r in matches if r['country']==country]
    groups={r['group']:float(r['group_population']) for r in selected}
    keys=sorted(groups);total=sum(int(r['old_tiles']) for r in selected)
    members={g:[r for r in selected if r['group']==g] for g in keys}
    counts=visible_budgets([groups[g] for g in keys],total,[len(members[g]) for g in keys])
    result={}
    for g,n in zip(keys,counts):
        allocated=visible_budgets([int(r['old_tiles']) for r in members[g]],n,[1]*len(members[g]))
        result.update({f"{country}:{r['target_part']}":value for r,value in zip(members[g],allocated)})
    return result


def releasable_sea(tiles, selected):
    owner=owners(tiles);released=set();records=[]
    for water in parts(enclosed(owner)):
        shore={owner[q] for p in water for q in adjacent(p) if q in owner}
        # This policy applies only to gaps among several selected island pieces.
        # Keep single-piece holes and international lakes out of the release set.
        if len(shore)>1 and shore<=selected:
            released|=water;records.append(dict(cells=sorted(water),shore_parts=sorted(shore)))
    return released,records


def pack_archipelago(tiles, budgets, max_shift=16, spacing=1.3):
    selected=set(budgets);owner=owners(tiles);required=contacts(owner)
    if any(a in selected or b in selected for a,b in required):
        raise ValueError('Free packing requires pieces without land-border contacts')
    released,sea_records=releasable_sea(tiles,selected)
    protected=enclosed(owner)-released
    if any(owner.get(q) in selected for p in protected for q in adjacent(p)):
        raise ValueError('A selected island has a protected lake shore')
    obstacles={p for p,c in owner.items() if c not in selected}
    centres={c:np.mean(sorted(tiles[c]),axis=0) for c in selected}
    anchor=np.mean(list(centres.values()),axis=0)
    result={c:set(p) for c,p in tiles.items() if c not in selected};placed={};records={}
    for c in sorted(selected,key=lambda c:(-budgets[c],c)):
        template=tiles[c] if budgets[c]==len(tiles[c]) else grow(outline(tiles[c]),budgets[c])[0]
        centre=np.mean(sorted(template),axis=0);desired=anchor+spacing*(centres[c]-anchor)
        low=centres[c]-centre-max_shift;high=centres[c]-centre+max_shift
        # Keep established centre order on axes with at least two cells of
        # separation. Later placements obey the already placed islands.
        for other,points in placed.items():
            other_centre=np.mean(sorted(points),axis=0)
            for axis in (0,1):
                delta=centres[c][axis]-centres[other][axis]
                if delta>=2:low[axis]=max(low[axis],other_centre[axis]+1-centre[axis])
                elif delta<=-2:high[axis]=min(high[axis],other_centre[axis]-1-centre[axis])
        blocked=obstacles|protected|{(x+dx,y+dy) for x,y in obstacles for dx in (-1,0,1) for dy in (-1,0,1)}
        moved=place(template,desired,blocked,maximum_radius=32,translation_bounds=[low,high])
        result[c]=moved;placed[c]=moved;obstacles|=moved
        shift=np.mean(sorted(moved),axis=0)-centres[c]
        records[c]=dict(before=len(tiles[c]),after=len(moved),translation=shift.tolist(),
                        removed=len(tiles[c]-moved),added=len(moved-tiles[c]))
    after=owners(result)
    if enclosed(after)!=protected:raise ValueError('Packing changed protected water or added a hole')
    if contacts(after)!=required:raise ValueError('Packing changed a land contact')
    assert all(len(result[c])==n and connectivity(result[c])==1 for c,n in budgets.items())
    return result,dict(parts=records,released_sea=sea_records,released_cells=len(released),
                       max_axis_shift=max_shift,spacing=spacing,centre_order_threshold=2,gap='one-cell eight-neighbour halo')


def scaled_template(points,count):
    template,_=grow(outline(points),count)
    shift=np.rint(np.mean(sorted(points),axis=0)-np.mean(sorted(template),axis=0)).astype(int)
    return {(x+int(shift[0]),y+int(shift[1])) for x,y in template}


def redistribute_country(tiles,budgets,seconds=120,margin=8,expansion=8):
    original={c:set(p) for c,p in tiles.items()};working=tiles
    required=contacts(owners(tiles));water=enclosed(owners(tiles))
    fixed=water|{q for p in water for q in adjacent(p)}
    attempts=[]
    for target in sorted(budgets,key=lambda c:(budgets[c]-len(original[c])>0,c)):
        if budgets[target]==len(original[target]):continue
        movable={target}|{b if a==target else a for a,b in required if target in (a,b)}
        preferred={c:scaled_template(original[c],budgets.get(c,len(original[c]))) for c in movable}
        candidate,solver=fit(working,required,set(),target,margin=margin,seconds=seconds,maximum_cuts=20,
            fixed_cells=fixed,expansion=expansion,movable=movable,preferred=preferred,
            perimeter_weight=.15,distance_weight=.1,sea_connected=True,protected_water=water,
            budgets={target:budgets[target]})
        attempts.append(dict(target=target,requested=budgets[target],movable=sorted(movable),accepted=candidate is not None,solver=solver))
        print(json.dumps(attempts[-1]),flush=True)
        if candidate is None:return original,dict(accepted=False,attempts=attempts)
        working=candidate
    after=owners(working)
    assert all(len(working[c])==budgets.get(c,len(original[c])) for c in original)
    assert sum(map(len,working.values()))==sum(map(len,original.values()))
    assert contacts(after)==required and enclosed(after)==water
    assert all(connectivity(p)==1 for p in working.values())
    return working,dict(accepted=True,attempts=attempts)


def run(parent,owid,output,archipelago=(),redistribute=(),seconds=120,margin=8,expansion=8,max_shift=16):
    if output.exists():raise ValueError('Use a new output directory')
    output.mkdir(parents=True)
    tiles={}
    for r in rows(parent/'cells.csv'):tiles.setdefault(r['component_id'],set()).add((int(r['x']),int(r['y'])))
    initial={c:set(p) for c,p in tiles.items()};matches=rows(parent/'matches.csv')
    record=dict(approved=False,parent=str(parent),archipelagos={},border_fits={},seconds_per_fit=seconds,margin=margin,expansion=expansion,
                inputs={str(p):digest(p) for p in (parent/'cells.csv',parent/'matches.csv',parent/'report.json',owid,Path(__file__))},
                dependencies={name:digest(Path(__file__).with_name(name)) for name in ('fit_local_coasts.py','resize_owid_islands.py','geographic_baseline.py','shape_placement.py')})
    def save(): (output/'relaxation.json').write_text(json.dumps(record,indent=2)+'\n')
    for country in archipelago:
        budgets=group_budgets(matches,country)
        if not budgets:raise ValueError('Unknown archipelago')
        try:
            tiles,result=pack_archipelago(tiles,budgets,max_shift)
            record['archipelagos'][country]=dict(accepted=True,**result)
        except ValueError as error:record['archipelagos'][country]=dict(accepted=False,error=str(error))
        save()
    for country in redistribute:
        budgets=group_budgets(matches,country)
        if not budgets:raise ValueError('Unknown country')
        tiles,record['border_fits'][country]=redistribute_country(tiles,budgets,seconds,margin,expansion)
        save()
    before=owners(initial);after=owners(tiles)
    assert len(after)==len(before) and contacts(after)==contacts(before)
    countries={c.split(':')[0] for c in tiles}
    for country in countries:
        assert sum(len(p) for c,p in tiles.items() if c.split(':')[0]==country)==sum(len(p) for c,p in initial.items() if c.split(':')[0]==country)
    report=json.loads((parent/'report.json').read_text())
    released={tuple(p) for r in record['archipelagos'].values() if r['accepted'] for gap in r['released_sea'] for p in gap['cells']}
    assert enclosed(after)==enclosed(before)-released
    report.update(relaxed_layout=True,enclosed_water_cells=len(enclosed(after)),released_inter_piece_sea_cells=len(released),
                  parent_layout_sha256=digest(parent/'cells.csv'),relaxation=record)
    report['limits'].append('Shared border positions may change. Selected archipelago gaps may open to the sea. Population identities are inherited, not newly approved.')
    for r in report['countries']:
        c=r['country'];labels=[k for k in tiles if k.split(':')[0]==c]
        changed=[k for k in labels if tiles[k]!=initial[k]]
        if changed:
            r['status']='joint border / island-motion trial'
            r['edits']={k:dict(before=len(initial[k]),after=len(tiles[k]),removed=len(initial[k]-tiles[k]),added=len(tiles[k]-initial[k])) for k in changed}
    for r in matches:
        label=f"{r['country']}:{r['target_part']}";r['actual_tiles']=len(tiles[label])
        if tiles[label]!=initial[label]:r['resize_status']='joint border / island-motion trial'
        if r['country'] in record['archipelagos'] and record['archipelagos'][r['country']]['accepted']:
            r['minimum_tiles']=1;r['tiles']=len(tiles[label])
    # The new group allocation is the sum over its actual target pieces.
    for r in matches:
        r['group_tiles']=sum(int(a['actual_tiles']) for a in matches if (a['country'],a['group'])==(r['country'],r['group']))
    write_csv(output/'matches.csv',matches)
    write_csv(output/'cells.csv',[dict(component_id=c,x=x,y=y) for c,p in sorted(tiles.items()) for x,y in sorted(p)])
    for name in ('source-assignments.csv','source-scopes-without-tiles.csv'):shutil.copyfile(parent/name,output/name)
    with owid.open() as stream:raw=[tuple(map(int,r)) for r in csv.reader(stream)]
    x0=min(r[0] for r in raw);y0=min(r[1] for r in raw);step=report['grid']['input_grid_step']
    iso=json.loads(Path('/usr/share/iso-codes/json/iso_3166-1.json').read_text())['3166-1'];codes={r['alpha_3']:int(r['numeric']) for r in iso}
    with (output/'owid-cartogram.csv').open('w',newline='') as stream:
        writer=csv.writer(stream,lineterminator='\n')
        for c,p in sorted(tiles.items()):
            country=c.split(':')[0];code=codes[country] if country in codes else int(country[5:])
            writer.writerows((x0+step*x,y0-step*y,code) for x,y in sorted(p))
    record['complete']=True
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    return tiles,record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','owid','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--archipelago',action='append',default=[])
    parser.add_argument('--redistribute',action='append',default=[])
    parser.add_argument('--seconds',type=float,default=120)
    parser.add_argument('--margin',type=int,default=8)
    parser.add_argument('--expansion',type=int,default=8)
    parser.add_argument('--max-shift',type=int,default=16)
    run(**vars(parser.parse_args()))
