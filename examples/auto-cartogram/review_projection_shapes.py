#!/usr/bin/env python3
"""Compare fresh population-sized outlines with current mainland tile shapes."""
import argparse
import csv
import html
import json
from pathlib import Path
import subprocess

import numpy as np
from shapely import affinity, transform, union_all
from shapely.geometry import box, shape

from geographic_baseline import grow
from prepare_flow import equal_earth, mercator
from review_layout import connectivity, load
from save_review import digest


def normalize(geometry, area):
    if not geometry.is_valid or geometry.area <= 0 or area <= 0:
        raise ValueError('Positive area and valid geometry required')
    geometry = affinity.translate(geometry, -geometry.centroid.x, -geometry.centroid.y)
    scale = np.sqrt(area/geometry.area)
    return affinity.scale(geometry, scale, scale, origin=(0, 0))


def tile_geometry(cells):
    land = union_all([box(x-.5, y-.5, x+.5, y+.5) for x, y in sorted(cells)])
    return affinity.translate(land, -land.centroid.x, -land.centroid.y)


def run(inputs, layout, polygons, output, countries=('RUS', 'CHN', 'IND', 'CAN')):
    if output.exists():
        raise ValueError('Use a new output directory')
    rows, tiles, _ = load(inputs, layout)
    features = {f['properties']['component_id']: shape(f['geometry'])
                for f in json.loads(polygons.read_text())['features']}
    output.mkdir(parents=True)
    records, exports = [], []
    for country in countries:
        component = max((c for c in tiles if rows[c]['country_id'] == country), key=lambda c: (len(tiles[c]), c))
        count = int(rows[component]['tiles'])
        if len(tiles[component]) != count:
            raise ValueError('Input tile count differs from budget')
        current = tile_geometry(tiles[component])
        panels, measures = [], {}
        for name, project in [('Equal Earth', equal_earth), ('Mercator', mercator)]:
            source = normalize(transform(features[component], project), count)
            fresh, _ = grow(source, count)
            assert len(fresh) == count and connectivity(fresh) == 1
            land = tile_geometry(fresh)
            panels.extend([(name+' outline', source), (name+' fresh tiles', land)])
            measures[name] = dict(source_holes=len(source.interiors),
                fresh_outline_iou=land.intersection(source).area/land.union(source).area,
                current_outline_iou=current.intersection(source).area/current.union(source).area,
                source_width=source.bounds[2]-source.bounds[0], source_height=source.bounds[3]-source.bounds[1])
            exports.extend((country, component, name, x, y) for x, y in sorted(fresh))
        panels.append(('Current lake layout', current))
        bounds = union_all([g for _, g in panels]).bounds
        x0, y0, x1, y1 = bounds
        margin = max(x1-x0, y1-y0)*.04
        parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="650">',
                 '<rect width="2000" height="650" fill="#faf9f6"/>',
                 f'<text x="24" y="36" font-family="sans-serif" font-size="25">{html.escape(country)}: largest component; {count:,} population tiles in every panel</text>',
                 '<text x="24" y="65" font-family="sans-serif" font-size="17">Same area and display scale. North is up. Shapes are centred, not placed on a world map.</text>']
        for i, (title, geometry) in enumerate(panels):
            parts.append(f'<text x="{20+400*i}" y="110" font-family="sans-serif" font-size="20">{title}</text>')
            parts.append(f'<svg x="{10+400*i}" y="130" width="380" height="450" viewBox="{x0-margin} {-y1-margin} {x1-x0+2*margin} {y1-y0+2*margin}"><g transform="scale(1,-1)">')
            parts.append(geometry.svg(fill_color='#91b9cc', opacity=1).replace('stroke-width="2.0"', 'stroke-width="0.08"'))
            parts.append('</g></svg>')
        parts.append('<text x="24" y="610" font-family="sans-serif" font-size="16">Diagnostic only. Fresh growth does not preserve lake holes. Other islands and components are not shown.</text></svg>')
        svg = output/(country+'.svg')
        svg.write_text('\n'.join(parts)+'\n')
        subprocess.run(['rsvg-convert', str(svg), '-o', str(output/(country+'.png'))], check=True)
        records.append(dict(country=country, component=component, tiles=count,
                            country_tiles=sum(len(p) for c, p in tiles.items() if rows[c]['country_id'] == country), projections=measures))
    with (output/'templates.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['country_id', 'component_id', 'projection', 'x', 'y'])
        writer.writerows(exports)
    report = dict(records=records, projection='Spherical Mercator, radius 1000; no latitude clipping; poles rejected',
                  limits=['Largest component only, not a world layout.', 'Exact existing component population budgets, not projected-area allocation.',
                          'Fresh growth keeps one connected shape but does not preserve lake holes. Do not use as a production template.',
                          'Centroid-aligned overlap is measured separately against each projection; scores across different targets are not a ranking of projections.'],
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', layout/'cells.csv', polygons]},
                  scripts={n: digest(Path(__file__).with_name(n)) for n in ['review_projection_shapes.py', 'prepare_flow.py', 'geographic_baseline.py']})
    (output/'metrics.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--countries', nargs='+', default=['RUS', 'CHN', 'IND', 'CAN'])
    run(**vars(parser.parse_args()))
