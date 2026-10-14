#!/usr/bin/env python3
"""Check whether saved group pairs permit exact source and target totals."""
import argparse
from collections import defaultdict
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import time

import networkx as nx

from check_transport import check, rows


def equal_target_cut(supply, neighbours, target_count):
    """Use integer capacities and return a cut witness for equal target totals."""
    if (not supply or len(supply) != len(neighbours) or target_count < 1
            or any(type(v) is not int or v <= 0 for v in supply)):
        raise ValueError("Positive integer source populations are required")
    bins=defaultdict(int)
    for value, targets in zip(supply,neighbours):
        key=tuple(sorted(set(targets)))
        if not key or any(type(j) is not int or not 0 <= j < target_count for j in key):
            raise ValueError("Missing or invalid source support")
        bins[key]+=value
    population=sum(supply); required=population*target_count
    graph=nx.DiGraph(); offset=2+len(bins)
    # Multiply all capacities by target_count. Each target then needs population.
    for i,(targets,value) in enumerate(bins.items(),2):
        graph.add_edge(0,i,capacity=value*target_count)
        for j in targets: graph.add_edge(i,offset+j,capacity=required+1)
    for j in range(target_count): graph.add_edge(offset+j,1,capacity=population)
    flow,(reachable,_) = nx.minimum_cut(graph,0,1,flow_func=nx.algorithms.flow.preflow_push)
    selected=[j for j in range(target_count) if flow < required and offset+j in reachable]
    allowed=set(selected)
    witness=[i for i,targets in enumerate(neighbours) if set(targets) <= allowed]
    mass=sum(supply[i] for i in witness)
    excess=mass*target_count-len(selected)*population
    if flow < required:
        if not selected or excess != required-flow:
            raise AssertionError("Invalid minimum-cut witness")
        bound=excess/(len(selected)*population)
    else:
        if flow != required: raise AssertionError("Flow exceeds source supply")
        bound=0.0
    return dict(exact_marginals_feasible=flow == required,source_population=population,
        sources=len(supply),targets=target_count,distinct_source_neighbourhoods=len(bins),
        capacity_multiplier=target_count,required_integer_flow=required,maximum_integer_flow=flow,
        necessary_maximum_relative_target_error=bound,witness_target_indices=selected,
        witness_source_count=len(witness),witness_source_population=mass,
        witness_excess_scaled=excess)


def run(directory):
    started=time.monotonic(); checked=check(directory)
    metadata=json.loads((directory/"manifest.json").read_text())
    if metadata["pooled"]: raise ValueError("This check requires grouped transport")
    sources=list(rows(directory/"sources.csv")); targets=list(rows(directory/"targets.csv"))
    source_index={r["id"]:i for i,r in enumerate(sources)}
    target_index={(float(r["x"]),float(r["y"])):i for i,r in enumerate(targets)}
    neighbours=[[] for _ in sources]
    for r in rows(directory/"mapping.csv"):
        neighbours[source_index[r["id"]]].append(target_index[float(r["x"]),float(r["y"])])
    source_groups=defaultdict(list); target_groups=defaultdict(list); supply=[]
    for i,r in enumerate(sources):
        value=Decimal(r["value"])
        if not value.is_finite() or value != value.to_integral_value():
            raise ValueError("Fractional source population is not supported")
        supply.append(int(value)); source_groups[r["group_id"]].append(i)
    for i,r in enumerate(targets): target_groups[r["group_id"]].append(i)
    results=[]
    for group,indices in sorted(source_groups.items()):
        local={j:i for i,j in enumerate(target_groups[group])}
        result=equal_target_cut([supply[i] for i in indices],
            [[local[j] for j in neighbours[i]] for i in indices],len(local))
        result["group_id"]=group
        result["witness_targets"]=[{k:targets[target_groups[group][j]][k] for k in ["x","y"]}
            for j in result.pop("witness_target_indices")]
        results.append(result)
    return dict(groups=results,infeasible_groups=sum(not r["exact_marginals_feasible"] for r in results),
        necessary_maximum_relative_target_error=max(r["necessary_maximum_relative_target_error"] for r in results),
        checked_inputs=checked,elapsed_seconds=time.monotonic()-started,networkx_version=nx.__version__,
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        limit="Feasibility permits zero weight on saved pairs. It does not prove convergence of positive scaling or spatial quality. The cut error bound need not be the strongest bound.")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory",type=Path); parser.add_argument("output",type=Path)
    args=parser.parse_args()
    if args.output.exists(): raise ValueError("Output already exists")
    result=run(args.directory)
    with args.output.open("x") as stream: json.dump(result,stream,indent=2); stream.write("\n")
    print(json.dumps({k:v for k,v in result.items() if k not in ["groups","checked_inputs"]},indent=2))
