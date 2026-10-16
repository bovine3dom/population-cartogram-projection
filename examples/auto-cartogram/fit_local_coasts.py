#!/usr/bin/env python3
"""Test exact local coast constraints without changing the land footprint."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import time

import numpy as np
from scipy.optimize import Bounds, LinearConstraint, milp
from scipy.sparse import coo_matrix

from compact_regions import adjacent
from dock_true_borders import contacts
from repair_partition import pieces
from review_geography import exterior_water, water_edges
from review_layout import load, read_csv
from save_review import digest


def fit(tiles, required, inland, target, margin=3, seconds=60, maximum_cuts=20):
    owner = {p:c for c, points in tiles.items() for p in points}
    ocean = exterior_water(owner)
    xy = np.array(sorted(tiles[target]))
    low, high = xy.min(axis=0)-margin, xy.max(axis=0)+margin
    window = {p for p in owner if all(low[i] <= p[i] <= high[i] for i in (0,1))}
    labels = sorted({owner[p] for p in window})
    points = sorted(window)
    indices = {(p,c):i for i,(p,c) in enumerate((p,c) for p in points for c in labels)}
    objective = [0. if owner[p] == c else 1. for p,c in indices]
    constraints, lower, upper = [], [], []
    def add(values, lo=-np.inf, hi=np.inf):
        constraints.append(values);lower.append(lo);upper.append(hi)
    def term(p,c):
        return ({indices[p,c]:1.},0.) if p in window else ({},float(owner.get(p)==c))
    for p in points:
        add({indices[p,c]:1 for c in labels},1,1)
    for c in labels:
        add({indices[p,c]:1 for p in points},len(tiles[c]&window),len(tiles[c]&window))
    # A fixed root permits valid connectivity cuts. Prefer an interior cell.
    roots = {}
    for c in labels:
        outside = tiles[c]-window
        roots[c] = min(outside) if outside else max(sorted(tiles[c]),key=lambda p:sum(q in tiles[c] for q in adjacent(p)))
        if roots[c] in window:
            add({indices[roots[c],c]:1},1,1)
    actual = contacts(owner)
    allowed = required | actual
    edge_set = {tuple(sorted((p,q))) for p in window for q in adjacent(p) if q in owner}
    for p,q in sorted(edge_set):
        for a in labels if p in window else [owner[p]]:
            for b in labels if q in window else [owner[q]]:
                if a==b or tuple(sorted((a,b))) in allowed:
                    continue
                left,lc=term(p,a);right,rc=term(q,b)
                add(left|right,hi=1-lc-rc)
    # Keep each true border that currently exists. Contacts outside the window are fixed.
    for a,b in sorted(required & actual):
        if a not in labels and b not in labels:
            continue
        if any(owner.get(q)==b and p not in window and q not in window for p in tiles[a] for q in adjacent(p)):
            continue
        witnesses = []
        for p,q in sorted(edge_set):
            for u,v in [(a,b),(b,a)]:
                if (p in window and u not in labels) or (q in window and v not in labels):continue
                left,lc=term(p,u);right,rc=term(q,v)
                if (not left and not lc) or (not right and not rc):continue
                y=len(objective);objective.append(0.);witnesses.append(y)
                add({y:1,**{i:-n for i,n in left.items()}},hi=lc)
                add({y:1,**{i:-n for i,n in right.items()}},hi=rc)
        add({i:1 for i in witnesses},lo=1)
    coast = {p for p in owner if any(q in ocean for q in adjacent(p))}
    original_coasts = {c: bool(tiles[c]&coast) for c in labels}
    for c in labels:
        if c in inland:
            weights={p:sum(q in ocean for q in adjacent(p)) for p in coast & window}
            bound=0 if c==target else sum(weights[p] for p in tiles[c]&window if p in weights)
            add({indices[p,c]:n for p,n in weights.items()},hi=bound)
        elif c not in inland and (c==target or original_coasts[c]) and not (tiles[c]&coast-window):
            add({indices[p,c]:1 for p in coast & window},lo=1)
    started=time.monotonic();records=[]
    for turn in range(maximum_cuts):
        remaining=seconds-(time.monotonic()-started)
        if remaining<=0:break
        rr,cc,vv=[],[],[]
        for row,values in enumerate(constraints):
            for col,value in values.items():rr.append(row);cc.append(col);vv.append(value)
        matrix=coo_matrix((vv,(rr,cc)),shape=(len(constraints),len(objective))).tocsc()
        solved=milp(np.array(objective),integrality=np.ones(len(objective)),bounds=Bounds(0,1),
                    constraints=LinearConstraint(matrix,lower,upper),options={'time_limit':remaining,'mip_rel_gap':0})
        records.append(dict(status=int(solved.status),message=solved.message))
        if solved.x is None or np.max(np.abs(solved.x-np.rint(solved.x)))>1e-5:break
        values=matrix@np.rint(solved.x)
        if np.any(values<np.asarray(lower)-1e-5) or np.any(values>np.asarray(upper)+1e-5):break
        result={c:set(p) for c,p in tiles.items()}
        for p in points:
            chosen=[c for c in labels if solved.x[indices[p,c]]>.5]
            if len(chosen)!=1:return None,records
            result[owner[p]].remove(p);result[chosen[0]].add(p)
        split=False
        for c in labels:
            for part in pieces(result[c]):
                if roots[c] in part:continue
                split=True
                boundary={q for p in part for q in adjacent(p) if q in owner and q not in part}
                values={indices[p,c]:-1/len(part) for p in part if p in window}
                fixed_inside=len(part-window)/len(part)
                fixed_boundary=sum(owner[p]==c for p in boundary-window)
                for p in boundary & window:values[indices[p,c]]=1
                add(values,lo=fixed_inside-fixed_boundary)
        if split:continue
        after={p:c for c,points in result.items() for p in points}
        if len(after)!=len(owner) or any(len(result[c])!=len(tiles[c]) for c in tiles):raise AssertionError('Counts differ')
        new=contacts(after)
        if (required & actual)-new or new-required-actual:raise AssertionError('Border regression')
        edges=water_edges(result,after,ocean)
        if (target in inland and edges[target]['exterior_water_edges']) or (target not in inland and not edges[target]['exterior_water_edges']):
            raise AssertionError('Target coast constraint failed')
        # Do not move an inland coast defect to a different component.
        old_edges=water_edges(tiles,owner,ocean)
        if any(edges[c]['exterior_water_edges']>old_edges[c]['exterior_water_edges'] for c in inland & set(labels)):
            return None,records+[dict(rejected='Another inland coast grew')]
        return result,records
    return None,records


def run(inputs,layout,source_coasts,output,maximum_tiles=200,margin=3,seconds=60,maximum_cuts=100,targets=None):
    if output.exists() or min(maximum_tiles,margin,seconds,maximum_cuts)<=0 or not np.isfinite(seconds):raise ValueError('Use a new output and positive limits')
    rows,tiles,owner=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or len(pieces(tiles[c]))!=1 for c in tiles):raise ValueError('Exact connected components required')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    inland={r['component_id'] for r in read_csv(source_coasts) if int(r['uncovered_samples'])==0}
    coast=water_edges(tiles,owner,exterior_water(owner));records=[]
    selected=set(targets) if targets else set(tiles)
    if not selected<=set(tiles):raise ValueError('Unknown target')
    targets=[c for c in tiles if c in selected and len(tiles[c])<=maximum_tiles and ((c in inland)==bool(coast[c]['exterior_water_edges']))]
    for c in sorted(targets,key=lambda c:(len(tiles[c]),c)):
        result,attempts=fit(tiles,required,inland,c,margin,seconds,maximum_cuts)
        records.append(dict(component=c,accepted=result is not None,attempts=attempts))
        print(json.dumps(records[-1]),flush=True)
        if result is not None:tiles=result
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    for name in ['lake-cells.csv','lake-placement.json']:
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record=dict(maximum_tiles=maximum_tiles,margin=margin,seconds_per_target=seconds,maximum_cuts=maximum_cuts,targets=records,
                inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',source_coasts]},
                script_sha256=digest(Path(__file__)),cells_sha256=digest(output/'cells.csv'),
                limits=['Fixed footprint and exact counts. Lakes stay empty.',
                        'Each component keeps one root cell. Search windows and time limits can hide valid repairs.',
                        'Source coast labels use finite samples. They are not a proof of ocean access.',
                        'Only connected integer solutions that retain true borders and add no false borders are accepted.',
                        'Accepted solutions can still have poor shapes. No production approval.'])
    (output/'local-coasts.json').write_text(json.dumps(record,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=local-coast-milp\ncounts=exact\napproval=none\n')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','source_coasts','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--seconds',type=float,default=60)
    parser.add_argument('--margin',type=int,default=3)
    parser.add_argument('--maximum-cuts',type=int,default=100)
    parser.add_argument('--targets',nargs='+')
    run(**vars(parser.parse_args()))
