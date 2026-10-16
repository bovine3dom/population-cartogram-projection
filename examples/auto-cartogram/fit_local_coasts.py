#!/usr/bin/env python3
"""Fit local coasts and borders with exact counts and optional coast movement."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import time

import numpy as np
from scipy.optimize import Bounds, LinearConstraint, milp
from scipy.sparse import coo_matrix
from scipy.spatial import cKDTree

from compact_regions import adjacent
from dock_true_borders import contacts
from repair_partition import pieces
from review_geography import exterior_water, water_edges
from review_layout import load, read_csv
from save_review import digest


def fit(tiles, required, inland, target, margin=3, seconds=60, maximum_cuts=20, maximum_reach=None, fixed_cells=(), required_extra=(), expansion=0, movable=(), preferred=None, perimeter_weight=0., distance_weight=0.):
    owner = {p:c for c, points in tiles.items() for p in points}
    ocean = exterior_water(owner)
    xy = np.array(sorted(tiles[target]))
    low, high = xy.min(axis=0)-margin, xy.max(axis=0)+margin
    window = {p for p in owner if all(low[i] <= p[i] <= high[i] for i in (0,1))}
    if movable:
        if target not in movable or not set(movable)<=set(tiles):
            raise ValueError('Movable labels must include the target and exist')
        window = {p for p in window if owner[p] in movable}
    labels = sorted({owner[p] for p in window})
    if expansion < 0 or min(perimeter_weight,distance_weight) < 0 or not np.isfinite([perimeter_weight,distance_weight]).all():
        raise ValueError('Expansion and shape weights must be non-negative and finite')
    for _ in range(expansion):
        window |= {q for p in window for q in adjacent(p) if q not in owner
                   and all(low[i] <= q[i] <= high[i] for i in (0,1))}
    points = sorted(window)
    indices = {(p,c):i for i,(p,c) in enumerate((p,c) for p in points for c in labels)}
    preferred = preferred or tiles
    objective = [0. if p in preferred.get(c, tiles[c]) else 1. for p,c in indices]
    if distance_weight:
        for c in labels:
            distances=cKDTree(sorted(preferred.get(c,tiles[c]))).query(points,p=1)[0]
            for p,d in zip(points,distances):objective[indices[p,c]]+=distance_weight*d*d
    constraints, lower, upper = [], [], []
    def add(values, lo=-np.inf, hi=np.inf):
        constraints.append(values);lower.append(lo);upper.append(hi)
    def term(p,c):
        return ({indices[p,c]:1.},0.) if p in window else ({},float(owner.get(p)==c))
    for p in points:
        add({indices[p,c]:1 for c in labels},0 if expansion else 1,1)
    for c in labels:
        add({indices[p,c]:1 for p in points},len(tiles[c]&window),len(tiles[c]&window))
    for p in window & set(fixed_cells):
        if p in owner:
            add({indices[p,owner[p]]:1},1,1)
        else:
            add({indices[p,c]:1 for c in labels},0,0)
    # A fixed root permits valid connectivity cuts. Prefer an interior cell.
    roots = {}
    for c in labels:
        outside = tiles[c]-window
        centre=np.mean(sorted(tiles[c]),axis=0)
        roots[c] = min(outside) if outside else max(sorted(tiles[c]),key=lambda p:(
            sum(q in tiles[c] for q in adjacent(p)), -sum((p[i]-centre[i])**2 for i in (0,1))))
        if roots[c] in window:
            add({indices[roots[c],c]:1},1,1)
    actual = contacts(owner)
    allowed = required | actual
    edge_set = {tuple(sorted((p,q))) for p in window for q in adjacent(p) if q in owner or q in window}
    for p,q in sorted(edge_set):
        for a in labels if p in window else [owner[p]]:
            for b in labels if q in window else [owner[q]]:
                if a==b or tuple(sorted((a,b))) in allowed:
                    continue
                left,lc=term(p,a);right,rc=term(q,b)
                add(left|right,hi=1-lc-rc)
    # Keep each true border that currently exists. Contacts outside the window are fixed.
    required_extra=set(required_extra)
    if not required_extra<=required:raise ValueError('Extra contacts must be source borders')
    for a,b in sorted((required & actual)|required_extra):
        if a not in labels and b not in labels and (a,b) not in required_extra:
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
    # With a changing footprint, use an independent flood fill after solving.
    # Old sea cells can become land, so the fixed-coast inequalities do not apply.
    for c in ([] if expansion else labels):
        if c in inland:
            weights={p:sum(q in ocean for q in adjacent(p)) for p in coast & window}
            bound=0 if c==target else sum(weights[p] for p in tiles[c]&window if p in weights)
            add({indices[p,c]:n for p,n in weights.items()},hi=bound)
        elif c not in inland and (c==target or original_coasts[c]) and not (tiles[c]&coast-window):
            add({indices[p,c]:1 for p in coast & window},lo=1)
    if expansion and target in inland:
        # Inland target cells need land on each side, except at existing lakes.
        # This is conservative: a new enclosed bay also needs land cover here.
        bounds=[(min(p[i] for p in owner),max(p[i] for p in owner)) for i in (0,1)]
        for p in points:
            for q in adjacent(p):
                if q not in owner and q not in ocean and all(lo<=v<=hi for v,(lo,hi) in zip(q,bounds)):
                    continue
                if q in window:
                    add({indices[p,target]:1, **{indices[q,c]:-1 for c in labels}},hi=0)
                elif q not in owner:
                    add({indices[p,target]:1},hi=0)
    if perimeter_weight:
        perimeter_edges={tuple(sorted((p,q))) for p in window for q in adjacent(p)}
        for p,q in sorted(perimeter_edges):
            for c in labels:
                left,lc=term(p,c);right,rc=term(q,c)
                y=len(objective);objective.append(perimeter_weight)
                add({y:1,**{i:-n for i,n in left.items()},**right},lo=lc-rc)
                add({y:1,**left,**{i:-n for i,n in right.items()}},lo=rc-lc)
    # Continuous flow from a fixed root enforces connectivity in the first solve.
    bounds_upper=[1.]*len(objective)
    # Border and perimeter auxiliaries can stay continuous with integer labels.
    integrality=[1]*len(indices)+[0]*(len(objective)-len(indices))
    if maximum_reach is not None:
        for c in labels:
            distances=cKDTree(sorted(tiles[c])).query(points,p=1)[0]
            for p,d in zip(points,distances):
                if d>maximum_reach:bounds_upper[indices[p,c]]=0.
    for c in labels:
        outside_parts=pieces(tiles[c]-window)
        fixed_nodes={p:('outside',i) for i,part in enumerate(outside_parts) for p in part}
        nodes=points+[('outside',i) for i in range(len(outside_parts))]
        root=roots[c] if roots[c] in window else fixed_nodes[roots[c]]
        demand=len(tiles[c]&window)+len(outside_parts)-1
        if demand<=0:continue
        edges=set()
        for p in points:
            for q in adjacent(p):
                other=q if q in window else fixed_nodes.get(q)
                if other is not None and bounds_upper[indices[p,c]] and (other not in window or bounds_upper[indices[other,c]]):
                    edges.add((p,other));edges.add((other,p))
        balances={p:{} for p in nodes}
        for a,b in sorted(edges,key=repr):
            f=len(objective);objective.append(0.);bounds_upper.append(float(demand));integrality.append(0)
            balances[a][f]=-1;balances[b][f]=1
            for p in (a,b):
                if p in window:add({f:1,indices[p,c]:-demand},hi=0)
        for p,values in balances.items():
            if p==root:add(values,-demand,-demand)
            elif p in window:add(values|{indices[p,c]:-1},0,0)
            else:add(values,1,1)
    started=time.monotonic();records=[]
    for turn in range(maximum_cuts):
        remaining=seconds-(time.monotonic()-started)
        if remaining<=0:break
        rr,cc,vv=[],[],[]
        for row,values in enumerate(constraints):
            for col,value in values.items():rr.append(row);cc.append(col);vv.append(value)
        matrix=coo_matrix((vv,(rr,cc)),shape=(len(constraints),len(objective))).tocsc()
        solved=milp(np.array(objective),integrality=np.array(integrality),bounds=Bounds(0,bounds_upper),
                    constraints=LinearConstraint(matrix,lower,upper),options={'time_limit':remaining,'mip_rel_gap':0})
        records.append(dict(status=int(solved.status),message=solved.message))
        if solved.x is None:break
        integer=np.array(integrality,dtype=bool)
        if np.max(np.abs(solved.x[integer]-np.rint(solved.x[integer])))>1e-5:break
        candidate=solved.x.copy();candidate[integer]=np.rint(candidate[integer])
        values=matrix@candidate
        if np.any(values<np.asarray(lower)-1e-5) or np.any(values>np.asarray(upper)+1e-5):break
        result={c:set(p) for c,p in tiles.items()}
        for p in points:
            chosen=[c for c in labels if solved.x[indices[p,c]]>.5]
            if len(chosen)>1 or (not expansion and not chosen):return None,records
            if p in owner:result[owner[p]].remove(p)
            if chosen:result[chosen[0]].add(p)
        split=False
        for c in labels:
            for part in pieces(result[c]):
                if roots[c] in part:continue
                split=True
                boundary={q for p in part for q in adjacent(p) if (q in owner or q in window) and q not in part}
                values={indices[p,c]:-1/len(part) for p in part if p in window}
                fixed_inside=len(part-window)/len(part)
                fixed_boundary=sum(owner.get(p)==c for p in boundary-window)
                for p in boundary & window:values[indices[p,c]]=1
                add(values,lo=fixed_inside-fixed_boundary)
        if split:continue
        after={p:c for c,points in result.items() for p in points}
        if len(after)!=len(owner) or any(len(result[c])!=len(tiles[c]) for c in tiles):raise AssertionError('Counts differ')
        if any(owner.get(p)!=after.get(p) for p in fixed_cells):raise AssertionError('Fixed cell changed')
        new=contacts(after)
        if ((required & actual)|required_extra)-new or new-required-actual:raise AssertionError('Border regression')
        edges=water_edges(result,after,exterior_water(after) if expansion else ocean)
        if (target in inland and edges[target]['exterior_water_edges']) or (target not in inland and not edges[target]['exterior_water_edges']):
            if expansion:return None,records+[dict(rejected='Target coast constraint failed')]
            raise AssertionError('Target coast constraint failed')
        # Do not move an inland coast defect to a different component.
        old_edges=water_edges(tiles,owner,ocean)
        if any(edges[c]['exterior_water_edges']>old_edges[c]['exterior_water_edges'] for c in inland & set(tiles)):
            return None,records+[dict(rejected='Another inland coast grew')]
        if any(old_edges[c]['exterior_water_edges'] and not edges[c]['exterior_water_edges']
               for c in set(tiles)-inland):
            return None,records+[dict(rejected='A coastal component lost sea access')]
        return result,records
    return None,records


def run(inputs,layout,source_coasts,output,maximum_tiles=200,margin=3,seconds=60,maximum_cuts=100,targets=None,maximum_reach=None,require_contacts=(),expansion=0,movable=(),templates=None,perimeter_weight=0.,distance_weight=0.):
    if output.exists() or min(maximum_tiles,margin,seconds,maximum_cuts)<=0 or not np.isfinite(seconds):raise ValueError('Use a new output and positive limits')
    if maximum_reach is not None and maximum_reach<1:raise ValueError('Use a positive reach')
    rows,tiles,owner=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or len(pieces(tiles[c]))!=1 for c in tiles):raise ValueError('Exact connected components required')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    inland={r['component_id'] for r in read_csv(source_coasts) if int(r['uncovered_samples'])==0}
    lakes=layout/'lake-cells.csv'
    lake_cells={(int(r['x']),int(r['y'])) for r in read_csv(lakes)} if lakes.exists() else set()
    fixed_cells=lake_cells | {q for p in lake_cells for q in adjacent(p)}
    preferred=None
    if templates:
        if not movable:raise ValueError('Template fitting needs explicit movable labels')
        native=load(inputs,templates)[1];preferred={}
        for c in movable:
            offset=np.rint(np.mean(sorted(tiles[c]),axis=0)-np.mean(sorted(native[c]),axis=0)).astype(int)
            preferred[c]={(x+int(offset[0]),y+int(offset[1])) for x,y in native[c]}
    coast=water_edges(tiles,owner,exterior_water(owner));records=[]
    extra={tuple(sorted(pair)) for pair in require_contacts}
    if not extra<=required:raise ValueError('Extra contacts must be source borders')
    selected=set(targets) if targets else set(tiles)
    if not selected<=set(tiles):raise ValueError('Unknown target')
    targets=[c for c in tiles if c in selected and len(tiles[c])<=maximum_tiles and (extra or (c in inland)==bool(coast[c]['exterior_water_edges']))]
    for c in sorted(targets,key=lambda c:(len(tiles[c]),c)):
        result,attempts=fit(tiles,required,inland,c,margin,seconds,maximum_cuts,maximum_reach,fixed_cells,extra,expansion,movable,preferred,perimeter_weight,distance_weight)
        records.append(dict(component=c,accepted=result is not None,attempts=attempts))
        print(json.dumps(records[-1]),flush=True)
        if result is not None:tiles=result
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    for name in ['lake-cells.csv','lake-placement.json']:
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record=dict(distance_weight=distance_weight,perimeter_weight=perimeter_weight,templates=str(templates) if templates else None,movable=sorted(movable),expansion=expansion,required_extra=sorted(extra),maximum_reach=maximum_reach,connectivity='rooted continuous flow with independent component checks',maximum_tiles=maximum_tiles,margin=margin,seconds_per_target=seconds,maximum_cuts=maximum_cuts,targets=records,
                inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',source_coasts]+([lakes] if lakes.exists() else [])+([templates/'cells.csv'] if templates else [])},
                script_sha256=digest(Path(__file__)),cells_sha256=digest(output/'cells.csv'),
                limits=['Exact counts. Lakes and their shore cells stay fixed. Expansion is optional.',
                        'With expansion, coast checks can reject a feasible border fit. The solver does not search again.',
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
    parser.add_argument('--maximum-reach',type=int)
    parser.add_argument('--expansion',type=int,default=0)
    parser.add_argument('--movable',nargs='+',default=[])
    parser.add_argument('--templates',type=Path)
    parser.add_argument('--perimeter-weight',type=float,default=0.)
    parser.add_argument('--distance-weight',type=float,default=0.)
    parser.add_argument('--require-contacts',nargs=2,action='append',default=[])
    run(**vars(parser.parse_args()))
