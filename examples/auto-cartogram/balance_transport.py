#!/usr/bin/env python3
"""Experiment: fit exported sparse transport to source and target marginals."""
import argparse
import csv
import hashlib
import json
import math
import shutil
import tempfile
import time
from pathlib import Path

import numpy as np

from check_transport import check, rows

SCRIPT_SHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def support_error_bound(row, column, supply, demand):
    """Necessary target-error bound from disconnected support components."""
    parent=list(range(len(supply)+len(demand)))
    def root(i):
        while parent[i] != i:
            parent[i]=parent[parent[i]]; i=parent[i]
        return i
    for i,j in zip(row,column):
        a,b=root(int(i)),root(len(supply)+int(j))
        if a != b: parent[max(a,b)]=min(a,b)
    a=np.bincount([root(i) for i in range(len(supply))],weights=supply,minlength=len(parent))
    b=np.bincount([root(len(supply)+j) for j in range(len(demand))],weights=demand,minlength=len(parent))
    if np.any((a == 0) != (b == 0)): raise ValueError("Source or target has no positive support")
    return float(np.max(np.abs(a[b>0]-b[b>0])/b[b>0]))


def scale(row, column, mass, supply, demand, iterations=5000, tolerance=1e-8):
    """Alternate column and row scaling; retain the original nonzero support."""
    row=np.asarray(row,dtype=np.int64); column=np.asarray(column,dtype=np.int64)
    mass=np.asarray(mass,dtype=float).copy()
    supply=np.asarray(supply,dtype=float); demand=np.asarray(demand,dtype=float)
    if iterations < 1 or not math.isfinite(tolerance) or tolerance <= 0:
        raise ValueError("Invalid scaling limits")
    if not len(mass) or len(row) != len(mass) or len(column) != len(mass):
        raise ValueError("Empty or inconsistent sparse matrix")
    if any(not np.all(np.isfinite(a) & (a > 0)) for a in [mass,supply,demand]):
        raise ValueError("Masses and marginals must be positive and finite")
    if row.min() < 0 or column.min() < 0 or row.max() >= len(supply) or column.max() >= len(demand):
        raise ValueError("Sparse index out of range")
    if not np.isclose(supply.sum(),demand.sum(),rtol=1e-12,atol=1e-7):
        raise ValueError("Total supply and demand differ")
    bound=support_error_bound(row,column,supply,demand)
    if bound > tolerance:
        raise ValueError(f"Disconnected support requires target error >= {bound:.9g}")
    for turn in range(1,iterations+1):
        columns=np.bincount(column,weights=mass,minlength=len(demand))
        if np.any(columns <= 0): raise ValueError("Target has no positive support")
        mass *= (demand/columns)[column]
        sums=np.bincount(row,weights=mass,minlength=len(supply))
        if np.any(sums <= 0): raise ValueError("Source has no positive support")
        mass *= (supply/sums)[row]
        error=float(np.max(np.abs(np.bincount(column,weights=mass,minlength=len(demand))/demand-1)))
        if error <= tolerance:
            return mass,turn,error
    raise ValueError(f"Sparse scaling did not converge in {iterations} iterations; target error={error:.9g}. Support may be infeasible.")


def expand_neighbours(row, column, mass, supply, sources, targets, groups):
    """Add one rook step within selected groups; seed new pairs, not new mass."""
    groups=set(groups)
    if not groups <= {r["group_id"] for r in sources}:
        raise ValueError("Unknown expansion group")
    coordinates={(float(r["x"]),float(r["y"])):j for j,r in enumerate(targets)}
    support=[set() for _ in sources]
    for i,j in zip(row,column): support[i].add(int(j))
    extra=[]
    for i,existing in enumerate(support):
        group=sources[i]["group_id"]
        if group not in groups: continue
        adjacent=set()
        for j in existing:
            if targets[j]["group_id"] != group: raise ValueError("Support crosses groups")
            x,y=float(targets[j]["x"]),float(targets[j]["y"])
            for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]:
                k=coordinates.get((x+dx,y+dy))
                if k is not None and targets[k]["group_id"] == group: adjacent.add(k)
        added=sorted(adjacent-existing)
        extra.extend((i,j,supply[i]*1e-3/len(added)) for j in added)
    new_row=np.array([p[0] for p in extra],dtype=np.int64)
    new_column=np.array([p[1] for p in extra],dtype=np.int64)
    initial=np.r_[mass,[p[2] for p in extra]]
    row=np.r_[row,new_row]; column=np.r_[column,new_column]
    # Restore the original retained total per source after adding the seed.
    before=np.bincount(row[:len(mass)],weights=mass,minlength=len(supply))
    after=np.bincount(row,weights=initial,minlength=len(supply))
    initial *= (before/after)[row]
    return row,column,initial,len(extra)


def run(directory, output, iterations=5000, tolerance=1e-8, expand_groups=()):
    if output.exists(): raise ValueError("Output already exists")
    original_checks=check(directory)
    metadata=json.loads((directory/"manifest.json").read_text())
    sources=list(rows(directory/"sources.csv")); targets=list(rows(directory/"targets.csv"))
    source_index={r["id"]:i for i,r in enumerate(sources)}
    target_index={(float(r["x"]),float(r["y"])):i for i,r in enumerate(targets)}
    supply=np.array([float(r["value"]) for r in sources])
    demand=np.empty(len(targets))
    # The quality table need not have the same order as targets.csv.
    for r in rows(directory/"target-quality.csv"):
        demand[target_index[float(r["x"]),float(r["y"])]]=float(r["expected_population"])
    row=[]; column=[]; weights=[]
    for r in rows(directory/"mapping.csv"):
        row.append(source_index[r["id"]]); column.append(target_index[float(r["x"]),float(r["y"])])
        weights.append(float(r["weight"]))
    row=np.asarray(row); column=np.asarray(column)
    original=np.asarray(weights)*supply[row]
    initial=original
    added=0
    if expand_groups:
        if metadata["pooled"]: raise ValueError("Support expansion requires grouped transport")
        row,column,initial,added=expand_neighbours(row,column,original,supply,sources,targets,expand_groups)
        original=np.r_[original,np.zeros(added)]
    started=time.monotonic()
    mass,turn,error=scale(row,column,initial,supply,demand,iterations,tolerance)
    retained=np.bincount(row,weights=mass/supply[row],minlength=len(sources))
    totals=np.bincount(column,weights=mass,minlength=len(targets))
    source_groups=np.array([r["group_id"] for r in sources]); target_groups=np.array([r["group_id"] for r in targets])
    crossing=float(mass[source_groups[row] != target_groups[column]].sum())
    metadata.update(source_population=float(supply.sum()),retained_population=float(mass.sum()),
        retained_share=float(mass.sum()/supply.sum()),cross_group_population=crossing,
        minimum_source_retained_share=float(retained.min()),maximum_source_retained_share=float(retained.max()),
        maximum_relative_target_error=error)
    metadata["sparse_balance"]=dict(method="Alternating target and source scaling",
        iterations=turn,maximum_iterations=iterations,tolerance=tolerance,elapsed_seconds=time.monotonic()-started,
        absolute_mass_change=float(np.abs(mass-original).sum()),script_sha256_at_load=SCRIPT_SHA256,
        original_checks=original_checks,added_pairs=added,expanded_groups=sorted(set(expand_groups)),
        support_rule="One rook step within selected groups; seed 0.001 of source mass across new pairs, then restore original source retention." if expand_groups else "Unchanged sparse support",
        limit="Does not prove spatial quality or a minimum-cost allocation.")
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="balanced-transport-",dir=output.parent))
    try:
        for name in ["sources.csv","targets.csv"]: shutil.copyfile(directory/name,temp/name)
        with (temp/"mapping.csv").open("w",newline="") as stream:
            writer=csv.writer(stream,lineterminator="\n"); writer.writerow(["x","y","id","weight","weight_mean"])
            for i,j,value in zip(row,column,mass):
                writer.writerow([targets[j]["x"],targets[j]["y"],sources[i]["id"],value/supply[i],value/totals[j]])
        with (temp/"target-quality.csv").open("w",newline="") as stream:
            writer=csv.writer(stream,lineterminator="\n")
            writer.writerow(["x","y","group_id","population","expected_population","relative_error"])
            for r,value,expected in zip(targets,totals,demand):
                writer.writerow([r["x"],r["y"],r["group_id"],value,expected,value/expected-1])
        (temp/"manifest.json").write_text(json.dumps(metadata,indent=2)+"\n")
        checked=check(temp)
        (temp/"independent-checks.json").write_text(json.dumps(checked,indent=2)+"\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return metadata["sparse_balance"]


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory",type=Path); parser.add_argument("output",type=Path)
    parser.add_argument("--iterations",type=int,default=5000); parser.add_argument("--tolerance",type=float,default=1e-8)
    parser.add_argument("--expand-group",action="append",default=[],help="Add one rook step of support within this group; can be repeated")
    args=parser.parse_args()
    print(json.dumps(run(args.directory,args.output,args.iterations,args.tolerance,args.expand_group),indent=2))
