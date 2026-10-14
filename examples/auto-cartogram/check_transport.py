#!/usr/bin/env python3
"""Independently check exported transport weights, groups, and target totals."""
import argparse
import collections
import csv
import hashlib
import json
import math
from pathlib import Path

from save_review import digest


def rows(path):
    with path.open(newline="") as stream:
        yield from csv.DictReader(stream)


def close(actual, expected):
    if not math.isfinite(actual) or not math.isclose(actual,expected,rel_tol=1e-9,abs_tol=1e-7):
        raise ValueError(f"Totals differ: {actual} != {expected}")


def check(directory):
    metadata=json.loads((directory/"manifest.json").read_text())
    sources={}; group_mass=collections.defaultdict(float)
    for r in rows(directory/"sources.csv"):
        value=float(r["value"])
        if r["id"] in sources or not math.isfinite(value) or value <= 0:
            raise ValueError("Duplicate source or invalid population")
        sources[r["id"]]=(r["group_id"],value)
        group_mass[r["group_id"]]+=value
    targets={}; group_count=collections.Counter()
    for r in rows(directory/"targets.csv"):
        p=(float(r["x"]),float(r["y"]))
        if p in targets or not all(map(math.isfinite,p)):
            raise ValueError("Duplicate or invalid target")
        targets[p]=r["group_id"]; group_count[r["group_id"]]+=1
    if not sources or not targets or set(group_count) != set(group_mass):
        raise ValueError("Missing source or target groups")
    weights=dict.fromkeys(sources,0.0); totals=dict.fromkeys(targets,0.0)
    pairs=set(); crossing=0.0
    for r in rows(directory/"mapping.csv"):
        source=r["id"]; p=(float(r["x"]),float(r["y"])); weight=float(r["weight"])
        if source not in sources or p not in targets or (source,p) in pairs:
            raise ValueError("Unknown or duplicate mapping pair")
        if not math.isfinite(weight) or weight <= 0 or weight > 1+1e-12:
            raise ValueError("Invalid mapping weight")
        pairs.add((source,p)); weights[source]+=weight
        group,value=sources[source]; mass=value*weight
        totals[p]+=mass
        if group != targets[p]: crossing+=mass
    if min(weights.values()) <= 0 or max(weights.values()) > 1+1e-9 or min(totals.values()) <= 0:
        raise ValueError("Missing contribution or excess source weight")
    if not metadata["pooled"] and crossing != 0:
        raise ValueError("Grouped transport crosses group boundaries")
    population=math.fsum(group_mass.values()); retained=math.fsum(totals.values())
    expected={p:population/len(targets) if metadata["pooled"] else group_mass[g]/group_count[g] for p,g in targets.items()}
    errors={p:totals[p]/expected[p]-1 for p in targets}
    seen=set()
    for r in rows(directory/"target-quality.csv"):
        p=(float(r["x"]),float(r["y"]))
        if p not in targets or p in seen or r["group_id"] != targets[p]:
            raise ValueError("Invalid target quality row")
        seen.add(p)
        for key,value in [("population",totals[p]),("expected_population",expected[p]),("relative_error",errors[p])]:
            close(float(r[key]),value)
    if seen != set(targets): raise ValueError("Missing target quality rows")
    mean_rows=0
    for r in rows(directory/"mapping.csv"):
        if "weight_mean" not in r: continue
        value=float(r["weight_mean"])
        if not math.isfinite(value) or not 0 < value <= 1+1e-12:
            raise ValueError("Invalid target-normalized weight")
        p=(float(r["x"]),float(r["y"]))
        expected_mean=sources[r["id"]][1]*float(r["weight"])/totals[p]
        if not math.isclose(value,expected_mean,rel_tol=1e-9,abs_tol=1e-14):
            raise ValueError("Target-normalized weight differs from its population share")
        mean_rows+=1
    result=dict(source_population=population,retained_population=retained,retained_share=retained/population,
        cross_group_population=crossing,minimum_source_retained_share=min(weights.values()),
        maximum_source_retained_share=max(weights.values()),maximum_relative_target_error=max(map(abs,errors.values())),
        coarse_sources=len(sources),targets=len(targets),groups=len(group_mass))
    for key,value in result.items(): close(value,metadata[key])
    result.update(mapping_rows=len(pairs),target_normalized_weights_checked=mean_rows,
        source_rows_below_99_5_percent=sum(w < .995-1e-12 for w in weights.values()),
        checked=True,checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    result["files"]={p.name:digest(p) for p in
        [directory/name for name in ["manifest.json","sources.csv","targets.csv","mapping.csv","target-quality.csv"]]}
    return result


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    result=check(args.directory)
    with args.output.open("x") as stream: json.dump(result,stream,indent=2); stream.write("\n")
