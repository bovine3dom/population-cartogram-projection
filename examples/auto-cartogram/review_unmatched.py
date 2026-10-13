#!/usr/bin/env python3
"""Summarize unmatched centres by nearest source polygon, without assigning population."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.ipc as ipc
import shapely
from shapely.geometry import shape


def run(centres, components, output):
    if output.exists():
        raise ValueError("Output already exists")
    features=json.loads((centres/"polygons.geojson").read_text())["features"]
    records=[f for f in features if shape(f["geometry"]).bounds[2]-shape(f["geometry"]).bounds[0] <= 180]
    polygons=np.array([shape(f["geometry"]) for f in records],dtype=object)
    tree=shapely.STRtree(polygons)
    source=ipc.open_file(pa.memory_map(str(components/"unmatched.arrow"))).read_all()
    x=source["longitude"].combine_chunks().to_numpy()
    y=source["latitude"].combine_chunks().to_numpy()
    value=source["value"].combine_chunks().to_numpy()
    points=shapely.points(x,y)
    nearest=tree.nearest(points)
    distance=shapely.distance(points,polygons[nearest])
    # Angular distance is a diagnostic only, not kilometres or ownership.
    totals={}
    for i,v,d in zip(nearest,value,distance):
        country=records[int(i)]["properties"]["country_id"]
        row=totals.setdefault(country,{"country_id":country,"cells":0,"population":0,"within_0_01_degree":0})
        row["cells"]+=1; row["population"]+=float(v)
        if d <= .01:
            row["within_0_01_degree"]+=float(v)
    output.mkdir(parents=True)
    with (output/"nearest-country.csv").open("w") as stream:
        writer=csv.DictWriter(stream,fieldnames=["country_id","cells","population","within_0_01_degree"])
        writer.writeheader(); writer.writerows(sorted(totals.values(),key=lambda r:-r["population"]))
    summary={"unmatched_population":float(value.sum()),"unmatched_cells":len(value),
             "within_0_01_degree_population":float(value[distance<=.01].sum()),
             "beyond_0_1_degree_population":float(value[distance>.1].sum()),
             "limit":"Nearest polygon is not ownership. Angular distances are not uniform physical distances."}
    (output/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps(summary,indent=2))
    return summary


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("centres",type=Path)
    parser.add_argument("components",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    run(args.centres,args.components,args.output)
