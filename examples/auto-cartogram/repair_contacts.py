#!/usr/bin/env python3
"""Try to repair geographic-baseline borders while keeping exact component counts."""
import argparse
import collections
import csv
import hashlib
import heapq
import json
import math
import shutil
import tempfile
import time
from pathlib import Path

from geographic_baseline import simple_toggle
from review_layout import NEIGHBOURS, connectivity, holes, load, read_csv

SCRIPT_SHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def neighbours(p):
    return [(p[0]+dx,p[1]+dy) for dx,dy in NEIGHBOURS]


class Repair:
    def __init__(self, tiles, required, max_search=30000):
        self.tiles={c:set(points) for c,points in tiles.items()}
        if any(connectivity(p) != 1 or holes(p) for p in self.tiles.values()):
            raise ValueError("Starting regions must be connected and have no holes")
        self.owners={p:c for c,points in self.tiles.items() for p in points}
        if len(self.owners) != sum(map(len,self.tiles.values())):
            raise ValueError("Overlapping starting tiles")
        self.required=set(required)
        self.allowed={c:set() for c in tiles}
        for a,b in self.required:
            self.allowed[a].add(b); self.allowed[b].add(a)
        self.contacts=collections.Counter()
        for p,c in self.owners.items():
            for dx,dy in [(1,0),(0,1)]:
                other=self.owners.get((p[0]+dx,p[1]+dy))
                if other is not None and other != c:
                    self.contacts[tuple(sorted((c,other)))]+=1
        if set(self.contacts)-self.required:
            raise ValueError("Starting layout has false contacts")
        self.centres={c:(sum(x for x,y in points)/len(points),sum(y for x,y in points)/len(points)) for c,points in tiles.items()}
        self.max_search=max_search

    def change(self, owner, p, add):
        for q in neighbours(p):
            other=self.owners.get(q)
            if other is not None and other != owner:
                pair=tuple(sorted((owner,other)))
                self.contacts[pair]+=1 if add else -1
                if self.contacts[pair] == 0:
                    del self.contacts[pair]
        if add:
            if p in self.owners:
                raise ValueError("Cannot add an occupied tile")
            self.owners[p]=owner; self.tiles[owner].add(p)
        else:
            del self.owners[p]; self.tiles[owner].remove(p)

    def route(self, owner, target, forbidden):
        cells=self.tiles[target]
        xmin,xmax=min(x for x,y in cells),max(x for x,y in cells)
        ymin,ymax=min(y for x,y in cells),max(y for x,y in cells)
        def heuristic(p):
            return max(xmin-p[0],0,p[0]-xmax)+max(ymin-p[1],0,p[1]-ymax)
        distance={p:0 for p in self.tiles[owner] if any(q not in self.owners for q in neighbours(p))}
        parent={p:None for p in distance}
        queue=[(heuristic(p),0,p) for p in sorted(distance)]
        heapq.heapify(queue)
        visited=0
        while queue and visited < self.max_search:
            _,cost,p=heapq.heappop(queue)
            if cost != distance[p]:
                continue
            visited+=1
            if any(self.owners.get(q) == target for q in neighbours(p)):
                path=[]
                while parent[p] is not None:
                    path.append(p); p=parent[p]
                return list(reversed(path))
            for q in neighbours(p):
                if q in self.owners or q in forbidden or cost+1 >= distance.get(q,math.inf):
                    continue
                adjacent={self.owners[r] for r in neighbours(q) if r in self.owners}-{owner}
                if adjacent-self.allowed[owner]:
                    continue
                distance[q]=cost+1; parent[q]=p
                heapq.heappush(queue,(cost+1+heuristic(q),cost+1,q))
        return None

    def removable(self, owner, p):
        if not simple_toggle(self.tiles[owner],p):
            return False
        losses=collections.Counter(self.owners[q] for q in neighbours(p) if q in self.owners and self.owners[q] != owner)
        return all(self.contacts[tuple(sorted((owner,other)))] > count for other,count in losses.items())

    def connect(self, owner, target):
        original=set(self.tiles[owner])
        forbidden=set()
        cx,cy=self.centres[owner]
        priority=lambda p: (-((p[0]-cx)**2+(p[1]-cy)**2),p)
        for attempt in range(3):
            path=self.route(owner,target,forbidden)
            if not path:
                return False,"no route"
            candidates=[priority(p) for p in self.tiles[owner]]
            heapq.heapify(candidates)
            failed=None
            for p in path:
                if not simple_toggle(self.tiles[owner],p):
                    failed=p; break
                self.change(owner,p,True)
                heapq.heappush(candidates,priority(p))
                rejected=[]; removed=False
                while candidates:
                    item=heapq.heappop(candidates); q=item[1]
                    if q not in self.tiles[owner]:
                        continue
                    if q != p and self.removable(owner,q):
                        self.change(owner,q,False); removed=True; break
                    rejected.append(item)
                for item in rejected:
                    heapq.heappush(candidates,item)
                if not removed:
                    failed=p; break
            if failed is None:
                if len(self.tiles[owner]) != len(original):
                    raise ValueError("Count changed during border repair")
                return True,"connected"
            # Roll back the whole proposed bridge, including its contact counts.
            for p in sorted(self.tiles[owner]):
                self.change(owner,p,False)
            for p in sorted(original):
                self.change(owner,p,True)
            forbidden.add(failed)
        return False,"no simple count-preserving move"


def run(inputs, baseline, output, max_search=30000, passes=2):
    if output.exists():
        raise ValueError("Output already exists")
    shapes,tiles,_=load(inputs,baseline)
    if any(len(tiles[c]) != int(r["tiles"]) for c,r in shapes.items()):
        raise ValueError("Border repair requires an exact-count baseline")
    required={tuple(sorted((r["a"],r["b"]))) for r in read_csv(inputs/"geographic-contacts.csv") if r["both_represented"] == "true"}
    state=Repair(tiles,required,max_search)
    started=time.monotonic(); attempts=[]
    for turn in range(passes):
        missing=required-set(state.contacts)
        if not missing:
            break
        order=sorted(missing,key=lambda pair:(math.dist(state.centres[pair[0]],state.centres[pair[1]]),pair))
        improved=0
        for a,b in order:
            if (a,b) in state.contacts:
                continue
            choices=sorted([(a,b),(b,a)],key=lambda pair:(-len(state.tiles[pair[0]]),pair))
            for owner,target in choices:
                success,reason=state.connect(owner,target)
                attempts.append(dict(pass_number=turn+1,owner=owner,target=target,success=success,reason=reason))
                if success:
                    improved+=1; break
            print(f"Pass {turn+1}: {len(state.contacts)}/{len(required)} contacts; {a} -- {b}",flush=True)
        if not improved:
            break
    if set(state.contacts)-required or any(len(state.tiles[c]) != len(tiles[c]) for c in tiles):
        raise ValueError("Repair violated count or contact constraints")
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="border-repair-",dir=output.parent))
    try:
        with (temp/"cells.csv").open("w") as stream:
            writer=csv.writer(stream); writer.writerow(["component_id","x","y"])
            for label,points in sorted(state.tiles.items()):
                writer.writerows((label,x,y) for x,y in sorted(points))
        with (temp/"attempts.csv").open("w") as stream:
            writer=csv.DictWriter(stream,fieldnames=["pass_number","owner","target","success","reason"])
            writer.writeheader(); writer.writerows(attempts)
        metadata=dict(method="Greedy geographic border repair with exact counts",max_search=max_search,passes=passes,
            required_contacts=len(required),retained_contacts=len(state.contacts),elapsed_seconds=time.monotonic()-started,
            limit="Some borders can remain missing. Position and shape can worsen. This is not the published mosaic algorithm.",
            baseline_cells_sha256=hashlib.sha256((baseline/"cells.csv").read_bytes()).hexdigest(),
            baseline_generation=(baseline/"complete.txt").read_text().splitlines(),
            baseline_metadata={name:json.loads((baseline/name).read_text()) for name in ["baseline.json","relax.json"] if (baseline/name).exists()},
            script_sha256=SCRIPT_SHA256)
        (temp/"repair.json").write_text(json.dumps(metadata,indent=2)+"\n")
        (temp/"complete.txt").write_text("mode=geographic-border-repair\ncounts=exact\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return metadata


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["inputs","baseline","output"]:
        parser.add_argument(name,type=Path)
    parser.add_argument("--max-search",type=int,default=30000)
    parser.add_argument("--passes",type=int,default=2)
    args=parser.parse_args()
    if args.max_search < 1 or args.passes < 1:
        parser.error("Search and pass limits must be positive")
    print(json.dumps(run(args.inputs,args.baseline,args.output,args.max_search,args.passes),indent=2))
