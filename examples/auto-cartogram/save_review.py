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


def run(inputs, layout, output):
    if output.exists():
        raise ValueError("Review output already exists")
    if not (layout/"complete.txt").exists():
        raise ValueError("Layout is incomplete")
    names=["review.png","metrics.json","region-quality.csv","country-counts.csv","contact-errors.csv",
           "island-order-errors.csv","complete.txt"]
    for name in names:
        if not (layout/name).exists():
            raise ValueError(f"Missing review file: {name}")
    output.mkdir(parents=True)
    for name in names:
        shutil.copyfile(layout/name,output/name)
    for name in ["manifest.json","groups.csv","outline-checks.json","embedding.json","embedding.tsv","embedding-edges.tsv"]:
        if (inputs/name).exists():
            shutil.copyfile(inputs/name,output/("input-"+name))
    if (layout/"baseline.json").exists():
        shutil.copyfile(layout/"baseline.json",output/"baseline.json")
    hashes={str(p):digest(p) for directory in [inputs,layout] for p in sorted(directory.iterdir()) if p.is_file()}
    (output/"checksums.json").write_text(json.dumps(hashes,indent=2)+"\n")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["inputs","layout","output"]:
        parser.add_argument(name,type=Path)
    args=parser.parse_args()
    run(args.inputs,args.layout,args.output)
