#!/usr/bin/env python3
"""Deform tile regions by local exchanges, without required-border paths."""
import argparse
import collections
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile
import time

import numpy as np
from scipy.ndimage import distance_transform_edt
from shapely import affinity, contains_xy
from shapely.geometry import Polygon

from geographic_baseline import simple_toggle
from review_layout import NEIGHBOURS, load, read_csv, connectivity, holes
from save_review import digest


def adjacent(p):return [(p[0]+dx,p[1]+dy) for dx,dy in NEIGHBOURS]


class Deformation:
    def __init__(self, tiles, required, costs, origin, perimeter=1., false_contact=4.):
        self.tiles={c:set(points) for c,points in tiles.items()}
        if any(connectivity(p)!=1 or holes(p) for p in self.tiles.values()):
            raise ValueError('Starting regions must be connected and have no holes')
        self.owners={p:c for c,points in self.tiles.items() for p in points}
        if len(self.owners)!=sum(map(len,self.tiles.values())):raise ValueError('Overlapping cells')
        self.required=set(required);self.costs=costs;self.origin=origin
        self.perimeter=perimeter;self.false_contact=false_contact
        self.bounds=next(iter(costs.values())).shape

    def inside(self,p):
        x,y=p[0]-self.origin[0],p[1]-self.origin[1]
        return 0<=x<self.bounds[1] and 0<=y<self.bounds[0]

    def cost(self,c,p):
        return 0. if c is None else float(self.costs[c][p[1]-self.origin[1],p[0]-self.origin[0]])

    def edge(self,a,b):
        if a==b:return 0.
        value=self.perimeter*((a is not None)+(b is not None))
        if a is not None and b is not None and tuple(sorted((a,b))) not in self.required:value+=self.false_contact
        return value

    def delta(self,p,target):
        owner=self.owners.get(p)
        return self.cost(target,p)-self.cost(owner,p)+sum(self.edge(target,self.owners.get(q))-self.edge(owner,self.owners.get(q)) for q in adjacent(p))

    def possible(self,p,target):
        if not self.inside(p):return False
        owner=self.owners.get(p)
        if owner==target:return False
        if owner is not None and (len(self.tiles[owner])<=1 or not simple_toggle(self.tiles[owner],p)):return False
        if target is not None and not simple_toggle(self.tiles[target],p):return False
        return True

    def change(self,p,target):
        owner=self.owners.pop(p,None)
        if owner is not None:self.tiles[owner].remove(p)
        if target is not None:self.owners[p]=target;self.tiles[target].add(p)
        return owner

    def exchange(self,p,q):
        a,b=self.owners.get(p),self.owners.get(q)
        if a==b or not self.possible(p,b):return False
        first=self.delta(p,b);self.change(p,b)
        if self.possible(q,a) and first+self.delta(q,a)<-1e-8:
            self.change(q,a);return True
        self.change(p,a)
        return False

    def energy(self):
        value=sum(self.cost(c,p) for p,c in self.owners.items())
        for p,c in self.owners.items():
            for q in adjacent(p):
                other=self.owners.get(q)
                if other is None or p<q:value+=self.edge(c,other)
        return value

    def candidates(self,choices):
        frontier={p for p,c in self.owners.items() if any(self.owners.get(q)!=c for q in adjacent(p))}
        frontier|={q for p in frontier for q in adjacent(p) if q not in self.owners and self.inside(q)}
        moves=collections.defaultdict(list)
        for p in sorted(frontier):
            owner=self.owners.get(p)
            for target in sorted({self.owners.get(q) for q in adjacent(p)}-{owner},key=lambda c:c or ''):
                if self.possible(p,target):moves[owner,target].append((self.delta(p,target),p))
        return {key:sorted(value)[:choices] for key,value in moves.items()}

    def step(self,choices=4):
        candidates=self.candidates(choices);pairs=[]
        key=lambda c:c or ''
        for (a,b),moves in candidates.items():
            if key(a)>=key(b) or (b,a) not in candidates:continue
            reverse=candidates[b,a]
            pairs.append((moves[0][0]+reverse[0][0],key(a),key(b),a,b))
        changed=0
        for _,_,_,a,b in sorted(pairs):
            success=False
            for _,p in candidates[a,b]:
                if self.owners.get(p)!=a:continue
                for _,q in candidates[b,a]:
                    if self.owners.get(q)!=b:continue
                    if self.exchange(p,q) or self.exchange(q,p):
                        success=True;changed+=1;break
                if success:break
        return changed


def guide_costs(inputs,tiles,anchor=.05,guide=1.,margin=64):
    all_points=set().union(*tiles.values())
    origin=(min(x for x,y in all_points)-margin,min(y for x,y in all_points)-margin)
    xmax=max(x for x,y in all_points)+margin;ymax=max(y for x,y in all_points)+margin
    yy,xx=np.mgrid[origin[1]:ymax+1,origin[0]:xmax+1]
    lines=(inputs/'validated.wkt').read_text().splitlines()
    polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
    costs={}
    for c,points in sorted(tiles.items()):
        n=len(points);cx=sum(x for x,y in points)/n;cy=sum(y for x,y in points)/n
        polygon=polygons[c];centre=polygon.centroid;scale=math.sqrt(n/polygon.area)
        polygon=affinity.translate(affinity.scale(affinity.translate(polygon,-centre.x,-centre.y),scale,scale,origin=(0,0)),cx,cy)
        mask=contains_xy(polygon,xx,yy)
        if not mask.any():
            p=polygon.representative_point();x,y=round(p.x)-origin[0],round(p.y)-origin[1]
            if not(0<=y<mask.shape[0] and 0<=x<mask.shape[1]):raise ValueError('Guide lies outside cost grid')
            mask[y,x]=True
        distance=distance_transform_edt(~mask)
        costs[c]=(guide*distance**2/math.sqrt(n)+anchor*((xx-cx)**2+(yy-cy)**2)/n).astype(np.float32)
    return costs,origin


def run(inputs,layout,output,rounds=300,perimeter=1.,false_contact=4.,guide=1.,anchor=.05,choices=4,cycles=False,fit_rounds=0,atomic=False,regrow=False):
    if output.exists():raise ValueError('Output already exists')
    if rounds<1 or choices<1 or fit_rounds<0 or any(not math.isfinite(v) or v<0 for v in [perimeter,false_contact,guide,anchor]):raise ValueError('Invalid optimization settings')
    shapes,tiles,_=load(inputs,layout)
    requested={c:int(row['tiles']) for c,row in shapes.items()}
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    started=time.monotonic();costs,origin=guide_costs(inputs,tiles,anchor,guide)
    state_type=Deformation
    if cycles:
        from cycle_deformation import CycleDeformation
        state_type=CycleDeformation
    if fit_rounds:
        from fit_counts import CountFit
        state_type=CountFit
    if regrow:atomic=True
    if atomic:
        from atomic_deformation import AtomicDeformation
        state_type=AtomicDeformation
    if regrow:
        from regrow_regions import Regrowth
        state_type=Regrowth
    state=state_type(tiles,required,costs,origin,perimeter,false_contact)
    scripts=[Path(__file__)]
    if cycles or fit_rounds or atomic:scripts.append(Path(__file__).with_name('cycle_deformation.py'))
    if fit_rounds or atomic:scripts.append(Path(__file__).with_name('fit_counts.py'))
    if atomic:scripts.append(Path(__file__).with_name('atomic_deformation.py'))
    if regrow:scripts.append(Path(__file__).with_name('regrow_regions.py'))
    hashes={p.name:digest(p) for p in scripts}
    history=[];initial=state.energy()
    for turn in range(1,fit_rounds+1):
        moves=state.fit_step(requested,choices)
        error=sum(abs(len(state.tiles[c])-requested[c]) for c in requested)
        history.append(dict(phase='counts',round=turn,exchanges=moves,energy=state.energy(),count_error=error))
        print(f'Count round {turn}: {moves} transfers; count error {error}',flush=True)
        if not moves or not error:break
    counts={c:len(points) for c,points in state.tiles.items()}
    error=sum(abs(counts[c]-requested[c]) for c in requested)
    previous=state.energy()
    for turn in range(1,rounds+1):
        moves=state.step(choices);energy=state.energy()
        if energy>previous+1e-6:raise AssertionError('Energy increased')
        history.append(dict(phase='shape',round=turn,exchanges=moves,energy=energy,count_error=error));previous=energy
        print(f'Round {turn}: {moves} exchanges; energy {energy:.6f}',flush=True)
        if not moves:break
    if any(len(state.tiles[c])!=counts[c] or connectivity(state.tiles[c])!=1 or holes(state.tiles[c]) for c in tiles):raise AssertionError('Count or topology changed')
    metadata=dict(method='Count-preserving local boundary exchanges with perimeter and geographic-guide costs; no required-contact paths',
        maximum_rounds=rounds,rounds=turn,perimeter=perimeter,false_contact=false_contact,guide=guide,anchor=anchor,choices=choices,
        cycles=cycles or bool(fit_rounds) or atomic,atomic=atomic,regrow=regrow,maximum_fit_rounds=fit_rounds,absolute_tile_error=error,
        initial_energy=initial,final_energy=previous,elapsed_seconds=time.monotonic()-started,
        input_cells_sha256=digest(layout/'cells.csv'),scripts=hashes,
        limit='Shape exchanges preserve counts after optional budget fitting. See absolute_tile_error for residual error. Contacts may be lost or added. Fixed initial centres can preserve poor geographic positions. Guides omit original holes. Sequential checks restrict single-cell movement. Atomic checks can move them through a temporary two-cell state.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='compact-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(state.tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        with (temp/'history.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(history[0]));writer.writeheader();writer.writerows(history)
        (temp/'compact.json').write_text(json.dumps(metadata,indent=2)+'\n')
        (temp/'complete.txt').write_text(f'mode=compact-deformation\ncounts={"exact" if not error else "partial"}\ncontacts=soft\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return metadata


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--rounds',type=int,default=300);parser.add_argument('--choices',type=int,default=4)
    for name,default in [('perimeter',1.),('false-contact',4.),('guide',1.),('anchor',.05)]:parser.add_argument('--'+name,type=float,default=default)
    parser.add_argument('--cycles',action='store_true');parser.add_argument('--atomic',action='store_true')
    parser.add_argument('--fit-rounds',type=int,default=0);parser.add_argument('--regrow',action='store_true')
    args=parser.parse_args();print(json.dumps(run(args.inputs,args.layout,args.output,args.rounds,args.perimeter,args.false_contact,args.guide,args.anchor,args.choices,args.cycles,args.fit_rounds,args.atomic,args.regrow),indent=2))
