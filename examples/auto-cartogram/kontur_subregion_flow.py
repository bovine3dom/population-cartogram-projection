#!/usr/bin/env python3
"""Test coarse within-component Kontur density in the continuous flow solver."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import subprocess
import time

import numpy as np
from shapely import STRtree, box, points, union_all
from shapely.geometry import mapping, shape

from review_flow import read_shapes, draw
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error


def targets(areas, mass, budget, strength):
    areas, mass = np.asarray(areas, dtype=float), np.asarray(mass, dtype=float)
    if (areas.shape != mass.shape or areas.ndim != 1 or not len(areas)
            or not np.isfinite(areas).all() or not np.isfinite(mass).all()
            or not np.isfinite(budget) or not 0 <= strength < 1 or budget <= 0
            or np.any(areas <= 0) or np.any(mass < 0) or mass.sum() <= 0):
        raise ValueError('Need positive areas and mass, and strength in [0, 1)')
    return budget*((1-strength)*areas/areas.sum()+strength*mass/mass.sum())


def patches(geometry, size):
    if not np.isfinite(size) or size <= 0:
        raise ValueError('Use a positive finite cell size')
    x0, y0, x1, y1 = geometry.bounds
    result = []
    for x in range(int(np.floor(x0/size)), int(np.floor(x1/size))+1):
        for y in range(int(np.floor(y0/size)), int(np.floor(y1/size))+1):
            g = geometry.intersection(box(x*size, y*size, (x+1)*size, (y+1)*size))
            parts = [p for p in getattr(g, 'geoms', [g]) if p.geom_type in ('Polygon', 'MultiPolygon') and p.area > 0]
            if parts:
                result.append(union_all(parts))
    return result


def merge_small(cells, minimum_area):
    cells = list(cells)
    while len(cells) > 1:
        i = min(range(len(cells)), key=lambda i: cells[i].area)
        if cells[i].area >= minimum_area:
            break
        small = cells.pop(i)
        j = max(range(len(cells)), key=lambda j: (small.boundary.intersection(cells[j].boundary).length, -small.distance(cells[j])))
        cells[j] = union_all([small, cells[j]])
    return cells


def merge_density(cells, mass, budget, strengths, minimum_target):
    cells, mass = list(cells), list(mass)
    while len(cells) > 1:
        smallest = np.min([targets([g.area for g in cells], mass, budget, s) for s in strengths], axis=0)
        i = int(np.argmin(smallest))
        if smallest[i] > minimum_target:
            break
        small, value = cells.pop(i), mass.pop(i)
        j = max(range(len(cells)), key=lambda j: (small.boundary.intersection(cells[j].boundary).length, -small.distance(cells[j])))
        cells[j] = union_all([small, cells[j]])
        mass[j] += value
    return cells, np.asarray(mass)


def run(root, output, cell_size=200., strengths=(0., .5, .9), grid=256, timeout=180):
    if (output.exists() or not np.isfinite(cell_size) or cell_size <= 0 or grid < 16 or timeout < 1
            or not strengths or len(set(strengths)) != len(strengths) or any(not 0 <= s < 1 for s in strengths)):
        raise ValueError('Use a new output and positive settings')
    inputs = root/'world-55000-dissolved-input'
    geometry_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    source_path = root/'world-55000-h3-5-density/sources.csv'
    binary = (root/'vendor/cartogram-cpp/build/Release/cartogram').resolve()
    native = read_shapes(geometry_path)
    groups = {r['component_id']: r for r in read_csv(inputs/'groups.csv') if int(r['tiles']) > 0}
    samples = defaultdict(list)
    with source_path.open() as stream:
        for row in csv.DictReader(stream):
            if row['group_id'] in native:
                samples[row['group_id']].append((float(row['x'])*1000, float(row['y'])*1000, float(row['value'])))
    output.mkdir(parents=True)
    features, data, reassigned, population = [], [], [], 0.
    # cartogram-cpp constants.hpp raises targets below 0.0001 of total area.
    # Use one shared partition that clears this floor in every density variant.
    minimum_target = sum(int(groups[c]['tiles']) for c in native)*.0001*1.01
    for c, g in sorted(native.items()):
        budget = int(groups[c]['tiles'])
        cells = merge_small(patches(g, cell_size), g.area/budget) if budget >= 16 else [g]
        p = np.asarray(samples[c])
        if not np.isclose(p[:, 2].sum(), float(groups[c]['group_population']), atol=.01, rtol=0):
            raise ValueError('Source population differs from component budget')
        tree = STRtree(cells)
        # A coastal H3 centre can lie outside the outline. Keep its component,
        # and assign it to the nearest clipped patch in that component.
        indices, distances = tree.query_nearest(points(p[:, :2]), return_distance=True, all_matches=False)
        masses = np.bincount(indices[1], weights=p[indices[0], 2], minlength=len(cells))
        if not np.isclose(masses.sum(), p[:, 2].sum(), atol=.01, rtol=0):
            raise AssertionError('Population lost during patch assignment')
        reassigned.append(dict(component=c, centres=int((distances > 1e-8).sum()),
                               population=float(p[indices[0][distances > 1e-8], 2].sum())))
        cells, masses = merge_density(cells, masses, budget, strengths, minimum_target)
        population += float(masses.sum())
        for i, (cell, mass) in enumerate(zip(cells, masses)):
            label = c+'@'+str(i)
            features.append(dict(type='Feature', properties=dict(patch_id=label, component_id=c), geometry=mapping(cell)))
            data.append(dict(patch_id=label, component_id=c, area=cell.area, population=float(mass)))
    geometry_file = output/'patches.geojson'
    geometry_file.write_text(json.dumps(dict(type='FeatureCollection', features=features), separators=(',', ':'))+'\n')
    report = dict(cell_size=cell_size, nominal_km=cell_size*6.371, grid=grid,
                  components=len(native), patches=len(features), population=population,
                  minimum_split_component_tiles=16, minimum_uniform_patch_tiles=1,
                  maximum_solver_grid=2048, minimum_patch_target=minimum_target,
                  small_target_rule='Merge patches until every tested blend exceeds the solver floor, unless only one patch remains.',
                  reassigned_outside_centres=reassigned, runs=[],
                  inputs={str(p): digest(p) for p in [geometry_path, source_path, inputs/'groups.csv', binary, root/'vendor/cartogram-cpp/include/constants.hpp']},
                  script_sha256=digest(Path(__file__)),
                  limits=['Continuous mainland experiment only. No tiles, islands, lake insertion, or population exports are changed.',
                          'The control has the same artificial subdivision as density runs, but uniform density within each original component.',
                          'Patch targets blend population share and geographic area share within each component. Component tile-area targets remain unchanged.',
                          'Kontur H3-5 cells place their population at their centres. Outside centres use the nearest patch of the same component.',
                          'The equal-area grid is not an equal-distance grid. Nominal kilometres use radius 6371 km.',
                          'The uniform share is a positive density floor, not Gaussian smoothing. Grid aggregation removes fine detail.',
                          'Extra internal boundaries and solver preprocessing can affect the result. Compare with the subdivided control.',
                          'Complete means that review artifacts were produced, not solver convergence or approval. Check solver_success and measured area errors.',
                          'Solver output needs validity, area, and topology checks before use as a tile guide.'])
    (output/'patch-data.json').write_text(json.dumps(data)+'\n')
    def save():
        (output/'experiment.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    indices = {c: [i for i, r in enumerate(data) if r['component_id'] == c] for c in native}
    for strength in strengths:
        folder = output/f'blend-{strength:g}'
        folder.mkdir()
        target = np.zeros(len(data))
        for c, ii in indices.items():
            target[ii] = targets([data[i]['area'] for i in ii], [data[i]['population'] for i in ii], int(groups[c]['tiles']), strength)
        areas = folder/'areas.csv'
        with areas.open('w', newline='') as stream:
            writer = csv.writer(stream, lineterminator='\n')
            writer.writerow(['patch_id', 'tiles'])
            writer.writerows((r['patch_id'], format(t, '.17f')) for r, t in zip(data, target))
        command = [str(binary), str(geometry_file.resolve()), str(areas.resolve()), '--skip_projection', '--id', 'patch_id', '--area', 'tiles',
                   '--n_grid_rows_or_cols', str(grid), '--max_allowed_autoscale_grid_length', '2048', '--timeout', str(timeout), '--export_preprocessed']
        entry = dict(strength=strength, command=command, complete=False, target_sha256=digest(areas))
        report['runs'].append(entry)
        save()
        start = time.monotonic()
        try:
            with (folder/'solver.log').open('w') as log:
                process = subprocess.run(command, cwd=folder, stdout=log, stderr=subprocess.STDOUT, timeout=timeout+60)
            entry['exit_code'] = process.returncode
            entry['solver_success'] = process.returncode == 0
            result_path = folder/'areas_cartogram.geojson'
            if not result_path.exists():
                raise ValueError('Solver produced no geometry')
            result = json.loads(result_path.read_text())['features']
            by_id = {f['properties']['patch_id']: shape(f['geometry']) for f in result}
            if set(by_id) != {r['patch_id'] for r in data}:
                raise ValueError('Solver output patch IDs differ')
            if any(not g.is_valid or g.is_empty for g in by_id.values()):
                raise ValueError('Invalid solver output patch')
            merged = {c: union_all([by_id[data[i]['patch_id']] for i in ii]) for c, ii in indices.items()}
            total = sum(g.area for g in merged.values())
            budget = sum(int(groups[c]['tiles']) for c in native)
            entry['records'] = [dict(component=c, country=groups[c]['country_id'], shape_error=outline_error(g, native[c]),
                    parts=len(getattr(g, 'geoms', [g])), valid=bool(g.is_valid),
                    relative_area_error=g.area/total*budget/int(groups[c]['tiles'])-1) for c, g in sorted(merged.items())]
            patch_area = sum(g.area for g in by_id.values())
            entry['maximum_patch_relative_area_error'] = max(abs(by_id[r['patch_id']].area/patch_area*target.sum()/t-1) for r, t in zip(data, target))
            merged_file = folder/'components.geojson'
            merged_file.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g)) for c, g in sorted(merged.items())]), separators=(',', ':'))+'\n')
            for name, shapes in [('world', merged), ('eurasia', {c:g for c,g in merged.items() if groups[c]['country_id'] in 'RUS CHN IND KAZ KGZ UZB TKM TJK AFG PAK IRN AZE MNG NPL BTN BGD MMR PRK KOR'.split()})]:
                draw(folder/(name+'.svg'), shapes, groups, f'Kontur patch flow: {strength:.0%} population, {cell_size:g}-unit cells',
                     'Continuous mainland experiment; no tile fit. Regional panel omits other countries.')
                subprocess.run(['rsvg-convert', str(folder/(name+'.svg')), '-o', str(folder/(name+'.png'))], check=True)
            entry.update(complete=True, approved=False, geometry_sha256=digest(merged_file))
        except Exception as error:
            entry['error'] = str(error)
        finally:
            entry['seconds'] = time.monotonic()-start
            save()
            print(json.dumps({k:v for k,v in entry.items() if k != 'records'}), flush=True)
    return {k:report[k] for k in ['components', 'patches', 'population']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--cell-size', type=float, default=200.)
    parser.add_argument('--strengths', type=float, nargs='+', default=[0., .5, .9])
    parser.add_argument('--grid', type=int, default=256)
    parser.add_argument('--timeout', type=int, default=180)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
