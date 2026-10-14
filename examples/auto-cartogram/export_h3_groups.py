#!/usr/bin/env python3
"""Export checked island transport and component-matched cities for H3-MON."""
import argparse
from collections import defaultdict
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile

import pyarrow as pa
from shapely import Point, STRtree
from shapely.geometry import shape

from check_transport import check, close, rows
from save_review import digest


def arrow(path, columns, types):
    table=pa.table({key:pa.array(value,type=types[key]) for key,value in columns.items()})
    with pa.OSFile(str(path),'wb') as stream:
        with pa.ipc.new_file(stream,table.schema) as writer:writer.write_table(table)


def csv_file(path, records):
    if not records:return
    with path.open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(records[0]));writer.writeheader();writer.writerows(records)


def export(directory, polygons_path, iso_path, output):
    if output.exists():raise ValueError('Output already exists')
    if not (directory/'balance-complete.json').exists():raise ValueError('Balance is not complete')
    groups={r['component_id']:r for r in rows(directory/'groups.csv')}
    if any(r['group_id'] not in groups or groups[r['group_id']]['country_id']!=r['country_id'] for r in groups.values()):raise ValueError('Island grouping crosses countries')
    sources={r['id']:r for r in rows(directory/'sources.csv')}
    targets={(int(r['x']),int(r['y'])):r['group_id'] for r in rows(directory/'targets.csv')}
    parents=defaultdict(float)
    for key,r in sources.items():parents[int(key.rsplit(':',1)[1])]+=float(r['value'])
    masses=defaultdict(float);totals=defaultdict(float);best={};audits=[];seen_sources=set();seen_targets=set()
    for group in sorted(set(targets.values())):
        shard=directory/'balanced'/group
        audit=check(shard)
        if audit['cross_group_population'] or audit['maximum_relative_target_error']>1e-4 or abs(audit['minimum_source_retained_share']-1)>1e-9:raise ValueError('Unbalanced shard')
        audit['group_id']=group;audits.append(audit)
        for r in rows(shard/'sources.csv'):
            key=r['id']
            if key in seen_sources or key not in sources or r['group_id']!=group or sources[key]['group_id']!=group:raise ValueError('Source shard mismatch')
            close(float(r['value']),float(sources[key]['value']));seen_sources.add(key)
        for r in rows(shard/'targets.csv'):
            p=int(r['x']),int(r['y'])
            if p in seen_targets or targets.get(p)!=group or r['group_id']!=group:raise ValueError('Target shard mismatch')
            seen_targets.add(p)
        for r in rows(shard/'mapping.csv'):
            key=r['id'];p=int(r['x']),int(r['y']);mass=float(r['weight'])*float(sources[key]['value'])
            parent=int(key.rsplit(':',1)[1]);masses[parent,*p]+=mass;totals[p]+=mass
            if key not in best or mass>best[key][0]:best[key]=(mass,p)
    if seen_sources!=set(sources) or seen_targets!=set(targets):raise ValueError('Incomplete transport')
    # Match a city to a polygon before selecting a transport row. H3 parents alone
    # cannot identify islands: one parent can intersect several components.
    features=json.loads(polygons_path.read_text())['features']
    features=[f for f in features if f['properties']['component_id'] in groups]
    geometries=[shape(f['geometry']) for f in features];tree=STRtree(geometries)
    labels=defaultdict(list);city_audit=[]
    for city in rows(directory/'labels/cities.csv'):
        point=Point(float(city['longitude']),float(city['latitude']))
        hits=[int(i) for i in tree.query(point,predicate='intersects')]
        component=features[hits[0]]['properties']['component_id'] if len(hits)==1 else ''
        key=f"{component}:{city['h3']}";group=groups[component]['group_id'] if component else ''
        reason='placed' if key in best else 'no_component_source' if component else 'ambiguous_polygon' if hits else 'outside_polygons'
        position=best[key][1] if reason=='placed' else None
        row=dict(city,component_id=component,group_id=group,grouped=groups[component]['grouped'] if component else '',x=2*position[0] if position else '',y=-2*position[1] if position else '',status=reason)
        city_audit.append(row)
        if position:labels[position].append((int(city['population']),city['name'],int(city['h3'])))
    winners={p:max(cities) for p,cities in labels.items()}
    for city in city_audit:
        p=(int(city['x'])//2,-int(city['y'])//2) if city['status']=='placed' else None
        city['displayed']=p in winners and winners[p]==(int(city['population']),city['name'],int(city['h3']))
    iso=json.loads(iso_path.read_text())['3166-1']
    codes={r['alpha_3']:int(r['numeric']) for r in iso}
    countries=sorted({r['country_id'] for r in groups.values()})
    # Special Natural Earth regions retain distinct categorical border codes.
    special={country:1000+i for i,country in enumerate(c for c in countries if c not in codes)}
    codes.update(special)
    data={k:[] for k in ['index_lower','index_upper','x','y','weight','weight_mean','population','code','label','prominence']}
    retained=defaultdict(float);means=defaultdict(float)
    for (parent,x,y),mass in sorted(masses.items()):
        city=winners.get((x,y))
        labelled=city is not None and city[2]==parent
        values=[parent&0xffffffff,parent>>32,2*x,-2*y,mass/parents[parent],mass/totals[x,y],parents[parent],codes[groups[targets[x,y]]['country_id']],city[1] if labelled else None,city[0] if labelled else None]
        for key,value in zip(data,values):data[key].append(value)
        retained[parent]+=values[4];means[x,y]+=values[5]
    for value in [*retained.values(),*means.values()]:close(value,1.)
    areas={int(r['h3']):float(r['area_km2']) for r in rows(directory/'labels/areas.csv')}
    if set(areas)!=set(parents) or any(not math.isfinite(a) or a<=0 for a in areas.values()):raise ValueError('Invalid H3 areas')
    density={'index_lower':[],'index_upper':[],'value':[]}
    for parent,population in sorted(parents.items()):
        density['index_lower'].append(parent&0xffffffff);density['index_upper'].append(parent>>32);density['value'].append(population/areas[parent])
    output.parent.mkdir(parents=True,exist_ok=True)
    temp=Path(tempfile.mkdtemp(prefix=output.name+'-',dir=output.parent))
    try:
        types={k:pa.float64() for k in data}
        types.update(index_lower=pa.uint32(),index_upper=pa.uint32(),x=pa.int32(),y=pa.int32(),code=pa.int32(),label=pa.string())
        mapping_name='cartogram_weights_auto_55000_h3_5_hilo.arrow'
        arrow(temp/mapping_name,data,types)
        arrow(temp/'population_density_hilo.arrow',density,dict(index_lower=pa.uint32(),index_upper=pa.uint32(),value=pa.float64()))
        metadata=dict(t='Population density — automatic 55,000-tile island cartogram',c='Kontur population; Natural Earth components; GeoNames cities. Experimental layout. Source population year not verified.',cartogram=f'{output.name}/{mapping_name}',colourScheme='interpolateViridis',colourScale='quantile',quantileSource='cartogram')
        (temp/'population_density_hilo.json').write_text(json.dumps(metadata,indent=2)+'\n')
        csv_file(temp/'cities.csv',city_audit)
        csv_file(temp/'country-codes.csv',[dict(country_id=c,code=codes[c],kind='special categorical code' if c in special else 'ISO 3166-1 numeric') for c in countries])
        shutil.copyfile(directory/'groups.csv',temp/'groups.csv')
        inputs=[directory/'sources.csv',directory/'targets.csv',directory/'groups.csv',directory/'labels/cities.csv',directory/'labels/areas.csv',polygons_path,iso_path,Path(__file__)]
        report=dict(tiles=len(targets),groups=len(audits),component_h3_sources=len(sources),h3_parents=len(parents),mapping_rows=len(masses),population=math.fsum(parents.values()),cross_group_population=0,maximum_relative_target_error=max(a['maximum_relative_target_error'] for a in audits),cities=len(city_audit),placed_cities=sum(r['status']=='placed' for r in city_audit),labelled_tiles=len(winners),grouped_population=sum(float(r['population']) for r in groups.values() if r['component_id']!=r['group_id']),inputs={str(p):digest(p) for p in inputs},shards=audits)
        report['files']={p.name:digest(p) for p in temp.iterdir()}
        (temp/'export-checks.json').write_text(json.dumps(report,indent=2)+'\n')
        (temp/'README.md').write_text('''# Population density: automatic island cartogram

This is an experimental 55,000-tile layout. It is not the production map.

Transport uses component/H3-5 fragments. Each fragment stays in its recorded
island group. Small islands with no tile use the group in `groups.csv`.
`export-checks.json` records their population and all shard checks.

The density value is matched population divided by the actual H3-5 cell area
in square kilometres. A parent cell can cross a coast or a border. Its density
is shared by its fragments, but transport does not cross their group boundary.
Excluded source population is not added to the map. The population year is not
verified. Do not use these values as a current census.

`weight` is the fraction of parent population sent to a tile. `weight_mean`
is the fraction of tile population from that parent. Use `weight_mean` to
average density. Tile populations are equal within each group, not worldwide.

City labels use GeoNames places with more than 50,000 people. A city point must
intersect one source component and have a component/H3 source row. Its label
goes to the tile with the largest contribution from that row. If several cities
share a tile, only the city with the largest population has a display label.
All candidates remain in the city audit. There is no country-wide label fallback. `cities.csv` includes unmatched places and reasons.
Coordinates use screen y (positive down) and a two-unit tile step for H3-MON.
The export applies x = 2 * layout_x and y = -2 * layout_y.

Special Natural Earth regions have distinct border codes of 1000 or more.
These codes are not ISO codes. See `country-codes.csv`.
''')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return {k:v for k,v in report.items() if k not in ['inputs','shards','files']}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['directory','polygons','iso','output']:parser.add_argument(name,type=Path)
    args=parser.parse_args();print(json.dumps(export(args.directory,args.polygons,args.iso,args.output),indent=2))
