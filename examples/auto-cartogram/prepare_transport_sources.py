#!/usr/bin/env python3
"""Keep native source IDs and population; apply the checked country-component union."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.ipc as ipc

from assign_population import file_hash


def run(membership, components, crosswalk, output):
    if output.exists():
        raise ValueError("Output already exists")
    with components.open() as stream:
        original=list(csv.DictReader(stream))
    labels=[r["component_id"] for r in original]
    if len(set(labels))!=len(labels):
        raise ValueError("Duplicate original component")
    with crosswalk.open() as stream:
        rows=list(csv.DictReader(stream))
    links={r["original_component_id"]:r for r in rows}
    if len(links)!=len(rows) or set(links)!=set(labels):
        raise ValueError("Crosswalk must name every original component once")
    countries={}
    for r in original:
        link=links[r["component_id"]]
        destination=link["component_id"]
        if link["country_id"]!=r["country_id"] or countries.setdefault(destination,r["country_id"])!=r["country_id"]:
            raise ValueError("Crosswalk merges different countries")
    destinations=sorted(countries)
    indices={label:i for i,label in enumerate(destinations)}
    destination_index=np.array([indices[links[label]["component_id"]] for label in labels],dtype=np.int32)
    table=ipc.open_file(pa.memory_map(str(membership))).read_all()
    if table["id"].type!=pa.uint64():
        raise ValueError("Expected UInt64 source IDs")
    if pc.count_distinct(table["id"]).as_py()!=len(table):
        raise ValueError("Duplicate or null source ID")
    owners=table["component_index"].combine_chunks().to_numpy()
    values=table["value"].combine_chunks().to_numpy()
    if owners.dtype.kind not in "iu" or np.any(owners < -1) or np.any(owners > len(original)):
        raise ValueError("Invalid component index")
    if not np.all(np.isfinite(values) & (values>0)):
        raise ValueError("Invalid source population")
    matched=owners>0
    positions=owners[matched]-1
    counts=np.bincount(positions,minlength=len(original))
    masses=np.bincount(positions,weights=values[matched],minlength=len(original))
    if any(counts[i]!=int(r["source_cells"]) or not np.isclose(masses[i],float(r["population"]),rtol=1e-12,atol=0)
           for i,r in enumerate(original)):
        raise ValueError("Membership differs from component counts or population")
    selected=table.filter(pa.array(matched))
    result=pa.table({"id":selected["id"],"value":selected["value"],
        "component_id":pa.DictionaryArray.from_arrays(pa.array(destination_index[positions]),pa.array(destinations)),
        "original_component_id":pa.DictionaryArray.from_arrays(pa.array(positions),pa.array(labels))})
    metadata={"source_cells":len(result),"source_population":float(values[matched].sum()),
        "unmatched_cells":int(np.sum(owners==0)),"unmatched_population":float(values[owners==0].sum()),
        "ambiguous_cells":int(np.sum(owners==-1)),"ambiguous_population":float(values[owners==-1].sum()),
        "policy":"Keep matched native IDs and values unchanged. Change component labels through the explicit same-country crosswalk. Keep original labels in a separate column.",
        "inputs":[{"path":str(p.resolve()),"sha256":file_hash(p)} for p in (membership,components,crosswalk,Path(__file__))]}
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix="transport-sources-",dir=output.parent))
    try:
        with ipc.new_file(str(temp/"sources.arrow"),result.schema) as writer:
            writer.write_table(result)
        metadata["sources_sha256"]=file_hash(temp/"sources.arrow")
        (temp/"manifest.json").write_text(json.dumps(metadata,indent=2)+"\n")
        temp.rename(output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    print(json.dumps(metadata,indent=2))
    return metadata


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("membership","components","crosswalk","output"):
        parser.add_argument(name,type=Path)
    args=parser.parse_args()
    run(args.membership,args.components,args.crosswalk,args.output)
