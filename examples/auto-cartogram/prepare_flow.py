#!/usr/bin/env python3
"""Prepare separate population components for continuous geographic deformation."""
import argparse
import csv
import json
import shutil
import tempfile
from pathlib import Path

import numpy as np
from shapely import transform
from shapely.geometry import shape, mapping

from review_layout import read_csv
from save_review import digest


def equal_earth(points):
    lon,lat=np.deg2rad(points).T
    theta=np.arcsin(np.sqrt(3)/2*np.sin(lat))
    a,b,c,d=1.340264,-.081106,.000893,.003796
    x=2*np.sqrt(3)*lon*np.cos(theta)/(3*(a+3*b*theta**2+theta**6*(7*c+9*d*theta**2)))
    y=theta*(a+b*theta**2+theta**6*(c+d*theta**2))
    return np.column_stack((x,y))*1000


def run(inputs, polygons, output):
    if output.exists(): raise ValueError('Output already exists')
    groups={r['component_id']:r for r in read_csv(inputs/'groups.csv') if int(r['tiles'])>0}
    features=[]; summary=[]
    for feature in json.loads(polygons.read_text())['features']:
        component=feature['properties']['component_id']
        if component not in groups:continue
        row=groups[component]; original=shape(feature['geometry']); geometry=transform(original,equal_earth)
        if not geometry.is_valid or geometry.is_empty or geometry.geom_type!='Polygon' or geometry.area<=0:
            raise ValueError(f'Invalid projected component: {component}')
        properties=dict(component_id=component,country_id=row['country_id'],name=row['name'])
        features.append(dict(type='Feature',properties=properties,geometry=mapping(geometry)))
        summary.append(dict(component_id=component,tiles=int(row['tiles']),source_area=geometry.area,holes=len(geometry.interiors)))
    if {r['component_id'] for r in summary}!=set(groups) or len(summary)!=len(groups):
        raise ValueError('Missing or duplicate represented components')
    features.sort(key=lambda f:f['properties']['component_id']);summary.sort(key=lambda r:r['component_id'])
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix='flow-input-',dir=output.parent))
    try:
        (temp/'geometry.geojson').write_text(json.dumps(dict(type='FeatureCollection',features=features),separators=(',',':'))+'\n')
        with (temp/'areas.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','tiles'])
            writer.writerows((r['component_id'],r['tiles']) for r in summary)
        with (temp/'components.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(summary[0]));writer.writeheader();writer.writerows(summary)
        metadata=dict(method='Equal Earth projection of individual represented components; target areas are requested tile counts',
            components=len(summary),tiles=sum(r['tiles'] for r in summary),holes=sum(r['holes'] for r in summary),
            projection='Equal Earth, EPSG method 1078; arbitrary Cartesian scale 1000. Pass --skip_projection to cartogram-cpp.',
            component_rule='No country-level union of islands. Zero-budget population uses the existing group table; no new geometry joins.',
            inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'manifest.json',polygons]},script_sha256=digest(Path(__file__)))
        (temp/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return metadata


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','polygons','output']:parser.add_argument(name,type=Path)
    args=parser.parse_args();print(json.dumps(run(args.inputs,args.polygons,args.output),indent=2))
