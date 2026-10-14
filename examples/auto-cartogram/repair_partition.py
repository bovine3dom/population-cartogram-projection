#!/usr/bin/env python3
"""Reduce partition fragments by swaps; keep counts and occupied cells fixed."""
import argparse
import csv
import heapq
import json
from pathlib import Path
import shutil
import tempfile
import time

from review_layout import load, read_csv, NEIGHBOURS
from save_review import digest


def adjacent(p):return [(p[0]+dx,p[1]+dy) for dx,dy in NEIGHBOURS]


def pieces(points):
    remaining=set(points);result=[]
    while remaining:
        start=min(remaining);remaining.remove(start);part={start};queue=[start]
        while queue:
            for q in adjacent(queue.pop()):
                if q in remaining:remaining.remove(q);part.add(q);queue.append(q)
        result.append(part)
    return sorted(result,key=lambda p:(-len(p),min(p)))


class Repair:
    def __init__(self,tiles,fixed=()):
        self.tiles={c:set(p) for c,p in tiles.items()};self.fixed=set(fixed)
        if any(not p for p in self.tiles.values()):raise ValueError('Empty region')
        self.owners={p:c for c,points in self.tiles.items() for p in points}
        if len(self.owners)!=sum(map(len,self.tiles.values())):raise ValueError('Overlapping regions')
        self.parts={c:pieces(p) for c,p in self.tiles.items()}

    def fragments(self,c):return len(self.tiles[c])-len(self.parts[c][0])

    def report(self):
        return dict(disconnected_regions=sum(len(p)>1 for p in self.parts.values()),fragment_cells=sum(self.fragments(c) for c in self.tiles))

    def step(self,choices=16):
        for c in sorted(self.tiles,key=lambda c:(-self.fragments(c),c)):
            if c in self.fixed or len(self.parts[c])==1:continue
            main=self.parts[c][0];cx=sum(x for x,y in main)/len(main);cy=sum(y for x,y in main)/len(main)
            frontier={q for p in main for q in adjacent(p) if self.owners.get(q) not in (None,c)}
            for p in sorted(self.tiles[c]-main):
                for d in sorted({self.owners[q] for q in adjacent(p) if q in self.owners}-{c}-self.fixed):
                    other=self.parts[d][0]
                    if not any(q in other for q in adjacent(p)):continue
                    dx=sum(x for x,y in other)/len(other);dy=sum(y for x,y in other)/len(other)
                    def score(q):
                        # Prefer a nearby main-piece attachment, not a distant path.
                        return ((q[0]-cx)**2+(q[1]-cy)**2)/len(main)-((q[0]-dx)**2+(q[1]-dy)**2)/len(other)
                    for q in sorted(frontier&other,key=lambda q:(score(q),q))[:choices]:
                        a=(self.tiles[c]-{p})|{q};b=(self.tiles[d]-{q})|{p}
                        ap=pieces(a);bp=pieces(b)
                        if len(ap)>len(self.parts[c]) or len(bp)>len(self.parts[d]):continue
                        before=self.fragments(c)+self.fragments(d)
                        after=len(a)-len(ap[0])+len(b)-len(bp[0])
                        if after>=before:continue
                        self.tiles[c]=a;self.tiles[d]=b;self.parts[c]=ap;self.parts[d]=bp
                        self.owners[p]=d;self.owners[q]=c
                        return dict(component=c,other=d,fragment_cell=list(p),replacement_cell=list(q),fragment_reduction=before-after)
        return None

    def borrow_coast(self,c,maximum_cells=32,choices=64,maximum_depth=4):
        """Replace a blocked fragment through a neighbour that can grow at sea."""
        removed=self.tiles[c]-self.parts[c][0]
        if c in self.fixed or not 0<len(removed)<=maximum_cells:return None
        trial=Repair(self.tiles,self.fixed);trial.tiles[c]=set(self.parts[c][0]);trial.parts[c]=[trial.tiles[c]]
        for p in removed:del trial.owners[p]
        blocked=removed|{q for d in self.fixed for p in self.tiles[d] for q in [p]+adjacent(p)}
        transfers=[]
        def grow(receiver,visited,attempts):
            points=trial.tiles[receiver];cx=sum(x for x,y in points)/len(points);cy=sum(y for x,y in points)/len(points)
            coast={r for p in points for r in adjacent(p) if r not in trial.owners and r not in blocked}
            if coast:
                r=min(coast,key=lambda r:(4-2*sum(p in points for p in adjacent(r))+((r[0]-cx)**2+(r[1]-cy)**2)/len(points),r))
                points.add(r);trial.owners[r]=receiver;return r,[]
            if len(visited)>=maximum_depth:return None
            candidates={q for p in points for q in adjacent(p) if trial.owners.get(q) not in self.fixed|visited|{None}}
            for q in sorted(candidates,key=lambda q:((q[0]-cx)**2+(q[1]-cy)**2,q)):
                if attempts[0]>=choices:return None
                attempts[0]+=1;donor=trial.owners[q];remaining=trial.tiles[donor]-{q}
                if not remaining or len(pieces(remaining))!=1:continue
                points.add(q);trial.tiles[donor].remove(q);trial.owners[q]=receiver
                tail=grow(donor,visited|{donor},attempts)
                if tail is not None:
                    r,chain=tail;return q,[dict(component=donor,removed=q,added=r)]+chain
                points.remove(q);trial.tiles[donor].add(q);trial.owners[q]=donor
            return None
        for _ in removed:
            result=grow(c,{c},[0])
            if result is None:return None
            transfers.extend(result[1])
        added=trial.tiles[c]-self.tiles[c]
        self.tiles=trial.tiles;self.parts={d:pieces(p) for d,p in trial.tiles.items()};self.owners=trial.owners
        return dict(component=c,removed=sorted(removed),added=sorted(added),coast_compensations=transfers)

    def relocate(self,c,borrow=False):
        if c in self.fixed or len(self.parts[c])==1:return None
        grown=set(self.parts[c][0]);removed=self.tiles[c]-grown;count=len(self.tiles[c])
        cx=sum(x for x,y in grown)/len(grown);cy=sum(y for x,y in grown)/len(grown)
        blocked={p for p,owner in self.owners.items() if owner!=c}|removed
        blocked.update(q for owner in self.fixed for p in self.tiles[owner] for q in [p]+adjacent(p))
        frontier=[]
        def score(p):return 4-2*sum(q in grown for q in adjacent(p))+((p[0]-cx)**2+(p[1]-cy)**2)/count
        def offer(p):
            if p not in grown and p not in blocked:heapq.heappush(frontier,(score(p),p))
        for p in sorted(grown):
            for q in adjacent(p):offer(q)
        while len(grown)<count and frontier:
            cost,p=heapq.heappop(frontier)
            if p in grown:continue
            current=score(p)
            if abs(current-cost)>1e-10:heapq.heappush(frontier,(current,p));continue
            grown.add(p)
            for q in adjacent(p):offer(q)
        if len(grown)!=count:return self.borrow_coast(c) if borrow else None
        added=grown-self.tiles[c]
        for p in removed:del self.owners[p]
        for p in added:self.owners[p]=c
        self.tiles[c]=grown;self.parts[c]=[grown]
        return dict(component=c,removed=sorted(removed),added=sorted(added))


def run(inputs,layout,output,rounds=2000,choices=16,relocate_fragments=False,borrow_coast=False):
    if output.exists():raise ValueError('Output already exists')
    if rounds<1 or choices<1:raise ValueError('Use positive search limits')
    if borrow_coast and not relocate_fragments:raise ValueError('Coast borrowing requires fragment relocation')
    hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',layout/'complete.txt']}
    scripts={name:digest(Path(__file__).with_name(name)) for name in ['repair_partition.py','review_layout.py']}
    shapes,tiles,owners=load(inputs,layout)
    if any(len(tiles[c])!=int(shapes[c]['tiles']) for c in tiles):raise ValueError('Exact starting budgets required')
    movable={r[k] for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true' for k in ['a','b']}
    fixed=set(tiles)-movable;state=Repair(tiles,fixed);before=state.report();history=[];started=time.monotonic()
    for turn in range(rounds):
        move=state.step(choices)
        if move is None:break
        history.append(move)
        if len(history)%25==0:print(len(history),state.report(),flush=True)
    relocations=[]
    if relocate_fragments:
        for c in sorted(tiles,key=lambda c:(-state.fragments(c),c)):
            moved=state.relocate(c,borrow_coast)
            if moved is not None:relocations.append(moved)
    if not relocate_fragments and set(state.owners)!=set(owners):raise AssertionError('Footprint changed')
    if any(len(state.tiles[c])!=len(tiles[c]) for c in tiles):raise AssertionError('Budgets changed')
    if any(state.tiles[c]!=tiles[c] for c in fixed):raise AssertionError('Fixed island changed')
    record=dict(method='Count-preserving fragment swaps, with optional compact relocation of secondary pieces',before=before,after=state.report(),swaps=len(history),maximum_rounds=rounds,choices=choices,relocate_fragments=relocate_fragments,borrow_coast=borrow_coast,borrow_limit_cells=32 if borrow_coast else None,borrow_choices=64 if borrow_coast else None,borrow_maximum_depth=4 if borrow_coast else None,relocated_components=len(relocations),removed_land_cells=len(set(owners)-set(state.owners)),added_land_cells=len(set(state.owners)-set(owners)),fixed_components=len(fixed),elapsed_seconds=time.monotonic()-started,inputs=hashes,scripts=scripts,limit='Swaps leave the footprint unchanged and reduce cells outside the largest connected pieces without increasing region component counts. Optional relocation removes secondary pieces and grows the main piece into empty neighbour cells; it never connects to the discarded pieces. Relocation can change coasts and empty spaces. Optional coast borrowing replaces a blocked fragment through a bounded chain of adjacent donor-cell transfers; the final donor grows into empty space. It is limited to 32 fragment cells, 64 donor-cell choices per step, and four regions in a compensation chain. Some fragments can remain if growth is blocked. Occupied holes are allowed; borders and geographic positions are not guaranteed.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='repair-partition-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(state.tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        record['cells_sha256']=digest(temp/'cells.csv')
        (temp/'repair-partition.json').write_text(json.dumps(record,indent=2)+'\n')
        (temp/'swaps.json').write_text(json.dumps(history,indent=2)+'\n')
        (temp/'relocations.json').write_text(json.dumps(relocations,indent=2)+'\n')
        for name in ['parent-partition.json','partition.json','envelope.csv']:
            if (layout/name).exists():shutil.copyfile(layout/name,temp/('parent-partition.json' if name=='partition.json' else name))
        (temp/'complete.txt').write_text(f'mode={"partition-relocation" if relocations else "partition-repair"}\ncounts=exact\ncontacts=unconstrained\nfootprint={"modified" if relocations else "unchanged"}\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--rounds',type=int,default=2000);parser.add_argument('--choices',type=int,default=16)
    parser.add_argument('--relocate-fragments',action='store_true',help='Remove remaining secondary pieces and grow the main piece; changes the footprint')
    parser.add_argument('--borrow-coast',action='store_true',help='For up to 32 blocked fragment cells, use bounded neighbour chains that end at empty space; no connector paths')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
