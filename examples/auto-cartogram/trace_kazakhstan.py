#!/usr/bin/env python3
"""Trace mainland outlines through the saved margin-one pipeline without a refit."""
import argparse
import json
from pathlib import Path
import subprocess

import numpy as np
from shapely import affinity, box, union_all

from review_flow import read_shapes, draw
from review_layout import load, read_csv
from save_review import digest


def outline_error(geometry, native):
    scale = np.sqrt(geometry.area/native.area)
    guide = affinity.scale(native, scale, scale, origin=native.centroid)
    guide = affinity.translate(guide, geometry.centroid.x-guide.centroid.x,
                               geometry.centroid.y-guide.centroid.y)
    return 1-geometry.intersection(guide).area/geometry.union(guide).area


def run(root, output):
    if output.exists():
        raise ValueError('Use a new output directory')
    inputs = root/'world-55000-dissolved-input'
    pipeline = root/'geography-water-trials/margin-1'
    groups = {r['component_id']: r for r in read_csv(inputs/'groups.csv') if int(r['tiles']) > 0}
    countries = 'RUS CHN IND KAZ KGZ UZB TKM TJK AFG PAK IRN AZE MNG NPL BTN BGD MMR PRK KOR'.split()
    main = {c: max((k for k in groups if groups[k]['country_id'] == c), key=lambda k: int(groups[k]['tiles'])) for c in countries}
    source_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    flow_path = root/'world-55000-mainland-flow/flow/areas_cartogram.geojson'
    source, flow = read_shapes(source_path), read_shapes(flow_path)
    record_path = pipeline/'partition/partition.json'
    record = json.loads(record_path.read_text())
    stages = [('01-source', source, source_path), ('02-continuous-flow', flow, flow_path),
              ('03-stretched-flow', {c: affinity.scale(g, record['flow']['x_scale'], record['flow']['y_scale'], origin=(0, 0)) for c, g in flow.items()}, record_path)]
    for name, folder in [('04-partition', pipeline/'partition'), ('05-repaired', pipeline/'repaired'),
                         ('06-margin-one', pipeline/'layout'), ('07-docked', root/'geography-margin1-rejoined-final'),
                         ('08-islands-lakes', root/'geography-islands-lakes-integrated')]:
        _, tiles, _ = load(inputs, folder)
        geometries = {}
        for c in main.values():
            xy = np.array(sorted(tiles[c]))
            geometries[c] = union_all(box(xy[:, 0]-.5, xy[:, 1]-.5, xy[:, 0]+.5, xy[:, 1]+.5))
        stages.append((name, geometries, folder/'cells.csv'))
    output.mkdir(parents=True)
    report = dict(stages=[], inputs={str(inputs/'groups.csv'): digest(inputs/'groups.csv')},
                  limits=['No fitting or layout changes. These are saved stages of one pipeline, not causal ablations.',
                          'Panels show selected mainland components only, each scaled to fit. Omitted countries are not water.',
                          'Outline error uses equal-area scaling and centroid alignment without rotation.',
                          'Bounding-box aspect is width divided by height. It does not by itself measure a pinch point.'])
    for name, geometries, path in stages:
        selected = {c: geometries[c] for c in main.values()}
        draw(output/(name+'.svg'), selected, groups, name.replace('-', ' '),
             'Selected mainland parts only; other countries omitted. Each panel is scaled to fit.', method='Saved-stage diagnostic; no new fit.')
        svg = output/(name+'.svg')
        svg.write_text(svg.read_text().replace('Continuous deformation of separate components. Not yet a square-tile layout. Not a production map.',
                                              'Saved-stage comparison: source, continuous outlines, then tile boundaries. Not a new layout.'))
        subprocess.run(['rsvg-convert', str(svg), '-o', str(output/(name+'.png'))], check=True)
        rows = []
        for country, c in main.items():
            g = selected[c]
            x0, y0, x1, y1 = g.bounds
            rows.append(dict(country=country, area=g.area, centroid=[g.centroid.x, g.centroid.y],
                             aspect=(x1-x0)/(y1-y0), outline_error=outline_error(g, source[c])))
        report['stages'].append(dict(name=name, records=rows))
        report['inputs'][str(path)] = digest(path)
    processed_path = root/'world-55000-mainland-flow/flow/areas_input_processed.geojson'
    processed = read_shapes(processed_path)
    report['preprocessed_outline_error'] = {c: outline_error(processed[k], source[k]) for c, k in main.items()}
    report['inputs'][str(processed_path)] = digest(processed_path)
    total_area = sum(g.area for g in source.values())
    total_tiles = sum(int(groups[c]['tiles']) for c in source)
    report['area_pressure'] = [dict(country=c, tiles=int(groups[k]['tiles']),
        target_share_over_source_area_share=(int(groups[k]['tiles'])/total_tiles)/(source[k].area/total_area)) for c, k in main.items()]
    site_path = Path(record['sites'])
    sites = {r['component_id']: np.array([float(r['x']), float(r['y'])]) for r in read_csv(site_path)}
    report['partition_sites'] = []
    for country, c in main.items():
        site = sites[c]*record['guide_alignment']['scale']+record['guide_alignment']['translation']
        g = stages[2][1][c]
        centre = np.array([g.centroid.x, g.centroid.y])
        report['partition_sites'].append(dict(country=country, flow_centroid=centre.tolist(),
            fitted_unwarped_site=site.tolist(), displacement_tiles=float(np.linalg.norm(site-centre))))
    report['inputs'][str(site_path)] = digest(site_path)
    swaps_path = pipeline/'repaired/swaps.json'
    swaps = json.loads(swaps_path.read_text())
    involved = [r for r in swaps if main['KAZ'] in (r['component'], r['other'])]
    report['kazakhstan_repair'] = dict(swap_count=len(involved),
        initiating_components=sorted({r['component'] for r in involved}),
        first_swap=involved[0] if involved else None)
    report['inputs'][str(swaps_path)] = digest(swaps_path)
    report['script_sha256'] = digest(Path(__file__))
    (output/'trace.json').write_text(json.dumps(report, indent=2)+'\n')
    return {s['name']: {r['country']: round(r['outline_error'], 4) for r in s['records'] if r['country'] in ['RUS', 'CHN', 'IND', 'KAZ']} for s in report['stages']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
