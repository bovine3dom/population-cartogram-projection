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
from scipy.ndimage import binary_closing, distance_transform_edt
from shapely import affinity, contains_xy
from shapely.geometry import Polygon

from geographic_baseline import simple_toggle
from review_layout import NEIGHBOURS, load, read_csv, connectivity, holes
from save_review import digest


def adjacent(p):return [(p[0]+dx,p[1]+dy) for dx,dy in NEIGHBOURS]


class Deformation:
    def __init__(self, tiles, required, costs, origin, perimeter=1., false_contact=4., sea_perimeter=0., sea_mask=None,allow_holes=False):
        self.tiles={c:set(points) for c,points in tiles.items()}
        if any(connectivity(p)!=1 or (not allow_holes and holes(p)) for p in self.tiles.values()):
            raise ValueError('Starting regions must be connected and have no holes')
        self.owners={p:c for c,points in self.tiles.items() for p in points}
        if len(self.owners)!=sum(map(len,self.tiles.values())):raise ValueError('Overlapping cells')
        self.required=set(required);self.costs=costs;self.origin=origin
        self.perimeter=perimeter;self.false_contact=false_contact;self.sea_perimeter=sea_perimeter
        self.bounds=next(iter(costs.values())).shape
        self.sea_mask=sea_mask
        if sea_mask is not None and sea_mask.shape!=self.bounds:raise ValueError('Sea mask and cost grid differ')

    def inside(self,p):
        x,y=p[0]-self.origin[0],p[1]-self.origin[1]
        return 0<=x<self.bounds[1] and 0<=y<self.bounds[0]

    def cost(self,c,p):
        return 0. if c is None else float(self.costs[c][p[1]-self.origin[1],p[0]-self.origin[0]])

    def edge(self,a,b):
        if a==b:return 0.
        value=self.perimeter*((a is not None)+(b is not None))
        if a is None or b is None:value+=self.sea_perimeter
        if a is not None and b is not None and tuple(sorted((a,b))) not in self.required:value+=self.false_contact
        return value

    def edge_at(self,p,q,a,b):
        value=self.edge(a,b)
        if self.sea_mask is not None and ((a is None)!=(b is None)):
            water=p if a is None else q
            if not self.inside(water) or not self.sea_mask[water[1]-self.origin[1],water[0]-self.origin[0]]:value-=self.sea_perimeter
        return value

    def delta(self,p,target):
        owner=self.owners.get(p)
        return self.cost(target,p)-self.cost(owner,p)+sum(self.edge_at(p,q,target,self.owners.get(q))-self.edge_at(p,q,owner,self.owners.get(q)) for q in adjacent(p))

    def possible(self,p,target):
        if not self.inside(p):return False
        owner=self.owners.get(p)
        if owner==target or owner in getattr(self,'fixed',()) or target in getattr(self,'fixed',()):return False
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
                if other is None or p<q:value+=self.edge_at(p,q,c,other)
        return value

    def candidates(self,choices,strict=False):
        frontier={p for p,c in self.owners.items() if any(self.owners.get(q)!=c for q in adjacent(p))}
        frontier|={q for p in frontier for q in adjacent(p) if q not in self.owners and self.inside(q)}
        moves=collections.defaultdict(list)
        for p in sorted(frontier):
            owner=self.owners.get(p)
            for target in sorted({self.owners.get(q) for q in adjacent(p)}-{owner},key=lambda c:c or ''):
                if self.possible(p,target) and (not strict or Deformation.possible(self,p,target)):
                    moves[owner,target].append((self.delta(p,target),p))
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


def fit_guide_centres(tiles,guides,budgets):
    labels=sorted(tiles)
    if set(guides)!=set(tiles):raise ValueError('Guide layout component labels differ')
    current=np.array([np.mean(list(tiles[c]),axis=0) for c in labels])
    target=np.array([np.mean(list(guides[c]),axis=0) for c in labels])
    weights=np.array([budgets[c] for c in labels],dtype=float)
    a=np.average(current,axis=0,weights=weights);b=np.average(target,axis=0,weights=weights)
    denominator=np.sum(weights[:,None]*(target-b)**2)
    if denominator<=0:raise ValueError('Guide centres have no spatial extent')
    scale=float(np.sum(weights[:,None]*(target-b)*(current-a))/denominator)
    if scale<=0:raise ValueError('Guide alignment reverses geographic axes')
    fitted=(target-b)*scale+a
    return dict(zip(labels,fitted)),dict(scale=scale,translation=(a-scale*b).tolist(),rotation_degrees=0)


def guide_costs(inputs,tiles,anchor=.05,guide=1.,margin=64,stretch=None,budgets=None,centres=None):
    all_points=set().union(*tiles.values())
    origin=(min(x for x,y in all_points)-margin,min(y for x,y in all_points)-margin)
    xmax=max(x for x,y in all_points)+margin;ymax=max(y for x,y in all_points)+margin
    yy,xx=np.mgrid[origin[1]:ymax+1,origin[0]:xmax+1]
    lines=(inputs/'validated.wkt').read_text().splitlines()
    polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
    costs={};allowed={}
    for c,points in sorted(tiles.items()):
        count=len(points);n=budgets[c] if budgets is not None else count
        cx,cy=centres[c] if centres is not None else (sum(x for x,y in points)/count,sum(y for x,y in points)/count)
        polygon=polygons[c];centre=polygon.centroid;scale=math.sqrt(n/polygon.area)
        polygon=affinity.translate(affinity.scale(affinity.translate(polygon,-centre.x,-centre.y),scale,scale,origin=(0,0)),cx,cy)
        mask=contains_xy(polygon,xx,yy)
        if not mask.any():
            p=polygon.representative_point();x,y=round(p.x)-origin[0],round(p.y)-origin[1]
            if not(0<=y<mask.shape[0] and 0<=x<mask.shape[1]):raise ValueError('Guide lies outside cost grid')
            mask[y,x]=True
        distance=distance_transform_edt(~mask)
        costs[c]=(guide*distance**2/math.sqrt(n)+anchor*((xx-cx)**2+(yy-cy)**2)/n).astype(np.float32)
        if stretch is not None:
            allowed[c]=distance<=max(2.,stretch*math.sqrt(n))
            for x,y in points:allowed[c][y-origin[1],x-origin[0]]=True
    return (costs,origin,allowed) if stretch is not None else (costs,origin)


def run(inputs,layout,output,rounds=300,perimeter=1.,false_contact=4.,guide=1.,anchor=.05,choices=4,cycles=False,fit_rounds=0,atomic=False,regrow=False,bounded=False,stretch=.1,contact_reward=.5,template_penalty=0.,land_only=False,sea_perimeter=0.,fit_attempts=1,strict_fit=False,interior_sea_radius=0,guide_layout=None,cache_regrowth=True,full_topology_checks=False,envelope_weight=0.,envelope_sigma=8.,fixed_footprint=False):
    if output.exists():raise ValueError('Output already exists')
    if rounds<1 or choices<1 or fit_rounds<0 or fit_attempts<1 or interior_sea_radius<0 or contact_reward>1 or any(not math.isfinite(v) or v<0 for v in [perimeter,false_contact,guide,anchor,stretch,contact_reward,template_penalty,sea_perimeter,envelope_weight,envelope_sigma]):raise ValueError('Invalid optimization settings')
    if fixed_footprint and (cycles or fit_rounds or atomic or regrow or bounded or envelope_weight):raise ValueError('Fixed footprint requires basic exact-count exchanges')
    if template_penalty and not bounded:raise ValueError('Template penalty requires bounded deformation')
    if envelope_weight and (not land_only or envelope_sigma<=0):raise ValueError('Envelope cost requires land-only mode and a positive scale')
    if bounded:regrow=True
    if regrow:atomic=True
    scripts=[Path(__file__)]+[Path(__file__).with_name(name) for name in ['geographic_baseline.py','review_layout.py']]
    if cycles or fit_rounds or atomic:scripts.append(Path(__file__).with_name('cycle_deformation.py'))
    if fit_rounds or atomic:scripts.append(Path(__file__).with_name('fit_counts.py'))
    if atomic:scripts.append(Path(__file__).with_name('atomic_deformation.py'))
    if regrow:scripts.append(Path(__file__).with_name('regrow_regions.py'))
    if bounded:scripts.append(Path(__file__).with_name('bounded_deformation.py'))
    if envelope_weight:scripts.append(Path(__file__).with_name('land_envelope.py'))
    hashes={p.name:digest(p) for p in scripts}
    input_hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'validated.wkt',inputs/'geographic-contacts.csv',layout/'cells.csv']+([guide_layout/'cells.csv',guide_layout/'complete.txt'] if guide_layout else [])}
    shapes,tiles,_=load(inputs,layout)
    requested={c:int(row['tiles']) for c,row in shapes.items()}
    if (envelope_weight or fixed_footprint) and any(len(tiles[c])!=requested[c] for c in tiles):raise ValueError('Footprint controls require exact starting budgets')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    centres=alignment=None
    if guide_layout:
        _,guides,_=load(inputs,guide_layout)
        centres,alignment=fit_guide_centres(tiles,guides,requested)
    started=time.monotonic();guided=guide_costs(inputs,tiles,anchor,guide,margin=max(64,interior_sea_radius+2,math.ceil(4*envelope_sigma)+2 if envelope_weight else 0),stretch=stretch if bounded else None,budgets=requested if fit_rounds else None,centres=centres)
    costs,origin=guided[:2]
    state_type=Deformation
    if cycles:
        from cycle_deformation import CycleDeformation
        state_type=CycleDeformation
    if fit_rounds:
        from fit_counts import CountFit
        state_type=CountFit
    if atomic:
        from atomic_deformation import AtomicDeformation
        state_type=AtomicDeformation
    if regrow:
        from regrow_regions import Regrowth
        state_type=Regrowth
    if bounded:
        from bounded_deformation import BoundedDeformation
        state_type=BoundedDeformation
    fixed=set(tiles)-{c for pair in required for c in pair} if land_only else set()
    options=dict(allowed_masks=guided[2],contact_reward=contact_reward,template_penalty=template_penalty,fixed=fixed) if bounded else {}
    if fixed_footprint:options['allow_holes']=True
    initial_holes={c:holes(p) for c,p in tiles.items()} if fixed_footprint else {}
    target=envelope=None
    if envelope_weight:
        from land_envelope import build, write_cells
        target,envelope=build(tiles,fixed,origin,next(iter(costs.values())).shape,envelope_sigma)
        penalty=(envelope_weight*(~target)).astype(np.float32)
        for c in set(tiles)-fixed:costs[c]+=penalty
    sea_mask=None
    if interior_sea_radius:
        sea_mask=np.zeros(next(iter(costs.values())).shape,dtype=bool)
        for points in tiles.values():
            for x,y in points:sea_mask[y-origin[1],x-origin[0]]=True
        yy,xx=np.mgrid[-interior_sea_radius:interior_sea_radius+1,-interior_sea_radius:interior_sea_radius+1]
        sea_mask|=binary_closing(sea_mask,structure=xx*xx+yy*yy<=interior_sea_radius**2)
    state=state_type(tiles,required,costs,origin,perimeter,false_contact,sea_perimeter=sea_perimeter,sea_mask=sea_mask,**options)
    state.full_topology_checks=full_topology_checks
    history=[];initial=state.energy()
    for turn in range(1,fit_rounds+1):
        moves=state.fit_step(requested,choices,fit_attempts,strict_fit)
        error=sum(abs(len(state.tiles[c])-requested[c]) for c in requested)
        history.append(dict(phase='counts',round=turn,exchanges=moves,energy=state.energy(),count_error=error))
        print(f'Count round {turn}: {moves} transfers; count error {error}',flush=True)
        if not moves or not error:break
    if land_only or fixed_footprint:state.fixed=frozenset(fixed|({None} if fixed_footprint else set()))
    initial_occupied=set(state.owners) if fixed_footprint else None
    state.cache_regrowth=cache_regrowth
    counts={c:len(points) for c,points in state.tiles.items()}
    error=sum(abs(counts[c]-requested[c]) for c in requested)
    previous=state.energy()
    for turn in range(1,rounds+1):
        moves=state.step(choices);energy=state.energy()
        if energy>previous+1e-6:raise AssertionError('Energy increased')
        history.append(dict(phase='shape',round=turn,exchanges=moves,energy=energy,count_error=error));previous=energy
        print(f'Round {turn}: {moves} exchanges; energy {energy:.6f}',flush=True)
        if not moves:break
    if any(len(state.tiles[c])!=counts[c] or connectivity(state.tiles[c])!=1 or holes(state.tiles[c])!=initial_holes.get(c,0) for c in tiles):raise AssertionError('Count or topology changed')
    if fixed_footprint and set(state.owners)!=initial_occupied:raise AssertionError('Fixed footprint changed')
    if bounded:state.check_contacts()
    if envelope is not None:
        occupied=np.zeros_like(target)
        for x,y in state.owners:occupied[y-origin[1],x-origin[0]]=True
        envelope['final_empty_target_cells']=int((target&~occupied).sum())
        envelope['weight']=envelope_weight
    metadata=dict(method='Count-preserving local boundary exchanges with perimeter and geographic-guide costs; no required-contact paths',
        maximum_rounds=rounds,rounds=turn,perimeter=perimeter,false_contact=false_contact,guide=guide,anchor=anchor,choices=choices,
        cycles=cycles or bool(fit_rounds) or atomic,atomic=atomic,regrow=regrow,maximum_fit_rounds=fit_rounds,fit_attempts=fit_attempts,strict_fit=strict_fit,absolute_tile_error=error,
        bounded=bounded,stretch=stretch if bounded else None,contact_reward=contact_reward if bounded else None,sea_perimeter=sea_perimeter,interior_sea_radius=interior_sea_radius,
        template_penalty=template_penalty,land_only=land_only,fixed_footprint=fixed_footprint,preserved_holes=sum(initial_holes.values()),fixed_components=len(fixed),guide_area='requested budget' if fit_rounds else 'initial count',guide_layout=str(guide_layout) if guide_layout else None,guide_alignment=alignment,cache_regrowth=cache_regrowth,full_topology_checks=full_topology_checks,envelope=envelope,
        initial_energy=initial,final_energy=previous,elapsed_seconds=time.monotonic()-started,
        input_cells_sha256=input_hashes[str(layout/'cells.csv')],inputs=input_hashes,scripts=hashes,
        limit='Shape exchanges preserve counts after optional budget fitting. See absolute_tile_error for residual error. Contacts may be lost or added. Fixed guide centres can preserve poor geographic positions. A guide layout changes target centres, not the starting cells; alignment uses a positive uniform scale and translation without rotation. Guides omit original holes. Sequential checks restrict single-cell movement. Atomic checks can move them through a temporary two-cell state. Bounded mode prevents false contacts and limits new cells to a source-outline buffer; initial cells always remain allowed. A template penalty charges for new cells outside the initial tile shape. Land-only mode freezes components without represented land borders during shape optimization, and also during count fitting in bounded mode. An interior sea radius restricts the extra sea-edge cost to water inside a fixed closing envelope of initial land; this envelope can include real water.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='compact-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(state.tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        with (temp/'history.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(history[0]));writer.writeheader();writer.writerows(history)
        if envelope is not None:
            write_cells(temp/'envelope.csv',target,origin)
            envelope['cells_sha256']=digest(temp/'envelope.csv')
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
    for name,default in [('perimeter',1.),('false-contact',4.),('guide',1.),('anchor',.05),('sea-perimeter',0.)]:parser.add_argument('--'+name,type=float,default=default)
    parser.add_argument('--cycles',action='store_true');parser.add_argument('--atomic',action='store_true')
    parser.add_argument('--fixed-footprint',action='store_true',help='Permit only country-to-country exchanges; freeze occupied cells and empty spaces')
    parser.add_argument('--fit-rounds',type=int,default=0);parser.add_argument('--fit-attempts',type=int,default=1)
    parser.add_argument('--regrow',action='store_true');parser.add_argument('--strict-fit',action='store_true')
    parser.add_argument('--bounded',action='store_true');parser.add_argument('--stretch',type=float,default=.1)
    parser.add_argument('--contact-reward',type=float,default=.5)
    parser.add_argument('--template-penalty',type=float,default=0.)
    parser.add_argument('--guide-layout',type=Path)
    parser.add_argument('--no-regrowth-cache',dest='cache_regrowth',action='store_false')
    parser.add_argument('--full-topology-checks',action='store_true')
    parser.add_argument('--envelope-weight',type=float,default=0.);parser.add_argument('--envelope-sigma',type=float,default=8.)
    parser.add_argument('--land-only',action='store_true');parser.add_argument('--interior-sea-radius',type=int,default=0)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
