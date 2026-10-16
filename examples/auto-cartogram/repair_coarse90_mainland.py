#!/usr/bin/env python3
"""Repeat downstream fitting with source-border fragment selection."""
import argparse
import json
from pathlib import Path
import subprocess

import audit_coarse90
import compact_regions
import dock_true_borders
import place_coast_graph
import place_islands
import place_lake_regions
import repair_partition
import restore_archipelagos
import restore_shared_islands
import review_layout
import review_regions
from run_margin1_projection import ROOT, INPUTS, POLYGONS, LAKES
from save_review import digest


def run(output, partition=None, fit_islands=None):
    parent = ROOT/'planet-kontur-coarse90'
    partition = partition or parent/'fit/partition'
    if output.exists():
        raise ValueError('Use a new output directory')
    output.mkdir(parents=True)
    base = json.loads((parent/'fit/pipeline.json').read_text())
    record = dict(complete=False, approved=False, partition=str(partition),
                  inputs={str(p):digest(p) for p in [partition/'cells.csv', parent/'fit/pipeline.json',
                      INPUTS/'groups.csv', INPUTS/'geographic-contacts.csv', POLYGONS, LAKES]},
                  scripts={p.name:digest(p) for p in Path(__file__).parent.glob('*.py')})
    try:
        if fit_islands is None:
            repair_partition.run(INPUTS, partition, output/'repaired', relocate_fragments=True,
                                 borrow_coast=base['borrow_coast'], prefer_true_borders=True)
            place_islands.run(INPUTS, output/'repaired', POLYGONS, output/'initial-islands', preserve_mainland_defects=True)
            compact_regions.run(INPUTS, output/'initial-islands', output/'border', rounds=base['fixed_border_rounds'],
                perimeter=1, false_contact=16, guide=0, anchor=1, choices=16, fixed_footprint=True, land_only=True)
            restore_shared_islands.run(INPUTS, output/'border', parent/'fit/flow-input/geometry.geojson', output/'shared')
            place_islands.run(INPUTS, output/'shared', POLYGONS, output/'fixed-coast', preserve_mainland_defects=True, fixed_land_anchors=True)
            restore_archipelagos.run(INPUTS, output/'fixed-coast', POLYGONS, output/'fit-islands', bridge_groups=True, coastal_groups=True)
            fit_islands=output/'fit-islands'
        else:
            saved=json.loads((fit_islands/'archipelagos.json').read_text())
            if saved['cells_sha256']!=digest(fit_islands/'cells.csv') or any(digest(Path(p))!=h for p,h in saved['inputs'].items()):
                raise ValueError('Saved island fit or inputs differ')
            record['inputs'].update({str(p):digest(p) for p in [fit_islands/'cells.csv',fit_islands/'archipelagos.json']})
        dock_true_borders.run(INPUTS, fit_islands, output/'continent-dock', max_tiles=10000,
                             radius=64, detached_only=True, no_new_false=True, polygons=POLYGONS)
        dock_true_borders.run(INPUTS, output/'continent-dock', output/'docked', max_tiles=550,
                             radius=64, detached_only=True, no_new_false=True)
        place_coast_graph.run(INPUTS, output/'docked', POLYGONS, output/'coast-islands', preserve_order=True)
        restore_archipelagos.run(INPUTS, output/'coast-islands', POLYGONS, output/'islands', bridge_groups=True, coastal_groups=True)
        lakes = json.loads(LAKES.read_text())
        settings = {k:lakes[k] for k in ['maximum_lakes','search_radius','placement_attempts','maximum_path_cost','path_attempts','bay_radius']}
        place_lake_regions.run(INPUTS, output/'islands', POLYGONS, ROOT/'geography-lake-guides-final',
            ROOT/'geography-source-coasts-55000/source-coasts.csv', output/'layout', **settings)
        record['metrics'] = review_layout.run(INPUTS, output/'layout', 'Coarse90: source-border fragment selection')
        subprocess.run(['rsvg-convert', str(output/'layout/review.svg'), '-o', str(output/'layout/review.png')], check=True)
        review_regions.run(INPUTS, output/'layout', output/'regions')
        audit_coarse90.run(output, output/'audit')
        record.update(complete=True, cells_sha256=digest(output/'layout/cells.csv'))
    finally:
        (output/'run.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--partition', type=Path)
    parser.add_argument('--fit-islands', type=Path, help='Reuse a checked intermediate island fit')
    run(**vars(parser.parse_args()))
