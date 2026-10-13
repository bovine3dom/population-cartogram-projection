#!/usr/bin/env python3
"""Copy small review files and record hashes of the complete experiment inputs."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream,"sha256").hexdigest()


def run(inputs, layout, output, refresh=False):
    if output.exists():
        if not refresh:
            raise ValueError("Review output already exists")
        previous=json.loads((output/"checksums.json").read_text())
        cells=[value for path,value in previous.items() if Path(path).name == "cells.csv"]
        if cells != [digest(layout/"cells.csv")] or (output/"input-manifest.json").read_bytes() != (inputs/"manifest.json").read_bytes():
            raise ValueError("Refresh cannot replace the layout or its input manifest")
    if not (layout/"complete.txt").exists():
        raise ValueError("Layout is incomplete")
    names=["review.png","metrics.json","region-quality.csv","country-counts.csv","contact-errors.csv",
           "island-order-errors.csv","country-order-errors.csv","group-capacities.csv","complete.txt"]
    for name in names:
        if not (layout/name).exists():
            raise ValueError(f"Missing review file: {name}")
    output.mkdir(parents=True,exist_ok=refresh)
    for name in names:
        shutil.copyfile(layout/name,output/name)
    input_names=["manifest.json","groups.csv","outline-checks.json"]
    if "embedding=planar" in (layout/"complete.txt").read_text().splitlines():
        input_names += ["embedding.json","embedding.tsv","embedding-edges.tsv","geographic-rotation.json"]
    for name in input_names:
        if (inputs/name).exists():
            shutil.copyfile(inputs/name,output/("input-"+name))
    for name in ["baseline.json","repair.json","attempts.csv","build-info.properties"]:
        if (layout/name).exists():
            shutil.copyfile(layout/name,output/name)
    hashes={str(p):digest(p) for directory in [inputs,layout] for p in sorted(directory.iterdir()) if p.is_file()}
    (output/"checksums.json").write_text(json.dumps(hashes,indent=2)+"\n")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["inputs","layout","output"]:
        parser.add_argument(name,type=Path)
    parser.add_argument("--refresh",action="store_true",help="Update derived checks only; cells and input manifest must match")
    args=parser.parse_args()
    run(args.inputs,args.layout,args.output,args.refresh)
