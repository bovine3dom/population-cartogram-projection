#!/usr/bin/env python3
"""Draw shared group labels for a trial OWID component assignment and resize."""
import argparse
import csv
import colorsys
import html
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np
from shapely.geometry import shape

from audit_owid_budgets import parts
from review_gaps import read_cells, draw_layout
from resize_owid_islands import local_geometry


def records(path):
    with path.open() as stream:return list(csv.DictReader(stream))


def run(owid, layout, polygons, output):
    if output.exists():raise ValueError('Use a new review output')
    output.mkdir(parents=True)
    report=json.loads((layout/'report.json').read_text())
    old,_=read_cells(owid,owid=True)
    new={};before={}
    for r in records(layout/'cells.csv'):new.setdefault(r['component_id'],set()).add((int(r['x']),int(r['y'])))
    # Source country labels come from the already audited output, not a second
    # independent assignment rule in the renderer.
    iso=json.loads(Path('/usr/share/iso-codes/json/iso_3166-1.json').read_text())['3166-1']
    codes={r['alpha_3']:int(r['numeric']) for r in iso}
    for c in {k.split(':')[0] for k in new}:
        code=codes.get(c,int(c[5:]) if c.startswith('OWID_') else -1)
        for i,p in enumerate(parts({p for p,k in old.items() if int(k)==code})):before[f'{c}:T{i+1}']=p
    assert set(before)==set(new)
    matches=records(layout/'matches.csv');assignments=records(layout/'source-assignments.csv')
    features={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features']}
    palette=['#'+''.join(f'{round(v*255):02x}' for v in colorsys.hls_to_rgb((i*.61803398875)%1,.7,.6)) for i in range(64)]
    pages=[]
    for entry in report['countries']:
        if entry['parts']<2:continue
        c=entry['country'];rows=[r for r in matches if r['country']==c]
        lookup={r['target_part']:r for r in rows};groups={r['group']:r for r in rows}
        src=[r for r in assignments if r['country']==c]
        anchor=features[max(src,key=lambda r:float(r['population']))['component_id']].centroid
        geos=local_geometry([features[r['component_id']] for r in src],anchor.x,anchor.y)
        source_shapes=[];source_labels=[]
        for r,g in zip(src,geos):
            part=r['target_part'];i=int(part[1:])-1
            gs=list(g.geoms) if g.geom_type=='MultiPolygon' else [g]
            source_shapes.extend((i,list(p.exterior.coords)) for p in gs)
            if r['component_id']==groups[part]['anchor_component']:
                source_labels.append((i,(g.centroid.x,g.centroid.y),part.replace('T','G')))
        sections=[]
        for cells in (before,new):
            shapes=[];labels=[]
            for part,r in lookup.items():
                points=cells[f'{c}:{part}'];i=int(r['group'][1:])-1
                shapes.extend((i,[(x-.5,y-.5),(x+.5,y-.5),(x+.5,y+.5),(x-.5,y+.5)]) for x,y in sorted(points))
                centre=np.mean(sorted(points),axis=0)
                anchor=min(points,key=lambda p:sum((np.array(p)-centre)**2))
                mark='*' if r['identity']!='reviewed' else ''
                labels.append((i,anchor,f"{r['group'].replace('T','G')}{mark}: {len(points)}"))
            sections.append((shapes,labels))
        sections.append((source_shapes,source_labels))
        common=[p for shapes,_ in sections[:2] for _,ring in shapes for p in ring]
        def bounds(points):return min(p[0] for p in points),min(p[1] for p in points),max(p[0] for p in points),max(p[1] for p in points)
        common_bounds=bounds(common)
        svg=['<svg xmlns="http://www.w3.org/2000/svg" width="2100" height="800"><rect width="2100" height="800" fill="white"/><g font-family="DejaVu Sans" font-size="14">',
             f'<text x="20" y="25">{c}: {html.escape(entry["status"])}. Shared G labels and colours identify the SAME assigned group.</text>',
             '<text x="20" y="50">* Automatic identity needs review. All source islands inherit their assigned group colour. Source panel has its own scale.</text>']
        for side,(shapes,labels) in enumerate(sections):
            west,south,east,north=common_bounds if side<2 else bounds([p for _,ring in shapes for p in ring])
            scale=min(620/max(east-west,1e-6),620/max(north-south,1e-6))
            def xy(p):return 20+700*side+(p[0]-west)*scale,130+(north-p[1])*scale
            svg.append(f'<text x="{20+700*side}" y="100">{["OWID before","Trial after","Assigned source population groups"][side]}</text>')
            for i,ring in shapes:
                coords=' '.join(f'{x:.2f},{y:.2f}' for x,y in map(xy,ring))
                svg.append(f'<polygon points="{coords}" fill="{palette[i%len(palette)]}" stroke="#777" stroke-width=".25"/>')
            for i,point,label in labels:
                x,y=xy(point);svg.append(f'<text x="{x:.2f}" y="{y:.2f}" fill="black">{html.escape(label)}</text>')
        svg.append('</g></svg>')
        (output/f'{c}.svg').write_text(''.join(svg))
        subprocess.run(['rsvg-convert',str(output/f'{c}.svg'),'-o',str(output/f'{c}.png')],check=True)
        pages.append(f'<h2>{c}</h2><p>{html.escape(entry["status"])}</p><a href="{c}.png"><img src="{c}.png" alt="{c}: original, trial, and shared source group labels"></a>')
    if report.get('relaxed_layout'):
        shutil.copyfile(layout/'relaxation.json',output/'relaxation.json')
        for country in report['relaxation']['border_fits']:
            for label in sorted(k for k in new if k.startswith(country+':')):
                points=before[label]|new[label]
                west=min(x for x,y in points)-8;east=max(x for x,y in points)+8
                south=min(y for x,y in points)-8;north=max(y for x,y in points)+8
                for name,cells in [('before',before),('after',new)]:
                    stem=label.replace(':','-')+'-'+name
                    owner={p:k.split(':')[0] for k,ps in cells.items() for p in ps
                           if west<=p[0]<=east and south<=p[1]<=north}
                    draw_layout(output/f'{stem}.svg',owner,f'{label} and neighbours: {name}',{}, {},borders=True)
                    subprocess.run(['rsvg-convert',str(output/f'{stem}.svg'),'-o',str(output/f'{stem}.png')],check=True)
                    pages.insert(0,f'<h2>{label} and neighbours: {name}</h2><img src="{stem}.png" alt="Shared border context">')
    for name in ('report.json','matches.csv','source-assignments.csv','source-scopes-without-tiles.csv'):shutil.copyfile(layout/name,output/name)
    import gzip
    (output/'cells.csv.gz').write_bytes(gzip.compress((layout/'cells.csv').read_bytes(),mtime=0))
    (output/'owid-cartogram.csv.gz').write_bytes(gzip.compress((layout/'owid-cartogram.csv').read_bytes(),mtime=0))
    for name,cells in [('before',before),('after',new)]:
        draw_layout(output/f'world-{name}.svg',{p:k.split(':')[0] for k,points in cells.items() for p in points},f'OWID island resize: {name}',{}, {})
        subprocess.run(['rsvg-convert',str(output/f'world-{name}.svg'),'-o',str(output/f'world-{name}.png')],check=True)
    (output/'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OWID island resize trial</title><style>body{font:18px system-ui;max-width:1500px;margin:2em auto;padding:0 1em}img{max-width:100%}</style><h1>OWID island resize trial</h1><p>Research only. No default layout or mapping export changed. Automatic island identities still need review. See each country status below; blocked trials remain unchanged. Shared G labels now refer to the same assigned groups, not independent size ranks.</p><p>Country totals, existing piece contacts, and connectivity stay fixed. The report lists any released inter-island sea gaps. Small source components join the nearest matched component within the same country. A visibility and protected-border floor can prevent exact population proportions. No new islands are created. Source scopes without target tiles remain unrepresented.</p><p><a href="report.json">Checks and blocked countries</a> · <a href="matches.csv">Identities and requested budgets</a> · <a href="source-assignments.csv">Every source assignment</a> · <a href="source-scopes-without-tiles.csv">Unrepresented scopes</a> · <a href="cells.csv.gz">Trial land tiles</a> · <a href="owid-cartogram.csv.gz">Trial in OWID coordinate format</a></p><p>For a blocked country, the displayed layout is unchanged; requested budgets in matches.csv were not applied. Conflicting South Africa/Lesotho coordinates use the audit last-row convention.</p><h2>World before</h2><img src="world-before.png" alt="OWID before"><h2>World after</h2><img src="world-after.png" alt="OWID trial after">'+''.join(pages)+'</html>')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','layout','polygons','output'):parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
