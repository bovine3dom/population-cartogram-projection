#!/usr/bin/env python3
"""Reduce partition fragments by swaps; keep counts and occupied cells fixed."""
import argparse
import csv
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


def run(inputs,layout,output,rounds=2000,choices=16):
    if output.exists():raise ValueError('Output already exists')
    if rounds<1 or choices<1:raise ValueError('Use positive search limits')
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
    if set(state.owners)!=set(owners) or any(len(state.tiles[c])!=len(tiles[c]) for c in tiles):raise AssertionError('Footprint or budgets changed')
    if any(state.tiles[c]!=tiles[c] for c in fixed):raise AssertionError('Fixed island changed')
    record=dict(method='Count-preserving fragment swaps on an unchanged footprint',before=before,after=state.report(),swaps=len(history),maximum_rounds=rounds,choices=choices,fixed_components=len(fixed),elapsed_seconds=time.monotonic()-started,inputs=hashes,scripts=scripts,limit='No connector cells are added. Each swap reduces cells outside the largest connected pieces and does not increase either region component count. Some fragments can remain. Occupied holes are allowed; borders and geographic positions are not guaranteed. All empty spaces are unchanged, including artificial gaps in the input footprint.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='repair-partition-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(state.tiles.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        record['cells_sha256']=digest(temp/'cells.csv')
        (temp/'repair-partition.json').write_text(json.dumps(record,indent=2)+'\n')
        (temp/'swaps.json').write_text(json.dumps(history,indent=2)+'\n')
        for name in ['partition.json','envelope.csv']:
            if (layout/name).exists():shutil.copyfile(layout/name,temp/('parent-partition.json' if name=='partition.json' else name))
        (temp/'complete.txt').write_text('mode=partition-repair\ncounts=exact\ncontacts=unconstrained\nfootprint=unchanged\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--rounds',type=int,default=2000);parser.add_argument('--choices',type=int,default=16)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
