#!/usr/bin/env python3
"""Compare OWID tile parts with source component budgets without editing tiles."""
import argparse
import csv
import json
import math
import html
import subprocess
from collections import defaultdict
from pathlib import Path

from compact_regions import adjacent
from review_gaps import read_cells
from save_review import digest


def parts(points):
    remaining = set(points); result = []
    while remaining:
        seed = min(remaining); remaining.remove(seed)
        part = {seed}; queue = [seed]
        for p in queue:
            for q in adjacent(p):
                if q in remaining:
                    remaining.remove(q); part.add(q); queue.append(q)
        result.append(part)
    return sorted(result, key=lambda p: (-len(p), min(p)))


def apportion(populations, tiles):
    total = math.fsum(populations)
    if total <= 0 or tiles < 0:
        raise ValueError('Need positive population and non-negative tile count')
    quotas = [p/total*tiles for p in populations]
    result = [math.floor(q) for q in quotas]
    for i in sorted(range(len(quotas)), key=lambda i: (-(quotas[i]-result[i]), i))[:tiles-sum(result)]:
        result[i] += 1
    return quotas, result


def source_scope(row, iso):
    # Overseas map units can have their own OWID code, even when Natural Earth
    # puts them under a sovereign country. Do not count Reunion as France.
    return row['map_unit'] if row['map_unit'] in iso else row['country_id']


def write_csv(path, rows):
    if rows:
        with path.open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
            writer.writeheader(); writer.writerows(rows)


def panel(path, country, tile_parts, sources, geometries):
    panels = [[], []]
    for i, part in enumerate(tile_parts):
        centre = [sum(p[a] for p in part)/len(part) for a in (0,1)]
        anchor = min(part, key=lambda p: sum((p[a]-centre[a])**2 for a in (0,1)))
        panels[0].append((i, [[(x-.5,y-.5),(x+.5,y-.5),(x+.5,y+.5),(x-.5,y+.5)] for x,y in part], anchor, f'T{i+1}: {len(part)}'))
    for i, row in enumerate(sources):
        geometry = geometries[row['component_id']]
        rings = [geometry['coordinates'][0]] if geometry['type']=='Polygon' else [p[0] for p in geometry['coordinates']]
        anchor = ((row['west']+row['east'])/2, (row['south']+row['north'])/2)
        panels[1].append((i, rings, anchor, f"S{i+1}: {row['proportional_tiles']:.1f}"))
    svg=['<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="650"><rect width="1400" height="650" fill="white"/><g font-family="DejaVu Sans" font-size="13">',
         f'<text x="20" y="25">{country}: ranks and colours are NOT a confirmed crosswalk</text>']
    colours=['#a6cee3','#b2df8a','#fb9a99','#fdbf6f','#cab2d6','#ffff99']
    for side, entries in enumerate(panels):
        points=[p for _,rings,_,_ in entries for ring in rings for p in ring]
        west=min(p[0] for p in points); east=max(p[0] for p in points)
        south=min(p[1] for p in points); north=max(p[1] for p in points)
        scale=min(650/max(east-west,1e-6),520/max(north-south,1e-6))
        def xy(p): return 25+700*side+(p[0]-west)*scale, 90+(north-p[1])*scale
        title='OWID parts: current tiles' if side==0 else 'Source components: population-proportional tiles'
        svg.append(f'<text x="{25+700*side}" y="65">{title}</text>')
        labels=[]
        for i,rings,anchor,label in entries:
            for ring in rings:
                coords=' '.join(f'{x:.2f},{y:.2f}' for x,y in map(xy,ring))
                svg.append(f'<polygon points="{coords}" fill="{colours[i%len(colours)]}" stroke="#666" stroke-width=".3"/>')
            if i<10:
                x,y=xy(anchor);labels.append(f'<text x="{x:.2f}" y="{y:.2f}">{html.escape(label)}</text>')
        svg.extend(labels)
    svg.append('</g></svg>')
    path.with_suffix('.svg').write_text(''.join(svg))
    subprocess.run(['magick','-background','white',str(path.with_suffix('.svg')),str(path)],check=True)


def run(owid, components, polygons, iso_path, output, countries):
    if output.exists():
        raise ValueError('Use a new output directory')
    iso = {r['alpha_3']:int(r['numeric']) for r in json.loads(iso_path.read_text())['3166-1']}
    reverse = {v:k for k,v in iso.items()}
    owner, grid = read_cells(owid, owid=True)
    raw_owners = defaultdict(list)
    with owid.open() as stream:
        for x,y,code in csv.reader(stream): raw_owners[int(x),int(y)].append(int(code))
    conflicts = [dict(x=x,y=y,codes=codes,inventory_owner=codes[-1])
                 for (x,y),codes in raw_owners.items() if len(set(codes))>1]
    targets = defaultdict(set)
    for p, code in owner.items(): targets[reverse.get(int(code), f'OWID_{code}')].add(p)
    source = defaultdict(list)
    with components.open() as stream:
        for row in csv.DictReader(stream):
            if float(row['population']) > 0: source[source_scope(row, iso)].append(row)
    output.mkdir(parents=True)
    country_rows=[]; target_rows=[]; source_rows=[]
    geometries={f['properties']['component_id']:f['geometry'] for f in json.loads(polygons.read_text())['features']}
    for country in sorted(set(targets)|set(source)):
        tile_parts = parts(targets[country])
        rows = sorted(source[country], key=lambda r: (-float(r['population']), r['component_id']))
        total = len(targets[country]); population = math.fsum(float(r['population']) for r in rows)
        quotas,budgets = apportion([float(r['population']) for r in rows],total) if rows else ([],[])
        country_rows.append(dict(country=country,owid_tiles=total,owid_parts=len(tile_parts),source_components=len(rows),population=population,
                                 components_with_positive_budget=sum(b>0 for b in budgets),
                                 status='needs_crosswalk' if rows and total else 'no_owid_tiles' if rows else 'no_source_population'))
        for i,part in enumerate(tile_parts):
            target_rows.append(dict(country=country,target_part=f'T{i+1}',tiles=len(part),x=sum(p[0] for p in part)/len(part),y=sum(p[1] for p in part)/len(part),
                                    west=min(p[0] for p in part),east=max(p[0] for p in part),south=min(p[1] for p in part),north=max(p[1] for p in part)))
        records=[]
        for i,(row,quota,budget) in enumerate(zip(rows,quotas,budgets)):
            record=dict(country=country,source_part=f'S{i+1}',component_id=row['component_id'],name=row['name'],population=float(row['population']),
                        proportional_tiles=quota,rounded_tiles=budget,west=float(row['west']),east=float(row['east']),south=float(row['south']),north=float(row['north']))
            records.append(record); source_rows.append(record)
        if country in countries and rows and tile_parts:
            panel(output/f'{country}.png',country,tile_parts,records,geometries)
    write_csv(output/'countries.csv',country_rows)
    write_csv(output/'owid-parts.csv',target_rows)
    write_csv(output/'source-budgets.csv',source_rows)
    (output/'audit.json').write_text(json.dumps(dict(grid=grid,unique_tiles=len(owner),
        conflicts=conflicts,overlap_policy='Inventory uses the last row at each coordinate, as in review_gaps.py. Raw input is unchanged. Resolve conflicting ownership before fitting.',
        inputs={str(p):digest(p) for p in (owid,components,polygons,iso_path,Path(__file__))},
        policy='Fixed OWID country totals. Largest-remainder component budgets. No minimum island tile. No tile edits or automatic component matching.',
        limits=['Native H3 centres assign population to source polygons; boundary and unmatched points are excluded.',
                'Source map-unit ISO codes take priority over sovereign country codes. Unmapped scopes remain explicit.',
                'Four-connected OWID parts need not correspond one-to-one to source islands or exclaves.',
                'Source ranks and target ranks are separate. Equal ranks do not establish identity.',
                'Zero-budget source components need an explicit grouping or visibility policy before fitting.',
                'OWID and Kontur population dates and administrative scopes can differ.']),indent=2)+'\n')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','components','polygons','iso_path','output'): parser.add_argument(name,type=Path)
    parser.add_argument('--countries',nargs='+',default=['IDN','JPN','GBR','USA','RUS','CAN','PHL','MYS','GRC','ITA','FRA'])
    run(**vars(parser.parse_args()))
