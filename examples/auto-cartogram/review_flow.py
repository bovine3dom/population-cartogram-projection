#!/usr/bin/env python3
"""Check continuous component geometry and draw a headless review image."""
import argparse
import csv
import html
import json
import math
from pathlib import Path

from shapely import STRtree
from shapely.geometry import shape

from review_layout import read_csv, country_color
from save_review import digest


def read_shapes(path):
    result={}
    for f in json.loads(path.read_text())['features']:
        component=f['properties']['component_id']
        if component in result:raise ValueError('Duplicate component')
        geometry=shape(f['geometry'])
        if geometry.geom_type=='MultiPolygon' and len(geometry.geoms)==1:geometry=geometry.geoms[0]
        if geometry.geom_type!='Polygon' or geometry.is_empty or not geometry.is_valid or geometry.area<=0:
            raise ValueError(f'Invalid or disconnected component {component}')
        result[component]=geometry
    return result


def draw(path, geometries, groups, title, caption, method='Flow method: Gastner, Seguy and More (2018), cartogram-cpp.'):
    xmin=min(g.bounds[0] for g in geometries.values());xmax=max(g.bounds[2] for g in geometries.values())
    ymin=min(g.bounds[1] for g in geometries.values());ymax=max(g.bounds[3] for g in geometries.values())
    scale=min(1700/(xmax-xmin),900/(ymax-ymin));left=(1800-scale*(xmax-xmin))/2;top=140+(900-scale*(ymax-ymin))/2
    def point(x,y):return left+(x-xmin)*scale,top+(ymax-y)*scale
    def ring(r):return 'M'+'L'.join(f'{x:.3f},{y:.3f}' for x,y in (point(x,y) for x,y in r.coords))+'Z'
    parts=['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1120">','<rect width="1800" height="1120" fill="#faf9f6"/>','<g font-family="sans-serif" fill="#242424">',
        f'<text x="40" y="40" font-size="27">{html.escape(title)}</text>',
        '<text x="40" y="70" font-size="17">Continuous deformation of separate components. Not yet a square-tile layout. Not a production map.</text>',
        f'<text x="40" y="96" font-size="15">{html.escape(caption)}</text>']
    for c,g in sorted(geometries.items()):
        polygons = list(g.geoms) if g.geom_type == 'MultiPolygon' else [g]
        commands=''.join(ring(p.exterior)+''.join(ring(r) for r in p.interiors) for p in polygons)
        colour = groups[c].get('fill', country_color(groups[c]['country_id']))
        parts.append(f'<path d="{commands}" fill="{colour}" fill-rule="evenodd" stroke="#444" stroke-width=".55"><title>{html.escape(c)}</title></path>')
    largest={}
    for c in geometries:
        country=groups[c]['country_id']
        if country not in largest or geometries[c].area>geometries[largest[country]].area:largest[country]=c
    boxes=[]
    for c in sorted(largest.values(),key=lambda c:(-geometries[c].area,c)):
        g=geometries[c]
        if g.area*scale**2<700:continue
        p=g.representative_point();x,y=point(p.x,p.y);bounds=(x-17,y-9,x+17,y+6)
        if any(not(bounds[2]<b[0] or b[2]<bounds[0] or bounds[3]<b[1] or b[3]<bounds[1]) for b in boxes):continue
        boxes.append(bounds)
        parts.append(f'<text x="{x:.3f}" y="{y:.3f}" text-anchor="middle" font-size="12" paint-order="stroke" stroke="#faf9f6" stroke-width="2">{html.escape(groups[c].get("label", groups[c]["country_id"]))}</text>')
    parts.append(f'<text x="40" y="1094" font-size="13">Sources: Kontur population; Natural Earth. {html.escape(method)} Source year is unknown.</text></g></svg>')
    path.write_text('\n'.join(parts))


def run(inputs, geometry_path, output, title='Continuous geographic deformation',allow_isolated_missing=False,method=None):
    if output.exists():raise ValueError('Output already exists')
    groups={r['component_id']:r for r in read_csv(inputs/'groups.csv') if int(r['tiles'])>0}
    geometries=read_shapes(geometry_path)
    expected={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    missing=set(groups)-set(geometries);land={c for pair in expected for c in pair}
    if set(geometries)-set(groups) or (missing and (not allow_isolated_missing or missing&land)):raise ValueError('Component labels differ from requested groups')
    input_budget=sum(int(r['tiles']) for r in groups.values());groups={c:groups[c] for c in geometries}
    labels=sorted(geometries);geometry=[geometries[c] for c in labels];tree=STRtree(geometry)
    total_area=sum(g.area for g in geometry);budget=sum(int(r['tiles']) for r in groups.values());scale=budget/total_area
    contacts=set();overlap=0.;overlap_pairs=0
    for i,g in enumerate(geometry):
        for j in tree.query(g,predicate='intersects'):
            if j<=i:continue
            other=geometry[j];area=g.intersection(other).area
            if area>total_area*1e-12:overlap_pairs+=1;overlap+=area
            if g.boundary.intersection(other.boundary).length>0:contacts.add((labels[i],labels[j]))
    rows=[dict(component_id=c,country_id=groups[c]['country_id'],requested=int(groups[c]['tiles']),equivalent_tiles=geometries[c].area*scale,
        relative_error=geometries[c].area*scale/int(groups[c]['tiles'])-1,holes=len(geometries[c].interiors),input_holes=int(groups[c]['holes']),
        compactness=4*math.pi*geometries[c].area/geometries[c].length**2) for c in labels]
    metadata=json.loads((inputs/'manifest.json').read_text())
    report=dict(components=len(rows),tile_budget=budget,input_tile_budget=input_budget,excluded_isolated_components=sorted(missing),population_scope='Whole input, including components excluded from this guide',maximum_relative_area_error=max(abs(r['relative_error']) for r in rows),
        sum_absolute_equivalent_tile_error=sum(abs(r['equivalent_tiles']-r['requested']) for r in rows),
        overlap_pairs=overlap_pairs,overlap_share=overlap/total_area,holes=sum(r['holes'] for r in rows),
        changed_hole_counts=sum(r['holes']!=r['input_holes'] for r in rows),
        required_contacts=len(expected),missing_contacts=len(expected-contacts),false_contacts=len(contacts-expected),
        matched_population=metadata['population_total'],unmatched_population=metadata.get('unmatched_source_population'),
        limit='Exact boundary intersection checks can report a missing contact after independent simplification or numeric rounding. Continuous areas are not integer tile counts.',
        inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'manifest.json',inputs/'geographic-contacts.csv',geometry_path]},script_sha256=digest(Path(__file__)))
    output.mkdir(parents=True)
    with (output/'regions.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    (output/'metrics.json').write_text(json.dumps(report,indent=2)+'\n')
    draw(output/'review.svg',geometries,groups,title,f'{len(rows)} components; maximum area error {report["maximum_relative_area_error"]:.2%}; {overlap_pairs} overlap pairs; {report["missing_contacts"]} missing exact boundary contacts.',**({'method':method} if method else {}))
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','geometry','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--title',default='Continuous geographic deformation')
    parser.add_argument('--allow-isolated-missing',action='store_true')
    parser.add_argument('--method',help='Image method caption for a supplied guide')
    args=parser.parse_args();print(json.dumps(run(args.inputs,args.geometry,args.output,args.title,args.allow_isolated_missing,args.method),indent=2))
