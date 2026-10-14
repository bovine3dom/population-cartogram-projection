#!/usr/bin/env python3
"""Build an exact-count, separate-component baseline. This does not preserve borders."""
import argparse
import csv
import hashlib
import heapq
import json
import math
import shutil
import tempfile
import time
from pathlib import Path

from shapely import affinity
from shapely.geometry import Point, Polygon

from review_layout import NEIGHBOURS, read_csv, load, connectivity, holes


def simple_toggle(cells, p):
    # A single land run and a single sea run, each with a side neighbour.
    ring = [(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]
    inside = [(p[0]+dx,p[1]+dy) in cells for dx,dy in ring]
    runs = sum(inside[i] and not inside[i-1] for i in range(8))
    return runs == 1 and any(inside[::2]) and not all(inside[::2])


def grow(polygon, count):
    if not polygon.is_valid or polygon.area <= 0:
        raise ValueError("Invalid guide polygon")
    centre = polygon.centroid
    scale = math.sqrt(count/polygon.area)
    guide = affinity.scale(affinity.translate(polygon,-centre.x,-centre.y),scale,scale,origin=(0,0))
    start = guide.representative_point()
    start = (round(start.x),round(start.y))
    cells = {start}
    frontier, queued = [], set()
    def offer(p):
        if p in cells or p in queued:
            return
        point = Point(p)
        # Prefer interior tiles, then nearby exterior tiles. A small radial
        # term gives deterministic, compact choices within the same category.
        score = guide.distance(point) + 0.001*math.hypot(*p)/max(math.sqrt(count),1)
        heapq.heappush(frontier,(score,p)); queued.add(p)
    while len(cells) < count:
        for dx,dy in NEIGHBOURS:
            offer((start[0]+dx,start[1]+dy))
        rejected = []
        while frontier:
            score,p = heapq.heappop(frontier); queued.remove(p)
            if simple_toggle(cells,p):
                cells.add(p); start=p
                break
            rejected.append((score,p))
        else:
            raise ValueError("No simple growth move")
        for score,p in rejected:
            heapq.heappush(frontier,(score,p)); queued.add(p)
    return cells, (centre.x,centre.y)


def place(cells, desired, blocked):
    cx = sum(x for x,y in cells)/len(cells)
    cy = sum(y for x,y in cells)/len(cells)
    origin = (round(desired[0]-cx),round(desired[1]-cy))
    for radius in range(10000):
        offsets = {(x,y) for x in range(-radius,radius+1) for y in (-radius,radius)}
        offsets.update((x,y) for y in range(-radius+1,radius) for x in (-radius,radius))
        for dx,dy in sorted(offsets,key=lambda p:(p[0]**2+p[1]**2,p)):
            shift = origin[0]+dx,origin[1]+dy
            moved = {(x+shift[0],y+shift[1]) for x,y in cells}
            if not moved & blocked:
                return moved
    raise ValueError("Placement search exhausted")


def run(inputs, output, spacing=1.6, reuse_layout=None):
    if output.exists():
        raise ValueError("Output already exists")
    if not math.isfinite(spacing) or spacing <= 0:
        raise ValueError("Spacing must be positive and finite")
    started = time.monotonic()
    rows = {r["component_id"]:r for r in read_csv(inputs/"groups.csv") if int(r["tiles"]) > 0}
    lines = (inputs/"validated.wkt").read_text().splitlines()
    polygons = {lines[i].split("\t")[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split("\t")])
                for i in range(2,len(lines),3)}
    if set(polygons) != set(rows):
        raise ValueError("Outline labels differ from groups")
    scale = spacing*math.sqrt(sum(int(r["tiles"]) for r in rows.values())/sum(p.area for p in polygons.values()))
    templates=None; parent={}
    if reuse_layout is not None:
        parent={"template_cells_sha256":hashlib.sha256((reuse_layout/"cells.csv").read_bytes()).hexdigest(),
                "template_generation":(reuse_layout/"complete.txt").read_text().splitlines()}
        _,templates,owners=load(inputs,reuse_layout)
        if any(r["both_represented"]=="true" for r in read_csv(inputs/"geographic-contacts.csv")) or any(
                owners.get((x+dx,y+dy),owner)!=owner for (x,y),owner in owners.items() for dx,dy in NEIGHBOURS):
            raise ValueError("Repositioning requires islands without land contacts")
        if any(len(cells)!=int(rows[label]["tiles"]) or connectivity(cells)!=1 or holes(cells)
               for label,cells in templates.items()):
            raise ValueError("Invalid island template counts or topology")
    blocked, result = set(), {}
    for label in sorted(rows,key=lambda c:(-int(rows[c]["tiles"]),c)):
        if templates is None:
            cells,centre = grow(polygons[label],int(rows[label]["tiles"]))
        else:
            cells=templates[label]
            centre=polygons[label].centroid.coords[0]
        moved = place(cells,(centre[0]*scale,centre[1]*scale),blocked)
        result[label] = moved
        blocked.update(moved)
        blocked.update((x+dx,y+dy) for x,y in moved for dx,dy in NEIGHBOURS)
        print(f"{len(result)}/{len(rows)} {label}: {len(moved)}",flush=True)
    output.parent.mkdir(parents=True,exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix="baseline-",dir=output.parent))
    try:
        with (temp/"cells.csv").open("w") as stream:
            writer=csv.writer(stream); writer.writerow(["component_id","x","y"])
            for label,cells in sorted(result.items()):
                writer.writerows((label,x,y) for x,y in sorted(cells))
        metadata = {"method":"Separate outline-guided growth with geographic placement" if templates is None else "Geographic placement of existing island shapes",
                    **parent,
                    "limit":"No land borders retained. Islands with zero budgets remain grouped." if templates is None else
                            "Requires no represented land borders; keeps each island shape and count. Zero-budget islands remain grouped.",
                    "spacing":spacing,"elapsed_seconds":time.monotonic()-started,
                    "script_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        (temp/"baseline.json").write_text(json.dumps(metadata,indent=2)+"\n")
        (temp/"complete.txt").write_text("mode=geographic-baseline\ncontacts=not-preserved\n" if templates is None else
                                        "mode=geographic-reposition\ncontacts=none-required\n")
        temp.rename(output)
    finally:
        if temp.exists():
            shutil.rmtree(temp)
    return metadata


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--spacing",type=float,default=1.6)
    parser.add_argument("--reuse-layout",type=Path,help="Reposition existing shapes; require no land contacts")
    args=parser.parse_args()
    print(json.dumps(run(args.inputs,args.output,args.spacing,args.reuse_layout),indent=2))
