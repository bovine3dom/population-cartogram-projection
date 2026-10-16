#!/usr/bin/env python3
"""Fit mainland components independently with the saved Kontur patch targets."""
import argparse
import csv
import html
import json
import math
from pathlib import Path
import subprocess

from shapely import affinity, union_all
from shapely.geometry import mapping, shape

from review_flow import read_shapes
from review_layout import read_csv, country_color
from save_review import digest
from trace_kazakhstan import outline_error


def select_patches(features, data, targets, component, budget, population):
    selected = [f for f in features if f['properties']['component_id'] == component]
    labels = [f['properties']['patch_id'] for f in selected]
    records = [r for r in data if r['component_id'] == component]
    rows = [r for r in targets if r['patch_id'] in labels]
    if (not labels or len(set(labels)) != len(labels)
            or len(rows) != len(labels) or len(records) != len(labels)
            or {r['patch_id'] for r in rows} != set(labels)
            or {r['patch_id'] for r in records} != set(labels)):
        raise ValueError('Patch labels differ')
    if not math.isclose(sum(float(r['tiles']) for r in rows), budget, abs_tol=1e-7, rel_tol=0):
        raise ValueError('Target budget differs')
    if not math.isclose(sum(r['population'] for r in records), population, abs_tol=.01, rel_tol=0):
        raise ValueError('Population differs')
    return selected, rows


def normalized(g, area=1.):
    scale = math.sqrt(area/g.area)
    g = affinity.translate(g, -g.centroid.x, -g.centroid.y)
    return affinity.scale(g, scale, scale, origin=(0, 0))


def compare(path, code, panels, reference):
    shapes = [normalized(g) for _, g in panels]
    native = normalized(reference)
    bounds = [g.bounds for g in shapes+[native]]
    extent_x = max(max(abs(b[0]), abs(b[2])) for b in bounds)
    extent_y = max(max(abs(b[1]), abs(b[3])) for b in bounds)
    scale = min(390/extent_x, 215/extent_y)
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1200">',
           '<rect width="1800" height="1200" fill="#faf9f6"/>', '<g font-family="sans-serif">',
           f'<text x="30" y="40" font-size="28">{code}: shared flow versus independent flow</text>',
           '<text x="30" y="70" font-size="18">Equal area and aligned centres within this page; no rotation. Dashed outline: original Equal Earth shape.</text>']
    for i, ((title, raw), g) in enumerate(zip(panels, shapes)):
        x, y = 450+900*(i % 2), 350+550*(i//2)
        def commands(geometry):
            return ''.join('M'+'L'.join(f'{x+px*scale:.3f},{y-py*scale:.3f}' for px,py in ring.coords)+'Z'
                           for ring in [geometry.exterior, *geometry.interiors])
        svg.extend([f'<text x="{x-410}" y="{y-240}" font-size="23">{html.escape(title)}</text>',
                    f'<path d="{commands(g)}" fill="{country_color(code)}" fill-rule="evenodd" stroke="#333"/>',
                    f'<path d="{commands(native)}" fill="none" stroke="#555" stroke-width="2" stroke-dasharray="6 5"/>',
                    f'<text x="{x-410}" y="{y+245}" font-size="18">Outline error: {outline_error(raw, reference):.4f}</text>'])
    svg.append('<text x="30" y="1175" font-size="17">Diagnostic only: mainland component, no neighbours, island placement, lakes, or tile fit. Sources: Natural Earth; Kontur.</text></g></svg>')
    path.write_text('\n'.join(svg)+'\n')
    subprocess.run(['rsvg-convert', str(path), '-o', str(path.with_suffix('.png'))], check=True)


def run(root, output, countries=('RUS', 'CHN'), grid=256):
    if output.exists() or grid < 16:
        raise ValueError('Use a new output directory and a grid of at least 16')
    baseline = root/'kontur-patch-flow-200-floor'
    original = root/'world-55000-mainland-flow/input/geometry.geojson'
    binary = (root/'vendor/cartogram-cpp/build/Release/cartogram').resolve()
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    groups = {r['component_id']: r for r in read_csv(groups_path)}
    native = read_shapes(original)
    shared = read_shapes(baseline/'blend-0.9/components.geojson')
    experiment = json.loads((baseline/'experiment.json').read_text())
    saved = next(r for r in experiment['runs'] if r['strength'] == .9)
    if not saved['solver_success'] or saved['geometry_sha256'] != digest(baseline/'blend-0.9/components.geojson'):
        raise ValueError('Saved shared-flow guide differs')
    features = json.loads((baseline/'patches.geojson').read_text())['features']
    data = json.loads((baseline/'patch-data.json').read_text())
    output.mkdir(parents=True)
    report = dict(countries=[], grid=grid, inputs={str(p): digest(p) for p in [original, groups_path, binary,
                  baseline/'patches.geojson', baseline/'patch-data.json', baseline/'experiment.json', baseline/'blend-0.9/components.geojson']},
                  script_sha256=digest(Path(__file__)),
                  limits=['Mainland components only. This is not a world layout.',
                          'Reuse exact saved patches and target rows. Each solver call has one component and no neighbours.',
                          'The solver domain and effective spatial resolution change when neighbours are removed.',
                          'Normalize each output to its component tile-area budget after solving. No tile partition is made.',
                          'Equal-area comparison panels do not show relative country size or placement.'])
    def save():
        (output/'experiment.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    for code in countries:
        c = max((c for c in native if groups[c]['country_id'] == code), key=lambda c: int(groups[c]['tiles']))
        budget, population = int(groups[c]['tiles']), float(groups[c]['group_population'])
        record = dict(country=code, component=c, tiles=budget, population=population, runs=[],
                      shared_shape_error=outline_error(shared[c], native[c]))
        report['countries'].append(record)
        fitted = {}
        for strength in (0., .9):
            folder = output/code/f'blend-{strength:g}'
            folder.mkdir(parents=True)
            source_targets = baseline/f'blend-{strength:g}/areas.csv'
            report['inputs'][str(source_targets)] = digest(source_targets)
            patches, rows = select_patches(features, data, read_csv(source_targets), c, budget, population)
            geometry, areas = folder/'patches.geojson', folder/'areas.csv'
            geometry.write_text(json.dumps(dict(type='FeatureCollection', features=patches), separators=(',', ':'))+'\n')
            with areas.open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=['patch_id', 'tiles'], lineterminator='\n')
                writer.writeheader()
                writer.writerows(rows)
            command = [str(binary), str(geometry.resolve()), str(areas.resolve()), '--skip_projection', '--id', 'patch_id', '--area', 'tiles',
                       '--n_grid_rows_or_cols', str(grid), '--max_allowed_autoscale_grid_length', '2048', '--timeout', '180', '--export_preprocessed']
            entry = dict(strength=strength, patches=len(patches), command=command, complete=False,
                         geometry_sha256=digest(geometry), targets_sha256=digest(areas))
            record['runs'].append(entry)
            save()
            with (folder/'solver.log').open('w') as log:
                process = subprocess.run(command, cwd=folder, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            entry['exit_code'] = process.returncode
            save()
            if process.returncode:
                raise ValueError(f'Independent solver failed: {code}, {strength}')
            result = json.loads((folder/'areas_cartogram.geojson').read_text())['features']
            by_id = {f['properties']['patch_id']: shape(f['geometry']) for f in result}
            if len(result) != len(rows) or set(by_id) != {r['patch_id'] for r in rows}:
                raise ValueError('Output patch labels differ')
            if any(not g.is_valid or g.is_empty for g in by_id.values()):
                raise ValueError('Invalid output patch')
            g = union_all(list(by_id.values()))
            if g.geom_type != 'Polygon' or not g.is_valid:
                raise ValueError('Disconnected or invalid output component')
            total = sum(p.area for p in by_id.values())
            fitted[strength] = normalized(g, budget)
            path = folder/'component.geojson'
            path.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(fitted[strength]))]), separators=(',', ':'))+'\n')
            entry.update(complete=True, shape_error=outline_error(g, native[c]),
                         maximum_patch_relative_area_error=max(abs(by_id[r['patch_id']].area/total*budget/float(r['tiles'])-1) for r in rows),
                         overlap_share=(total-g.area)/total, normalized_area=fitted[strength].area, output_sha256=digest(path))
            save()
        compare(output/code/'comparison.svg', code, [('Original Equal Earth outline', native[c]), ('Shared world flow: 90% Kontur', shared[c]),
                ('Independent flow: uniform control', fitted[0.]), ('Independent flow: 90% Kontur', fitted[.9])], native[c])
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--countries', nargs='+', default=['RUS', 'CHN'])
    parser.add_argument('--grid', type=int, default=256)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
