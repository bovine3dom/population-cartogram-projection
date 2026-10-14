#!/usr/bin/env python3
"""Measure population-weighted component sites from matched native sources."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile

import numpy as np

from prepare_flow import equal_earth
from review_layout import read_csv
from save_review import digest


def read_sites(path,labels):
    rows=read_csv(path);sites={r['component_id']:(float(r['x']),float(r['y'])) for r in rows}
    if len(sites)!=len(rows) or set(sites)!=set(labels):raise ValueError('Site labels differ or repeat')
    if any(not np.isfinite(point).all() for point in sites.values()):raise ValueError('Invalid site coordinates')
    return sites


def spherical_sites(longitude,latitude,weights,labels,count):
    longitude,latitude,weights=[np.asarray(v,dtype=float) for v in [longitude,latitude,weights]];labels=np.asarray(labels)
    if not (len(longitude)==len(latitude)==len(weights)==len(labels)):raise ValueError('Array lengths differ')
    if not isinstance(count,int) or count<1 or labels.dtype.kind not in 'iu' or np.any(labels<0) or np.any(labels>=count):raise ValueError('Invalid group indices')
    if any(not np.isfinite(v).all() for v in [longitude,latitude,weights]) or np.any(weights<=0):raise ValueError('Invalid coordinates or weights')
    if np.any(np.abs(latitude)>90) or np.any(np.abs(longitude)>180):raise ValueError('Invalid geographic coordinates')
    lon=np.deg2rad(longitude);lat=np.deg2rad(latitude)
    mass=np.bincount(labels,weights=weights,minlength=count)
    x=np.bincount(labels,weights=weights*np.cos(lat)*np.cos(lon),minlength=count)
    y=np.bincount(labels,weights=weights*np.cos(lat)*np.sin(lon),minlength=count)
    z=np.bincount(labels,weights=weights*np.sin(lat),minlength=count)
    if np.any(mass<=0) or np.any(np.sqrt(x*x+y*y+z*z)<1e-12*mass):raise ValueError('Undefined population site')
    return mass,np.column_stack((np.rad2deg(np.arctan2(y,x)),np.rad2deg(np.arctan2(z,np.hypot(x,y)))))


def run(inputs,sources,centres,output):
    import pyarrow as pa
    import pyarrow.compute as pc
    if output.exists():raise ValueError('Output already exists')
    hashes={str(p):digest(p) for p in [inputs/'groups.csv',sources,centres]}
    scripts={name:digest(Path(__file__).with_name(name)) for name in ['population_sites.py','prepare_flow.py']}
    rows=read_csv(inputs/'groups.csv');groups={r['component_id']:r for r in rows if int(r['tiles'])>0}
    labels=sorted(groups);index={c:i for i,c in enumerate(labels)}
    mapping={r['component_id']:r['group_id'] for r in rows}
    with pa.memory_map(str(sources),'r') as a,pa.memory_map(str(centres),'r') as b:
        source=pa.ipc.open_file(a).read_all();points=pa.ipc.open_file(b).read_all()
        if pc.count_distinct(points['id']).as_py()!=len(points):raise ValueError('Duplicate centre IDs')
        if pc.count_distinct(source['id']).as_py()!=len(source):raise ValueError('Duplicate source IDs')
        positions=pc.index_in(source['id'],value_set=points['id'])
        if positions.null_count:raise ValueError('Missing source centre')
        weights=source['value'].to_numpy()
        if not np.array_equal(weights,pc.take(points['value'],positions).to_numpy()):raise ValueError('Source values differ')
        codes=pc.dictionary_encode(source['component_id']).combine_chunks()
        if codes.null_count:raise ValueError('Missing source group')
        codes_index=codes.indices.to_numpy();used=np.bincount(codes_index,minlength=len(codes.dictionary))
        try:destinations=np.array([index[mapping[c]] if used[i] else 0 for i,c in enumerate(codes.dictionary.to_pylist())])
        except KeyError as error:raise ValueError('Source group is not represented') from error
        ids=destinations[codes_index]
        longitude=pc.take(points['longitude'],positions).to_numpy();latitude=pc.take(points['latitude'],positions).to_numpy()
        mass,sites=spherical_sites(longitude,latitude,weights,ids,len(labels))
        expected=np.array([float(groups[c]['group_population']) for c in labels])
        if not np.allclose(mass,expected,rtol=0,atol=1e-6):raise ValueError('Group populations differ')
        source_cells=len(source)
    xy=equal_earth(sites)/1000
    records=[dict(component_id=c,population=float(mass[i]),longitude=float(sites[i,0]),latitude=float(sites[i,1]),x=float(xy[i,0]),y=float(xy[i,1])) for i,c in enumerate(labels)]
    report=dict(method='Population-weighted spherical mean of native H3 centres, then Equal Earth projection with radius 1',source_cells=source_cells,population=float(mass.sum()),components=len(labels),inputs=hashes,scripts=scripts,pyarrow_version=pa.__version__,limit='Sites, not a layout. Each native H3 cell places its population at its centre. Existing population groups are unchanged. A group site need not lie inside its outline. Source year remains unspecified.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='population-sites-',dir=output.parent))
    try:
        with (temp/'sites.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(records[0]));writer.writeheader();writer.writerows(records)
        report['sites_sha256']=digest(temp/'sites.csv')
        (temp/'sites.json').write_text(json.dumps(report,indent=2)+'\n');temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','sources','centres','output']:parser.add_argument(name,type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
