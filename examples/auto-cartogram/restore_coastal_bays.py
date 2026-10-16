#!/usr/bin/env python3
"""Extend exterior water to lost coasts with exact-count vacancy moves."""
import argparse
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from lake_vacancies import VacancyLayout
from review_geography import exterior_water, water_edges
from review_layout import load, read_csv
from save_review import digest


def run(inputs,layout,source_coasts,output,maximum_steps=8):
    if output.exists() or maximum_steps<1:raise ValueError('Use a new output and a positive step limit')
    rows,tiles,owner=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) for c in tiles):raise ValueError('Exact counts required')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    inland={r['component_id'] for r in read_csv(source_coasts) if int(r['uncovered_samples'])==0}
    land={c for pair in required for c in pair}
    lakes=layout/'lake-cells.csv'
    water={(int(r['x']),int(r['y'])) for r in read_csv(lakes)} if lakes.exists() else set()
    fixed=(set(tiles)-land)|{owner[q] for p in water for q in adjacent(p) if q in owner}
    state=VacancyLayout(tiles,required,inland,fixed=fixed)
    initial=water_edges(tiles,owner,state.exterior)
    targets=[c for c in tiles if c not in inland and not initial[c]['exterior_water_edges'] and len(tiles[c])<=200]
    records=[]
    for c in sorted(targets,key=lambda c:(len(tiles[c]),c)):
        actions=[];moves=[]
        for _ in range(maximum_steps):
            if state.ocean_edges(c):break
            coast={p for p,d in state.owners.items() if d not in fixed and any(q in state.exterior for q in adjacent(p))}
            def distance(p):return min(abs(p[0]-q[0])+abs(p[1]-q[1]) for q in state.tiles[c])
            candidates=sorted(coast,key=lambda p:(distance(p),p))[:24]
            moved=False
            for start in candidates:
                if distance(start)>maximum_steps:continue
                before=min(distance(p) for p in coast)
                if distance(start)!=before:continue
                for path in state.paths(start,maximum_cost=48,limit=32):
                    action=state.attempt(path,coastal=True)
                    if action is None:continue
                    after=min(distance(p) for p in state.owners if any(q in state.exterior for q in adjacent(p)))
                    if not state.ocean_edges(c) and after>=before:
                        state.undo(action);continue
                    actions.append(action);moves.append(dict(start=start,end=action['end'],length=action['length']))
                    moved=True;break
                if moved:break
            if not moved:break
        accepted=state.ocean_edges(c)>0
        if not accepted:
            for action in reversed(actions):state.undo(action)
        records.append(dict(component=c,accepted=accepted,moves=moves if accepted else [],reverted_steps=0 if accepted else len(actions)))
        print(json.dumps(records[-1]),flush=True)
    if state.exterior!=exterior_water(state.owners):raise AssertionError('Exterior water tracking differs')
    if any(p in state.owners for p in water):raise AssertionError('Lake occupied')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(state.tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    for name in ['lake-cells.csv','lake-placement.json']:
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record=dict(maximum_steps=maximum_steps,targets=records,rejections=dict(state.rejections),
                inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',source_coasts]+([lakes] if lakes.exists() else [])},
                scripts={name:digest(Path(__file__).with_name(name)) for name in ['restore_coastal_bays.py','lake_vacancies.py']},
                cells_sha256=digest(output/'cells.csv'),limits=['Counts and true borders are retained. No increase in false border count or inland ocean edges.',
                'Lake shore components stay fixed. Failed coast repairs are rolled back. Short bays still need visual review.'])
    (output/'coastal-bays.json').write_text(json.dumps(record,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=coastal-vacancies\ncounts=exact\napproval=none\n')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','source_coasts','output']:parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
