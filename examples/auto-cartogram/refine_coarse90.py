#!/usr/bin/env python3
"""Test coastal island groups on the saved coarse 90% Kontur fit."""
import argparse
import json
from pathlib import Path
import subprocess

import audit_coarse90
import dock_true_borders
import place_coast_graph
import place_lake_regions
import restore_archipelagos
import review_layout
import review_regions
from run_margin1_projection import ROOT, INPUTS, POLYGONS, LAKES
from save_review import digest


def run(output, dock=False):
    parent = ROOT/'planet-kontur-coarse90'
    saved = json.loads((parent/'run.json').read_text())
    if not saved['complete'] or digest(parent/'layout/cells.csv') != saved['cells_sha256']:
        raise ValueError('Parent layout differs from its completed record')
    if output.exists():
        raise ValueError('Use a new output directory')
    output.mkdir(parents=True)
    record = dict(complete=False, approved=False, parent=str(parent), dock=dock,
                  inputs={str(p): digest(p) for p in [parent/'run.json', parent/'layout/cells.csv',
                      parent/'coast-islands/cells.csv', INPUTS/'groups.csv', INPUTS/'geographic-contacts.csv',
                      POLYGONS, LAKES]}, script_sha256=digest(Path(__file__)))
    try:
        island_input = parent/'coast-islands'
        if dock:
            dock_true_borders.run(INPUTS, parent/'docked', output/'rejoined', max_tiles=550,
                                  radius=64, detached_only=True, no_new_false=True)
            dock_true_borders.run(INPUTS, output/'rejoined', output/'borders', max_tiles=550,
                                  radius=64, no_new_false=True)
            place_coast_graph.run(INPUTS, output/'borders', POLYGONS, output/'coast-islands', preserve_order=True)
            island_input = output/'coast-islands'
        restore_archipelagos.run(INPUTS, island_input, POLYGONS, output/'islands',
                                  bridge_groups=True, coastal_groups=True)
        lakes = json.loads(LAKES.read_text())
        settings = {k: lakes[k] for k in ['maximum_lakes', 'search_radius', 'placement_attempts',
                                         'maximum_path_cost', 'path_attempts', 'bay_radius']}
        place_lake_regions.run(INPUTS, output/'islands', POLYGONS, ROOT/'geography-lake-guides-final',
            ROOT/'geography-source-coasts-55000/source-coasts.csv', output/'layout', **settings)
        record['metrics'] = review_layout.run(INPUTS, output/'layout', 'Coarse 90% Kontur: coastal island groups')
        subprocess.run(['rsvg-convert', str(output/'layout/review.svg'), '-o', str(output/'layout/review.png')], check=True)
        review_regions.run(INPUTS, output/'layout', output/'regions')
        audit_coarse90.run(parent, output/'baseline-audit')
        audit_coarse90.run(output, output/'audit')
        record.update(complete=True, cells_sha256=digest(output/'layout/cells.csv'))
    finally:
        (output/'run.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--dock', action='store_true')
    run(**vars(parser.parse_args()))
