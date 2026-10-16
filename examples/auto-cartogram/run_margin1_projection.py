#!/usr/bin/env python3
"""Repeat the preferred margin-one and lake pipeline with one flow projection change."""
import argparse
import json
from pathlib import Path
import subprocess

import dock_true_borders
import place_lake_regions
import prepare_flow
import review_layout
import review_regions
import run_compact_pipeline
from save_review import digest

ROOT = Path('output/auto-cartogram')
INPUTS = ROOT/'world-55000-dissolved-input'
POLYGONS = ROOT/'world-dissolved/polygons.geojson'
BASE = ROOT/'geography-water-trials/margin-1/pipeline.json'
DOCK = ROOT/'geography-margin1-rejoined-final/docking.json'
LAKES = ROOT/'geography-margin1-lake-vacancies-final/lake-placement.json'
FLOW = ROOT/'world-55000-mainland-flow/run.json'
REFERENCE = ROOT/'geography-margin1-lake-vacancies-final'


def run(output, projection='mercator'):
    if output.exists():
        raise ValueError('Use a new output directory')
    base, dock, lakes, flow = [json.loads(p.read_text()) for p in [BASE, DOCK, LAKES, FLOW]]
    # Check the saved input chain before changing any geometry.
    for record in [base, dock, lakes]:
        for path, expected in record['inputs'].items():
            if digest(Path(path)) != expected:
                raise ValueError(f'Baseline input changed: {path}')
    output.mkdir(parents=True)
    record = dict(projection=projection, complete=False, approved_for_production=False,
                  reference=str(REFERENCE), reference_cells_sha256=digest(REFERENCE/'cells.csv'),
                  records={str(p): digest(p) for p in [BASE, DOCK, LAKES, FLOW]},
                  script_sha256=digest(Path(__file__)))
    def save():
        (output/'comparison.json').write_text(json.dumps(record, indent=2)+'\n')
    save()
    try:
        prepare_flow.run(INPUTS, POLYGONS, output/'flow-input', mainland_only=True, projection=projection)
        # The external solver options are copied from the exact reference flow run.
        command = flow['stages'][0]['command'].copy()
        command[1:3] = [str((output/'flow-input'/name).resolve()) for name in ['geometry.geojson', 'areas.csv']]
        record['flow_command'] = command
        record['flow_binary_sha256'] = digest(Path(command[0]))
        flow_dir = output/'flow'
        flow_dir.mkdir()
        save()
        with (output/'flow.log').open('w') as stream:
            subprocess.run(command, cwd=flow_dir, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=660)
        settings = {k: base[k] for k in ['stretch', 'flow_guide_weight', 'sigma', 'iterations', 'flow_grid', 'flow_area_error',
                    'float_islands', 'dock_landmasses', 'borrow_coast', 'mainland_only', 'sites_in_flow',
                    'fixed_border_rounds', 'shared_islands', 'archipelagos', 'archipelago_gap_fraction',
                    'fixed_land_anchors', 'bridge_groups', 'water_radius', 'water_margin']}
        record['fit_settings'] = settings
        save()
        # All post-flow rules, source frames, templates, and population sites stay as in the reference.
        run_compact_pipeline.run(INPUTS, ROOT/'world-55000-shape-islands', POLYGONS, output/'margin-1',
                                 flow_geometry=flow_dir/'areas_cartogram.geojson', sites=Path(base['sites']), **settings)
        dock_settings = {k: dock[k] for k in ['max_tiles', 'radius', 'rounds', 'detached_only', 'coastal_islands_km']}
        dock_true_borders.run(INPUTS, output/'margin-1/layout', output/'rejoined', polygons=POLYGONS, **dock_settings)
        lake_settings = {k: lakes[k] for k in ['maximum_lakes', 'search_radius', 'placement_attempts', 'maximum_path_cost', 'path_attempts', 'bay_radius']}
        place_lake_regions.run(INPUTS, output/'rejoined', POLYGONS, ROOT/'geography-lake-guides-final',
                               ROOT/'geography-source-coasts-55000/source-coasts.csv', output/'local-lakes', **lake_settings)
        metrics = review_layout.run(INPUTS, output/'local-lakes', f'Margin-one with lakes: {projection} starting flow')
        subprocess.run(['rsvg-convert', str(output/'local-lakes/review.svg'), '-o', str(output/'local-lakes/review.png')], check=True)
        review_regions.run(INPUTS, output/'local-lakes', output/'regions')
        baseline = json.loads((REFERENCE/'metrics.json').read_text())
        keys = ['tiles', 'absolute_tile_error', 'disconnected_regions', 'missing_contacts', 'false_contacts', 'named_lakes', 'water_display_cells']
        record.update(complete=True, dock_settings=dock_settings, lake_settings=lake_settings,
                      comparison={k: dict(reference=baseline[k], candidate=metrics[k]) for k in keys},
                      cells_sha256=digest(output/'local-lakes/cells.csv'))
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        save()
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--projection', choices=['equal-earth', 'mercator'], default='mercator')
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
