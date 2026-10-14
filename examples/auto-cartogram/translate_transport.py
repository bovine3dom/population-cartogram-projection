#!/usr/bin/env python3
"""Move transport targets with rigidly translated island shapes; keep all weights."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile

from check_transport import check, rows
from save_review import digest


def layout_cells(directory):
    if not (directory/"complete.txt").exists(): raise ValueError("Incomplete layout")
    shapes={}; occupied=set()
    for r in rows(directory/"cells.csv"):
        point=(int(r["x"]),int(r["y"]))
        if point in occupied: raise ValueError("Overlapping layout cells")
        occupied.add(point); shapes.setdefault(r["component_id"],set()).add(point)
    if not shapes: raise ValueError("Empty layout")
    return shapes


def translations(before, after):
    if before.keys()!=after.keys(): raise ValueError("Layout groups differ")
    result={}
    for group,cells in before.items():
        a=min(cells); b=min(after[group]); shift=b[0]-a[0],b[1]-a[1]
        if {(x+shift[0],y+shift[1]) for x,y in cells}!=after[group]:
            raise ValueError("A group changed shape instead of translating")
        result[group]=shift
    return result


def run(transport, original, moved, output):
    if output.exists(): raise ValueError("Output already exists")
    verified=json.loads((transport/"independent-checks.json").read_text())
    if not verified["checked"] or any(digest(transport/name)!=value for name,value in verified["files"].items()):
        raise ValueError("Transport differs from its independent checks")
    before,after=layout_cells(original),layout_cells(moved)
    shifts=translations(before,after)
    owners={p:g for g,cells in before.items() for p in cells}
    targets={(float(r["x"]),float(r["y"])):r["group_id"] for r in rows(transport/"targets.csv")}
    if owners!=targets: raise ValueError("Transport targets differ from the original layout")
    metadata=json.loads((transport/"manifest.json").read_text())
    metadata["target_translation"]={"method":"Push the existing mapping through a checked per-group integer translation; do not solve again or change weights",
        "shifts":shifts,"source_target_pairs":verified["mapping_rows"],"script_sha256":digest(Path(__file__)),
        "inputs":[{"path":str(p.resolve()),"sha256":digest(p)} for p in
                  (transport/"manifest.json",transport/"independent-checks.json",original/"cells.csv",moved/"cells.csv")]}
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="translated-transport-",dir=output.parent))
    try:
        shutil.copyfile(transport/"sources.csv",temp/"sources.csv")
        for name in ("targets.csv","mapping.csv","target-quality.csv"):
            with (transport/name).open() as source, (temp/name).open("w",newline="") as destination:
                reader=csv.DictReader(source); writer=csv.DictWriter(destination,fieldnames=reader.fieldnames,lineterminator="\n")
                writer.writeheader()
                for row in reader:
                    point=float(row["x"]),float(row["y"])
                    dx,dy=shifts[owners[point]]
                    row["x"],row["y"]=int(point[0])+dx,int(point[1])+dy
                    writer.writerow(row)
        (temp/"manifest.json").write_text(json.dumps(metadata,indent=2)+"\n")
        result=check(temp)
        (temp/"independent-checks.json").write_text(json.dumps(result,indent=2)+"\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return result


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("transport","original","moved","output"): parser.add_argument(name,type=Path)
    args=parser.parse_args()
    print(json.dumps(run(args.transport,args.original,args.moved,args.output),indent=2))
