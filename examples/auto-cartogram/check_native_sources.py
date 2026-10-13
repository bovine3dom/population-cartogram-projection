#!/usr/bin/env python3
"""Check native transport source IDs, population, and group labels against inputs."""
import argparse
import hashlib
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.ipc as ipc

from check_transport import rows
from save_review import digest


def check(source_path, groups_path, transport):
    metadata=json.loads((transport/"manifest.json").read_text())
    if metadata["coarse_h3_resolution"] != 8:
        raise ValueError("Expected native H3-8 transport")
    recorded={r["sha256"] for r in metadata["inputs"]}
    hashes={str(p):digest(p) for p in [source_path,groups_path,transport/"sources.csv"]}
    if hashes[str(source_path)] not in recorded or hashes[str(groups_path)] not in recorded:
        raise ValueError("Native source or grouping input differs from recorded inputs")
    groups={}
    for r in rows(groups_path):
        suffix=r["component_id"].split(":")[-1]
        if suffix in groups: raise ValueError("Duplicate component hash")
        groups[suffix]=(r["component_id"],r["group_id"])
    native=ipc.open_file(pa.memory_map(str(source_path))).read_all()
    expected={}
    for source,value,component in zip(native["id"].to_pylist(),native["value"].to_pylist(),native["component_id"].to_pylist()):
        if source in expected: raise ValueError("Duplicate native source")
        expected[source]=(value,*groups[component.split(":")[-1]])
    count=0; population=0.0
    for r in rows(transport/"sources.csv"):
        component,source=r["id"].rsplit(":",1)
        actual=(float(r["value"]),r["component_id"],r["group_id"])
        if component != r["component_id"] or expected.pop(int(source),None) != actual:
            raise ValueError("Unknown, duplicate, or changed native source")
        count+=1; population+=actual[0]
    if expected: raise ValueError("Native source cells are missing")
    if count != metadata["coarse_sources"] or population != metadata["source_population"]:
        raise ValueError("Native source summary differs")
    return dict(checked=True,native_sources=count,population=population,
        check="Every native ID occurs once with unchanged population and the declared component/group labels",
        limit="This check does not assess projected coordinates or spatial transport quality",
        files=hashes,checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["source","groups","transport","output"]: parser.add_argument(name,type=Path)
    args=parser.parse_args()
    result=check(args.source,args.groups,args.transport)
    with args.output.open("x") as stream: json.dump(result,stream,indent=2); stream.write("\n")
