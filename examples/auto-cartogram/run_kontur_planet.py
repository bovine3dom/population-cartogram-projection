#!/usr/bin/env python3
"""Fit the saved coarse 90% Kontur guide to exact planet tile budgets."""
import argparse
import json
from pathlib import Path
import subprocess

from shapely import union_all
from shapely.geometry import mapping

import dock_true_borders
import place_coast_graph
import place_lake_regions
import restore_archipelagos
import review_geography
import review_layout
import review_regions
import run_compact_pipeline
from review_flow import read_shapes
from run_margin1_projection import ROOT, INPUTS, POLYGONS, BASE, DOCK, LAKES
from save_review import digest


def clean_overlaps(shapes, maximum_share=1e-6):
    """Remove only tiny numeric overlaps; do not accept split or missing regions."""
    result, records = {}, []
    total = sum(g.area for g in shapes.values())
    for c in sorted(shapes, key=lambda c: (shapes[c].area, c)):
        g = shapes[c]
        others = [h for h in result.values() if g.intersects(h)]
        clean = g.difference(union_all(others)) if others else g
        lost = g.area-clean.area
        if lost > maximum_share*total or lost > .001*g.area:
            raise ValueError('Overlap exceeds numeric cleanup limit')
        if clean.geom_type != 'Polygon' or clean.is_empty or not clean.is_valid:
            raise ValueError('Overlap cleanup split or invalidated a component')
        result[c] = clean
        if lost > 0:
            records.append(dict(component=c, removed_area=lost, component_share=lost/g.area))
    if sum(r['removed_area'] for r in records) > maximum_share*total:
        raise ValueError('Total overlap exceeds numeric cleanup limit')
    return result, records


def run(output, legacy_centres=False, guide=None, guide_record=None, inputs=INPUTS):
    if output.exists():
        raise ValueError('Use a new output directory')
    cuts = []
    if guide is None:
        guide_root = ROOT/'kontur-patch-flow-200-floor'
        guide = guide_root/'blend-0.9/components.geojson'
        guide_record = guide_root/'experiment.json'
        selected = next(r for r in json.loads(guide_record.read_text())['runs'] if r['strength'] == .9)
        if not selected['solver_success'] or digest(guide) != selected['geometry_sha256']:
            raise ValueError('Saved Kontur guide is not verified')
    else:
        if guide_record is None:
            raise ValueError('A custom guide needs its source record')
        selected = json.loads(guide_record.read_text())
        if digest(guide) != selected['geometry_sha256'] or selected['inputs'].get(str(inputs/'geographic-contacts.csv')) != digest(inputs/'geographic-contacts.csv'):
            raise ValueError('Custom guide or cut contact policy differs')
        if any(digest(Path(p)) != expected for p,expected in selected['inputs'].items()):
            raise ValueError('Custom guide inputs differ')
        cuts = selected['cuts']
    base, dock, lakes = [json.loads(p.read_text()) for p in [BASE, DOCK, LAKES]]
    settings = {k: base[k] for k in ['stretch', 'flow_guide_weight', 'sigma', 'iterations', 'flow_grid', 'flow_area_error',
        'float_islands', 'dock_landmasses', 'borrow_coast', 'mainland_only', 'sites_in_flow', 'fixed_border_rounds',
        'shared_islands', 'archipelagos', 'archipelago_gap_fraction', 'fixed_land_anchors', 'bridge_groups', 'water_radius', 'water_margin']}
    settings['flow_centres'] = not legacy_centres
    cleaned, changes = clean_overlaps(read_shapes(guide))
    output.mkdir(parents=True)
    clean_path = output/'guide.geojson'
    clean_path.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g)) for c,g in sorted(cleaned.items())]), separators=(',', ':'))+'\n')
    record = dict(complete=False, approved=False, cuts=cuts, settings=settings, overlap_cleanup=changes,
        inputs={str(p): digest(p) for p in [BASE, DOCK, LAKES, guide, guide_record, clean_path, inputs/'geographic-contacts.csv']},
        script_sha256=digest(Path(__file__)),
        limits=['Research candidate only. Cut pairs, if any, are explicit and use a separate contact policy.',
                'Flow centres retain the selected guide. The legacy option uses unwarped population centres.',
                'Island coast placement uses geometric frames, not the old layout population mapping.',
                'Lakes are inserted as empty cells. The number placed can differ from the preferred baseline.',
                'The continuous guide has approximate areas; the tile fit uses the original exact component budgets.'])
    def save():
        (output/'run.json').write_text(json.dumps(record, indent=2)+'\n')
    save()
    try:
        run_compact_pipeline.run(inputs, ROOT/'world-55000-shape-islands', POLYGONS, output/'fit',
                                 flow_geometry=clean_path, sites=Path(base['sites']), **settings)
        dock_settings = {k: dock[k] for k in ['max_tiles', 'radius', 'rounds', 'detached_only', 'coastal_islands_km']}
        dock_true_borders.run(inputs, output/'fit/layout', output/'docked', polygons=POLYGONS, **dock_settings)
        place_coast_graph.run(inputs, output/'docked', POLYGONS, output/'coast-islands', preserve_order=True)
        restore_archipelagos.run(inputs, output/'coast-islands', POLYGONS, output/'islands', bridge_groups=True)
        lake_settings = {k: lakes[k] for k in ['maximum_lakes', 'search_radius', 'placement_attempts', 'maximum_path_cost', 'path_attempts', 'bay_radius']}
        place_lake_regions.run(inputs, output/'islands', POLYGONS, ROOT/'geography-lake-guides-final',
                              ROOT/'geography-source-coasts-55000/source-coasts.csv', output/'layout', **lake_settings)
        record['metrics'] = review_layout.run(inputs, output/'layout', f'Planet: coarse 90% Kontur, 55,000 tiles; {len(cuts)} strategic cuts')
        subprocess.run(['rsvg-convert', str(output/'layout/review.svg'), '-o', str(output/'layout/review.png')], check=True)
        review_regions.run(inputs, output/'layout', output/'regions')
        review_geography.run(inputs, output/'layout', POLYGONS, output/'geography')
        record.update(complete=True, cells_sha256=digest(output/'layout/cells.csv'))
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        save()
    return record['metrics']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--legacy-centres', action='store_true')
    parser.add_argument('--guide',type=Path)
    parser.add_argument('--guide-record',type=Path)
    parser.add_argument('--inputs',type=Path,default=INPUTS)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
