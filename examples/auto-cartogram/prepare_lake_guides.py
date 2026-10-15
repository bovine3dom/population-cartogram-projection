#!/usr/bin/env python3
"""Audit explicit lakes and prepare separate land and water flow-guide regions."""
import argparse
import csv
import html
import json
import math
from pathlib import Path

from shapely import STRtree, transform, union_all, make_valid, get_parts
from shapely.geometry import shape, mapping, box

from prepare_flow import equal_earth
from review_layout import read_csv
from save_review import digest


LAKES_URL = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_lakes.geojson'


def measure_lake(lake, land, labels, tree, budgets):
    intersections = [(int(i), land[int(i)].intersection(lake)) for i in tree.query(lake, predicate='intersects')]
    intersections = [(i, g) for i, g in intersections if g.area > 0]
    covered = union_all([g for _, g in intersections]).area/lake.area
    # This is a display-area estimate, not population assigned to water.
    estimate = sum(g.area/land[i].area*budgets.get(labels[i], 0) for i, g in intersections)
    members = [labels[i] for i, g in intersections if g.area/lake.area > .001]
    return covered, estimate, sorted(members)


def source_review(path, land, lakes, bounds):
    clip = transform(box(*bounds), equal_earth)
    xmin, ymin, xmax, ymax = clip.bounds
    width, height = xmax-xmin, ymax-ymin
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{xmin} {-ymax} {width} {height}">',
             '<rect x="-4000" y="-2000" width="8000" height="4000" fill="#faf9f6"/>', '<g transform="scale(1,-1)">']
    for g in land:
        if g.intersects(clip):
            parts.append(g.intersection(clip).svg(scale_factor=.15, fill_color='#ddd5bb', opacity=1))
    for name, g in lakes:
        if g.intersects(clip):
            parts.append(g.intersection(clip).svg(scale_factor=.15, fill_color='#77bde8', opacity=1))
    parts.append('</g>')
    for name, g in lakes:
        if clip.contains(g.representative_point()):
            p = g.representative_point()
            parts.append(f'<text x="{p.x}" y="{-p.y}" font-size="4.5" text-anchor="middle">{html.escape(name)}</text>')
    parts.append('</svg>')
    path.write_text('\n'.join(parts)+'\n')


def run(inputs, polygons, lakes, output, minimum_area_km2=1000., minimum_tiles=1.):
    if output.exists() or not all(math.isfinite(v) and v > 0 for v in [minimum_area_km2, minimum_tiles]):
        raise ValueError('Use a new output and positive thresholds')
    budgets = {r['component_id']: int(r['tiles']) for r in read_csv(inputs/'groups.csv')}
    features = json.loads(polygons.read_text())['features']
    labels = [f['properties']['component_id'] for f in features]
    land = [transform(shape(f['geometry']), equal_earth) for f in features]
    if len(set(labels)) != len(labels) or not set(budgets) <= set(labels):
        raise ValueError('Invalid source labels')
    tree = STRtree(land)
    records, selected, repaired = [], [], []
    lake_features = json.loads(lakes.read_text())['features']
    seen = set()
    for index, f in enumerate(lake_features):
        lake = transform(shape(f['geometry']), equal_earth)
        identifier = 'water:'+str(f['properties'].get('ne_id', index))
        if not lake.is_valid:
            lake = union_all([g for g in get_parts(make_valid(lake)) if g.geom_type in ['Polygon', 'MultiPolygon']])
            repaired.append(identifier)
        if lake.is_empty or not lake.is_valid or lake.area <= 0:
            raise ValueError('Invalid lake geometry: '+identifier)
        if identifier in seen:
            raise ValueError('Duplicate lake ID')
        seen.add(identifier)
        name = f['properties'].get('name') or identifier
        covered, estimate, members = measure_lake(lake, land, labels, tree, budgets)
        area = lake.area*(6371/1000)**2
        use = area >= minimum_area_km2 and estimate >= minimum_tiles and covered >= .95
        records.append(dict(lake_id=identifier, name=name, area_km2=area,
            administrative_coverage_fraction=covered, estimated_water_tiles=estimate,
            guide_selected=use, components=';'.join(members)))
        if use:
            selected.append((identifier, name, lake, max(1, round(estimate))))
    water = union_all([g for _, _, g, _ in selected])
    if abs(water.area-sum(g.area for _, _, g, _ in selected)) > max(1e-8, water.area*1e-7):
        raise ValueError('Selected lakes overlap')
    guide_features, areas, cut_land = [], [], []
    cut_by_id = {}
    split = []
    for c, f, g in zip(labels, features, land):
        if not budgets.get(c):
            continue
        cut = g.difference(water)
        if cut.is_empty or not cut.is_valid or cut.geom_type not in ['Polygon', 'MultiPolygon']:
            raise ValueError('Lake subtraction removed or invalidated '+c)
        if cut.geom_type == 'MultiPolygon':
            split.append(c)
        cut_land.append(cut)
        cut_by_id[c] = cut
        guide_features.append(dict(type='Feature', properties=dict(component_id=c, name=f['properties'].get('name', c), feature_kind='land'), geometry=mapping(cut)))
        areas.append((c, budgets[c]))
    for c, name, g, count in selected:
        guide_features.append(dict(type='Feature', properties=dict(component_id=c, name=name, feature_kind='water'), geometry=mapping(g)))
        areas.append((c, count))
    original = dict(zip(labels, land))
    separated_contacts = []
    for r in read_csv(inputs/'geographic-contacts.csv'):
        if r['both_represented'] != 'true':
            continue
        a, b = r['a'], r['b']
        before, after = original[a].distance(original[b]), cut_by_id[a].distance(cut_by_id[b])
        if before <= .001 and after > .001:
            separated_contacts.append(dict(a=a, b=b, gap_km=after*6371/1000))
    output.mkdir(parents=True)
    with (output/'lake-audit.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    with (output/'areas.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'tiles'])
        writer.writerows(areas)
    (output/'geometry.geojson').write_text(json.dumps(dict(type='FeatureCollection', features=guide_features), separators=(',', ':'))+'\n')
    report = dict(source_lakes=len(records), selected_lakes=len(selected), repaired_lakes=repaired,
        minimum_area_km2=minimum_area_km2, minimum_tiles=minimum_tiles,
        land_tiles=sum(budgets.values()), water_guide_tiles=sum(n for _, _, _, n in selected),
        split_guide_components=split, lake_separated_contacts=separated_contacts,
        contact_distance_tolerance_km=.001*6371/1000,
        large_lakes_covered_by_admin=sum(r['area_km2'] >= minimum_area_km2 and r['administrative_coverage_fraction'] >= .95 for r in records),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', polygons, lakes]},
        script_sha256=digest(Path(__file__)), lake_source_url=LAKES_URL,
        documentation_url='https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-lakes/',
        limits=['This prepares flow guides. It does not change the tile layout or any population export.',
                'Water guide areas estimate local display scale from administrative area and component tile budgets. Water has no population budget.',
                'Administrative borders through lakes are not physical land contacts. Subtraction can make a guide component multipart.',
                'Lake islands need separate population-component checks before these guides can enter a production mapping.',
                'Lakes below the thresholds and lakes already outside administrative polygons are audited but not added to the guide.',
                'Area estimates use a spherical Equal Earth projection. Seasonal and reservoir extents follow the source dataset.'])
    (output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    source_review(output/'east-africa-source.svg', cut_land, [(name, g) for _, name, g, _ in selected], (20, -18, 44, 8))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'polygons', 'lakes', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--minimum-area-km2', type=float, default=1000.)
    parser.add_argument('--minimum-tiles', type=float, default=1.)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
