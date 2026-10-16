#!/usr/bin/env python3
"""Cut the border graph before fitting large connected land groups."""
import argparse
import csv
import json
import math
from pathlib import Path
import subprocess

import networkx as nx
from shapely import affinity, union_all
from shapely.geometry import mapping, shape

from independent_kontur_flow import select_patches
from review_flow import draw, read_shapes
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error


def separator(borders, start, end, policy, mean_limit=75., p90_limit=150.):
    if policy not in ('strict','relaxed') or not all(math.isfinite(v) and v>0 for v in [mean_limit,p90_limit]):
        raise ValueError('Use a known separator policy and positive finite density limits')
    graph = nx.Graph()
    for record in borders:
        eligible = record['eligible']
        if policy == 'relaxed':
            eligible |= (record.get('mean_density',math.inf)<=mean_limit and record.get('p90_segment_density',math.inf)<=p90_limit)
            eligible |= (record.get('length_km',math.inf)<=50 and record.get('corridor_population',math.inf)<=500000)
        graph.add_edge(record['a'],record['b'],capacity=max(1.,record.get('corridor_population',1e15)) if eligible else 1e15,record=record)
    graph = graph.subgraph(nx.node_connected_component(graph,start)).copy()
    cost,(left,right) = nx.minimum_cut(graph,start,end)
    cut = [graph[a][b]['record'] for a in sorted(left) for b in sorted(graph[a]) if b in right]
    return graph,cost,cut,[left,right]


def run(root,output,grid=512,split_india=False,mean_limit=75.,p90_limit=150.):
    if output.exists() or grid < 16:
        raise ValueError('Use a new output directory and a grid of at least 16')
    baseline = root/'kontur-patch-flow-200-floor'
    source_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    contacts_path = groups_path.with_name('geographic-contacts.csv')
    binary = (root/'vendor/cartogram-cpp/build/Release/cartogram').resolve()
    groups = {r['component_id']:r for r in read_csv(groups_path)}
    native = read_shapes(source_path)
    shared = read_shapes(baseline/'blend-0.9/components.geojson')
    audit = json.loads(audit_path.read_text())
    if any(audit['inputs'].get(str(p)) != digest(p) for p in [groups_path,contacts_path]):
        raise ValueError('Audit inputs differ')
    main = {code:max((c for c in native if c[:3]==code),key=lambda c:int(groups[c]['tiles'])) for code in ['RUS','CHN','IND']}
    graph,cost,cut,blocks = separator(audit['borders'],main['RUS'],main['CHN'],'relaxed',mean_limit,p90_limit)
    strict_cost = separator(audit['borders'],main['RUS'],main['CHN'],'strict')[1]
    if cost >= 1e15 or any(not b for b in blocks):
        raise ValueError('No permitted complete separator')
    if split_india:
        removed = {tuple(sorted((r['a'],r['b']))) for r in cut}
        remaining = [r for r in audit['borders'] if tuple(sorted((r['a'],r['b']))) not in removed]
        _,extra_cost,extra_cut,children = separator(remaining,main['CHN'],main['IND'],'relaxed',mean_limit,p90_limit)
        if extra_cost >= 1e15:
            raise ValueError('No permitted China-India separator')
        blocks = [b for b in blocks if main['CHN'] not in b]+children
        cut += extra_cut
        cost += extra_cost
    features = json.loads((baseline/'patches.geojson').read_text())['features']
    data = json.loads((baseline/'patch-data.json').read_text())
    target_path = baseline/'blend-0.9/areas.csv'
    targets = read_csv(target_path)
    for c in graph:
        select_patches(features,data,targets,c,int(groups[c]['tiles']),float(groups[c]['group_population']))
    output.mkdir(parents=True)
    paths = [source_path,groups_path,audit_path,contacts_path,binary,target_path,baseline/'patches.geojson',baseline/'patch-data.json',baseline/'blend-0.9/components.geojson']
    report = dict(grid=grid,split_india=split_india,mean_limit=mean_limit,p90_limit=p90_limit,strict_separator_possible=strict_cost<1e15,corridor_population_cost=cost,cuts=cut,cases=[],
                  inputs={str(p):digest(p) for p in paths},script_sha256=digest(Path(__file__)),
                  limits=['Research only. No tile fit or production export.',
                          f'The relaxed policy permits mean density at most {mean_limit:g} and segment p90 at most {p90_limit:g} people per square kilometre, or a border at most 50 km long with corridor population at most 500000.',
                          'This differs from the original density policy. No rejected edge is silently approved.',
                          'Fit connected land groups, not separate countries. All within-group borders remain in the common population flow.',
                          'Reuse exact saved Kontur patches and target rows. Normalize each block to its total tile-area budget.',
                          'This regional test includes the connected Russia-China land group. Other continents, islands, and lake insertion are absent.',
                          'Assembly uses rigid block translation only. Area floors can still affect tiny components.'])
    def save():
        (output/'experiment.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    scale = math.sqrt(sum(int(groups[c]['tiles']) for c in shared)/sum(g.area for g in shared.values()))
    for name,parts in [('control',[set(graph)]),('separator',blocks)]:
        case = dict(name=name,blocks=[],complete=False)
        report['cases'].append(case);save()
        fitted = []
        for i,part in enumerate(parts):
            folder = output/name/str(i)
            folder.mkdir(parents=True)
            patches = [f for f in features if f['properties']['component_id'] in part]
            labels = {f['properties']['patch_id'] for f in patches}
            rows = [r for r in targets if r['patch_id'] in labels]
            source = folder/'patches.geojson'
            source.write_text(json.dumps(dict(type='FeatureCollection',features=patches),separators=(',',':'))+'\n')
            areas = folder/'areas.csv'
            with areas.open('w',newline='') as stream:
                writer = csv.DictWriter(stream,fieldnames=['patch_id','tiles'],lineterminator='\n')
                writer.writeheader();writer.writerows(rows)
            command = [str(binary),str(source.resolve()),str(areas.resolve()),'--skip_projection','--id','patch_id','--area','tiles','--n_grid_rows_or_cols',str(grid),'--max_allowed_autoscale_grid_length','2048','--timeout','600','--export_preprocessed']
            entry = dict(components=sorted(part),command=command,population=sum(r['population'] for r in data if r['component_id'] in part),tiles=sum(float(r['tiles']) for r in rows),complete=False)
            case['blocks'].append(entry);save()
            with (folder/'solver.log').open('w') as log:
                process = subprocess.run(command,cwd=folder,stdout=log,stderr=subprocess.STDOUT,timeout=660)
            entry['exit_code'] = process.returncode;save()
            if process.returncode:
                raise ValueError('Block solver failed')
            result = json.loads((folder/'areas_cartogram.geojson').read_text())['features']
            by_id = {f['properties']['patch_id']:shape(f['geometry']) for f in result}
            if set(by_id) != labels or any(not g.is_valid for g in by_id.values()):
                raise ValueError('Invalid block patches')
            shapes = {c:union_all([by_id[f['properties']['patch_id']] for f in patches if f['properties']['component_id']==c]) for c in sorted(part)}
            if any(g.geom_type != 'Polygon' or not g.is_valid for g in shapes.values()):
                raise ValueError('Block flow breaks a country')
            total = sum(g.area for g in shapes.values())
            factor = math.sqrt(entry['tiles']/total)
            origin = union_all(list(shapes.values())).centroid
            anchor = union_all([shared[c] for c in part]).centroid
            shapes = {c:affinity.translate(affinity.scale(affinity.translate(g,-origin.x,-origin.y),factor,factor,origin=(0,0)),anchor.x*scale,anchor.y*scale) for c,g in shapes.items()}
            entry.update(complete=True,patch_relative_area_error=max(abs(by_id[r['patch_id']].area/total*entry['tiles']/float(r['tiles'])-1) for r in rows))
            fitted.append(shapes);save()
        if len(fitted)>1:
            placed = []
            case['translations'] = []
            for i in sorted(range(len(fitted)),key=lambda i:-sum(g.area for g in fitted[i].values())):
                block = union_all(list(fitted[i].values()))
                if placed:
                    occupied = union_all(placed)
                    dx,dy = block.centroid.x-occupied.centroid.x,block.centroid.y-occupied.centroid.y
                    length = math.hypot(dx,dy)
                    if length==0:
                        raise ValueError('Block centres give no placement direction')
                    dx,dy = dx/length,dy/length
                    for distance in range(401):
                        moved = affinity.translate(block,dx*distance,dy*distance)
                        if moved.distance(occupied)>=2:
                            break
                    else:
                        raise ValueError('No non-overlapping block placement on the centre-order ray')
                    fitted[i] = {c:affinity.translate(g,dx*distance,dy*distance) for c,g in fitted[i].items()}
                    case['translations'].append(dict(block=i,shift=[dx*distance,dy*distance]))
                    block = moved
                placed.append(block)
        shapes = {c:g for block in fitted for c,g in block.items()}
        retained = [(a,b) for a,b in graph.edges if not any({r['a'],r['b']}=={a,b} for r in cut)] if len(parts)>1 else list(graph.edges)
        missing = [(a,b) for a,b in retained if shapes[a].boundary.intersection(shapes[b].boundary).length<=1e-8]
        case.update(complete=True,retained_contacts=len(retained),missing_contacts=missing,
                    overlap=sum(g.area for g in shapes.values())-union_all(list(shapes.values())).area,
                    records=[dict(component=c,country=c[:3],shape_error=outline_error(g,native[c]),area_error=g.area/int(groups[c]['tiles'])-1) for c,g in shapes.items()])
        folder = output/name
        geometry = folder/'components.geojson'
        geometry.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in shapes.items()]),separators=(',',':'))+'\n')
        case['geometry_sha256'] = digest(geometry)
        draw(folder/'review.svg',shapes,groups,'Population flow after graph separation: '+name,
             f'{len(parts)} flow domains. Retained contacts: {len(retained)-len(missing)}/{len(retained)}. Regional diagnostic only.',
             method='Original Kontur patches; independent connected-group flow; rigid block translation.')
        subprocess.run(['rsvg-convert',str(folder/'review.svg'),'-o',str(folder/'review.png')],check=True)
        save();print(json.dumps(case),flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--grid',type=int,default=512)
    parser.add_argument('--split-india',action='store_true')
    parser.add_argument('--mean-limit',type=float,default=75.)
    parser.add_argument('--p90-limit',type=float,default=150.)
    run(**vars(parser.parse_args()))
