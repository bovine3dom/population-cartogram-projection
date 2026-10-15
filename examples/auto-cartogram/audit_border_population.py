#!/usr/bin/env python3
"""Measure population beside physical borders before testing selective separation."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from shapely import affinity, get_parts, points, distance, line_merge
from shapely.geometry import shape

from review_layout import read_csv
from save_review import digest


def measure(border, land, xy, population, width, spacing):
    """Use an equal-area kilometre plane; centre samples are not a census strip."""
    if border.length <= 0:
        return None
    strip = border.buffer(width).intersection(land)
    if strip.area <= 0:
        return None
    samples, lengths = [], []
    for part in get_parts(line_merge(border)):
        if part.length <= 0:
            continue
        n = max(1, int(np.ceil(part.length/spacing)))
        for i in range(n):
            samples.append(part.interpolate((i+.5)*part.length/n).coords[0])
            lengths.append(part.length/n)
    near = distance(points(xy), border) <= width
    mass = population[near]
    bins = cKDTree(samples).query(xy[near])[1]
    totals = np.bincount(bins, weights=mass, minlength=len(samples))
    # Allocate corridor area in proportion to sampled border length.
    densities = totals/(strip.area*np.array(lengths)/sum(lengths))
    order = np.argsort(densities)
    cumulative = np.cumsum(np.array(lengths)[order])/sum(lengths)
    p90 = float(densities[order[np.searchsorted(cumulative, .9)]])
    return dict(length_km=border.length, corridor_area_km2=strip.area,
                corridor_population=float(mass.sum()), mean_density=float(mass.sum()/strip.area),
                p90_segment_density=p90, maximum_segment_density=float(densities.max()),
                source_centres=int(near.sum()), segments=len(samples))


def run(inputs, sources, guides, output, width=25., spacing=25., mean_limit=10., p90_limit=25.):
    if output.exists() or not np.isfinite([width, spacing, mean_limit, p90_limit]).all() or min(width, spacing) <= 0 or min(mean_limit, p90_limit) < 0:
        raise ValueError('Use a new output and valid settings')
    groups = {r['component_id']: r for r in read_csv(inputs/'groups.csv') if int(r['tiles']) > 0}
    features = json.loads((guides/'geometry.geojson').read_text())['features']
    land = {f['properties']['component_id']: affinity.scale(shape(f['geometry']), 6.371, 6.371, origin=(0, 0))
            for f in features if f['properties']['feature_kind'] == 'land'}
    if set(land) != set(groups):
        raise ValueError('Lake-aware guide labels differ')
    sites = defaultdict(list)
    ids = set()
    for r in read_csv(sources):
        if r['id'] in ids or r['group_id'] not in groups:
            raise ValueError('Duplicate source or unknown group')
        ids.add(r['id'])
        # Source CSV uses Equal Earth with radius one; guides use radius 1000.
        sites[r['group_id']].append((float(r['x'])*6371, float(r['y'])*6371, float(r['value'])))
    sites = {c: np.array(p) for c, p in sites.items()}
    if set(sites) != set(groups) or any(not np.isfinite(p).all() or np.any(p[:, 2] <= 0) or
            not np.isclose(p[:, 2].sum(), float(groups[c]['group_population']), rtol=0, atol=.01) for c, p in sites.items()):
        raise ValueError('Source population or coordinates do not match groups')
    required = sorted({tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'})
    records = []
    for a, b in required:
        border = land[a].boundary.intersection(land[b].boundary)
        lines = [p for p in get_parts(border) if p.geom_type in ('LineString', 'MultiLineString')]
        from shapely import union_all
        border = union_all(lines)
        data = np.concatenate((sites[a], sites[b]))
        measured = measure(border, land[a].union(land[b]), data[:, :2], data[:, 2], width, spacing)
        row = dict(a=a, b=b, countries=groups[a]['country_id']+'–'+groups[b]['country_id'], eligible=False)
        if measured is None:
            row['reason'] = 'No measurable physical shared border; do not infer sparse population'
        else:
            row.update(measured)
            row['eligible'] = measured['mean_density'] <= mean_limit and measured['p90_segment_density'] <= p90_limit
            row['reason'] = 'Below both density limits' if row['eligible'] else 'Above a density limit'
        records.append(row)
    output.mkdir(parents=True)
    report = dict(width_km=width, segment_spacing_km=spacing, mean_density_limit=mean_limit, p90_density_limit=p90_limit,
        borders=records, eligible_borders=sum(r['eligible'] for r in records), source_centres=len(ids),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', sources, guides/'geometry.geojson']},
        script_sha256=digest(Path(__file__)),
        limits=['Density is people per square kilometre in a two-sided border corridor, not a country average.',
                'Equal Earth preserves area, not distance. Widths and lengths are projected approximations, especially at high latitude.',
                'H3-5 sources place each cell population at its centre. Corridor edges and short borders have sampling error.',
                'Segment density uses corridor area apportioned by length. The 90th percentile can miss a short dense settlement.',
                'Eligibility permits an experiment; it does not require separation or approve a layout. No named-country overrides.'])
    (output/'border-population.json').write_text(json.dumps(report, indent=2)+'\n')
    fields = sorted({k for r in records for k in r})
    with (output/'border-population.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows(records)
    return dict(borders=len(records), eligible_borders=report['eligible_borders'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'sources', 'guides', 'output']:
        parser.add_argument(name, type=Path)
    for name, default in [('width', 25.), ('spacing', 25.), ('mean-limit', 10.), ('p90-limit', 25.)]:
        parser.add_argument('--'+name, type=float, default=default)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
