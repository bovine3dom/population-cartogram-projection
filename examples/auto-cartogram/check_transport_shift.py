#!/usr/bin/env python3
"""Measure changes in each source's expected target position."""
import argparse
from array import array
import collections
import itertools
import json
import math
from pathlib import Path

from check_transport import rows
from save_review import digest


def compare(raw, corrected, allow_appended=False):
    checks=[]
    for directory in (raw,corrected):
        check=json.loads((directory/"independent-checks.json").read_text())
        if not check["checked"] or any(digest(directory/name)!=value for name,value in check["files"].items()):
            raise ValueError("Files differ from the independent checks")
        checks.append(check)
    if any(digest(raw/name)!=digest(corrected/name) for name in ("sources.csv","targets.csv")):
        raise ValueError("Source or target tables differ")
    sources={r["id"]:(r["group_id"],array("d",[float(r["value"]),0,0,0,0,0,0])) for r in rows(raw/"sources.csv")}
    pairs=0; appended=0; absolute_mass_change=0.0
    original_support=collections.defaultdict(set)
    for a,b in itertools.zip_longest(rows(raw/"mapping.csv"),rows(corrected/"mapping.csv")):
        if b is None or (a is None and not allow_appended):
            raise ValueError("Ordered sparse support differs")
        x,y=float(b["x"]),float(b["y"])
        if a is not None:
            if (a["id"],float(a["x"]),float(a["y"]))!=(b["id"],x,y):
                raise ValueError("Ordered sparse support differs")
            if allow_appended: original_support[a["id"]].add((x,y))
        else:
            if not any((x+dx,y+dy) in original_support[b["id"]] for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]):
                raise ValueError("Appended pair is not one rook step from original support")
            appended+=1
        state=sources[b["id"]][1]
        before,after=float(a["weight"]) if a is not None else 0.0,float(b["weight"])
        for offset,weight in ((1,before),(4,after)):
            state[offset]+=weight; state[offset+1]+=weight*x; state[offset+2]+=weight*y
        absolute_mass_change+=state[0]*abs(after-before)
        pairs+=1
    totals=collections.defaultdict(lambda:dict(source_cells=0,population=0.0,weighted_shift=0.0,
        weighted_squared_shift=0.0,maximum_shift=0.0,population_shift_above_one=0.0))
    for group,s in sources.values():
        if s[1]<=0 or s[4]<=0: raise ValueError("A source has no retained mass")
        shift=math.hypot(s[2]/s[1]-s[5]/s[4],s[3]/s[1]-s[6]/s[4])
        for key in (group,None):
            t=totals[key]; t["source_cells"]+=1; t["population"]+=s[0]
            t["weighted_shift"]+=s[0]*shift; t["weighted_squared_shift"]+=s[0]*shift*shift
            t["maximum_shift"]=max(t["maximum_shift"],shift)
            if shift>1: t["population_shift_above_one"]+=s[0]
    for t in totals.values():
        t["population_weighted_mean_shift"]=t.pop("weighted_shift")/t["population"]
        t["population_weighted_rms_shift"]=math.sqrt(t.pop("weighted_squared_shift")/t["population"])
        t["population_share_shift_above_one"]=t.pop("population_shift_above_one")/t["population"]
    return dict(ordered_support_unchanged=appended == 0,mapping_pairs=pairs,appended_pairs=appended,
        appended_pairs_one_rook_step=bool(appended),absolute_pair_mass_change=absolute_mass_change,
        unit="Target coordinate units; one square-tile side for these layouts",
        method="Normalize each source's retained weights before computing its expected target position; compare raw and corrected positions",
        limit="This measures a change in expectations, not a bound on each person's displacement. Opposite assignment changes can cancel. It does not assess absolute geographic accuracy.",
        summary=totals.pop(None),groups=dict(sorted(totals.items())),
        inputs={str(d):c["files"] for d,c in zip((raw,corrected),checks)},script_sha256=digest(Path(__file__)))


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("raw","corrected","output"): parser.add_argument(name,type=Path)
    parser.add_argument("--allow-appended",action="store_true",help="Allow appended pairs one rook step from original support")
    args=parser.parse_args()
    result=compare(args.raw,args.corrected,args.allow_appended)
    with args.output.open("x") as stream: json.dump(result,stream,indent=2); stream.write("\n")
