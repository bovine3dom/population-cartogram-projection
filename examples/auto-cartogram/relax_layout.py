#!/usr/bin/env python3
"""Move whole tile shapes toward required neighbours before border repair."""
import argparse
import csv
import hashlib
import json
import math
import shutil
import tempfile
import time
from pathlib import Path

from shapely import affinity, union_all
from shapely.geometry import box

from repair_contacts import Repair, neighbours
from review_layout import load, read_csv

SCRIPT_SHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def relax(tiles, required, rounds=200, stiffness=.05):
    if rounds < 1 or not math.isfinite(stiffness) or stiffness <= 0:
        raise ValueError("Rounds and anchor stiffness must be positive")
    state=Repair(tiles,required)
    geometry={c:union_all([box(x,y,x+1,y+1) for x,y in sorted(points)]) for c,points in tiles.items()}
    offset={c:(0,0) for c in tiles}
    weights={c:stiffness*math.sqrt(len(points)) for c,points in tiles.items()}
    order=sorted(tiles,key=lambda c:(-len(tiles[c]),c))
    def score(c, shape, shift):
        return weights[c]*(shift[0]**2+shift[1]**2)+sum(shape.distance(geometry[n])**2 for n in sorted(state.allowed[c]))
    def energy():
        return sum(geometry[a].distance(geometry[b])**2 for a,b in sorted(required))+sum(weights[c]*(x*x+y*y) for c,(x,y) in offset.items())
    initial=energy(); moves=0
    for turn in range(1,rounds+1):
        changes=0
        for c in order:
            if not state.allowed[c]: continue
            best=score(c,geometry[c],offset[c]); choice=None
            current=state.tiles[c]; allowed=state.allowed[c]|{c,None}
            for dx,dy in [(-1,0),(0,-1),(0,1),(1,0),(-1,-1),(-1,1),(1,-1),(1,1)]:
                moved={(x+dx,y+dy) for x,y in current}; incoming=moved-current
                if any(p in state.owners for p in incoming): continue
                if any(state.owners.get(q) not in allowed for p in incoming for q in neighbours(p)): continue
                shape=affinity.translate(geometry[c],dx,dy)
                shift=(offset[c][0]+dx,offset[c][1]+dy)
                value=score(c,shape,shift)
                if value < best-1e-9:
                    best=value; choice=moved,shape,shift
            if choice is None: continue
            moved,shape,shift=choice
            for p in sorted(current-moved): state.change(c,p,False)
            for p in sorted(moved-current): state.change(c,p,True)
            geometry[c]=shape; offset[c]=shift; changes+=1
        moves+=changes
        print(f"Relax round {turn}: {changes} translations, energy {energy():.6f}",flush=True)
        if not changes: break
    if set(state.contacts)-set(required) or any(len(state.tiles[c]) != len(tiles[c]) for c in tiles):
        raise ValueError("Translation violated count or contact constraints")
    return state.tiles,dict(rounds=turn,moves=moves,initial_energy=initial,final_energy=energy(),
        maximum_translation=max(math.hypot(*p) for p in offset.values()),stiffness=stiffness)


def run(inputs, layout, output, rounds=200, stiffness=.05):
    if output.exists(): raise ValueError("Output already exists")
    shapes,tiles,_=load(inputs,layout)
    if any(len(tiles[c]) != int(r["tiles"]) for c,r in shapes.items()):
        raise ValueError("Translation requires exact component counts")
    required={tuple(sorted((r["a"],r["b"]))) for r in read_csv(inputs/"geographic-contacts.csv") if r["both_represented"] == "true"}
    started=time.monotonic()
    result,metadata=relax(tiles,required,rounds,stiffness)
    metadata.update(method="Greedy whole-shape translation with border-distance and geographic-anchor costs",
        maximum_rounds=rounds,elapsed_seconds=time.monotonic()-started,script_sha256_at_load=SCRIPT_SHA256,
        input_cells_sha256=hashlib.sha256((layout/"cells.csv").read_bytes()).hexdigest(),
        limit="Borders can remain missing. Position can worsen. No global optimum or correct island order is guaranteed.")
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="relaxed-",dir=output.parent))
    try:
        with (temp/"cells.csv").open("w",newline="") as stream:
            writer=csv.writer(stream,lineterminator="\n"); writer.writerow(["component_id","x","y"])
            for c,points in sorted(result.items()): writer.writerows((c,x,y) for x,y in sorted(points))
        (temp/"relax.json").write_text(json.dumps(metadata,indent=2)+"\n")
        (temp/"complete.txt").write_text("mode=relaxed-geographic\ncounts=exact\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return metadata


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["inputs","layout","output"]: parser.add_argument(name,type=Path)
    parser.add_argument("--rounds",type=int,default=200); parser.add_argument("--stiffness",type=float,default=.05)
    args=parser.parse_args()
    print(json.dumps(run(args.inputs,args.layout,args.output,args.rounds,args.stiffness),indent=2))
