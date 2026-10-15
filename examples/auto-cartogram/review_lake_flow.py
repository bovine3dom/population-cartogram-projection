#!/usr/bin/env python3
"""Check and render continuous guides with explicit water regions."""
import argparse
import json
from pathlib import Path

from shapely import STRtree, make_valid, is_valid_reason, get_parts, union_all
from shapely.geometry import shape

from review_flow import draw
from review_layout import read_csv
from save_review import digest


def run(inputs, guides, geometry, output, allow_invalid_review=False):
    if output.exists():
        raise ValueError('Use a new output')
    groups = {r['component_id']: r for r in read_csv(inputs/'groups.csv')}
    requested = {r['component_id']: float(r['tiles']) for r in read_csv(guides/'areas.csv')}
    source = {f['properties']['component_id']: f for f in json.loads((guides/'geometry.geojson').read_text())['features']}
    features = json.loads(geometry.read_text())['features']
    shapes = {f['properties']['component_id']: shape(f['geometry']) for f in features}
    if len(shapes) != len(features) or set(shapes) != set(requested) or set(source) != set(shapes):
        raise ValueError('Flow labels differ')
    invalid = {c: is_valid_reason(g) for c, g in shapes.items() if not g.is_valid}
    if invalid and not allow_invalid_review:
        raise ValueError('Invalid flow geometry; use --allow-invalid-review only for diagnostic images')
    for c in invalid:
        shapes[c] = union_all([g for g in get_parts(make_valid(shapes[c])) if g.geom_type in ['Polygon', 'MultiPolygon']])
    if any(g.is_empty or g.geom_type not in ['Polygon', 'MultiPolygon'] for g in shapes.values()):
        raise ValueError('Empty or unsupported flow geometry')
    water = {c for c, f in source.items() if f['properties']['feature_kind'] == 'water'}
    for c in water:
        groups[c] = dict(country_id=c, fill='#77bde8', label=source[c]['properties']['name'])
    total = sum(g.area for g in shapes.values())
    scale = sum(requested.values())/total
    errors = {c: shapes[c].area*scale/requested[c]-1 for c in shapes}
    labels = sorted(shapes)
    geometries = [shapes[c] for c in labels]
    tree = STRtree(geometries)
    overlaps = []
    for i, g in enumerate(geometries):
        for j in tree.query(g, predicate='intersects'):
            if j <= i:
                continue
            area = g.intersection(geometries[j]).area
            if area > total*1e-12:
                overlaps.append(dict(a=labels[i], b=labels[j], equivalent_tiles=area*scale))
    report = dict(land_components=len(shapes)-len(water), water_regions=len(water), invalid_source_geometries=invalid,
        diagnostic_repairs=bool(invalid), approved=False,
        requested_land_tiles=sum(requested[c] for c in shapes if c not in water),
        requested_water_guide_tiles=sum(requested[c] for c in water),
        maximum_relative_area_error=max(map(abs, errors.values())),
        lake_relative_area_errors={groups[c]['label']: errors[c] for c in sorted(water)},
        overlap_pairs=len(overlaps), overlaps=overlaps,
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', guides/'areas.csv', guides/'geometry.geojson', geometry]},
        scripts={p.name: digest(p) for p in [Path(__file__), Path(__file__).with_name('review_flow.py')]},
        limits=['Continuous geometry only. No integer tile layout or population mapping is generated.',
                'If diagnostic repairs are enabled, measurements and images use make_valid. This does not validate the original solver output.',
                'Multipart land guides can include lake islands. Population components still need a separate review.',
                'This is a separate experiment. It does not replace the preferred margin-one footprint.'])
    output.mkdir(parents=True)
    (output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    caption = f'{len(water)} water regions; maximum area error {report["maximum_relative_area_error"]:.2%}; {len(overlaps)} overlap pairs; {len(invalid)} invalid solver geometries. Water is blue.'
    draw(output/'world.svg', shapes, groups, 'Explicit lake regions: continuous guide', caption)
    # Region selection is for review only, not a country-specific layout rule.
    selected = {c for c, r in groups.items() if c in shapes and c not in water and 20 <= (float(r['west'])+float(r['east']))/2 <= 44 and -18 <= (float(r['south'])+float(r['north']))/2 <= 8}
    if selected:
        source_tree = STRtree([shape(source[c]['geometry']) for c in sorted(selected)])
        selected |= {c for c in water if len(source_tree.query(shape(source[c]['geometry']), predicate='intersects'))}
        draw(output/'east-africa.svg', {c: shapes[c] for c in selected}, groups, 'East Africa: explicit lakes in the continuous guide', caption)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'guides', 'geometry', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--allow-invalid-review', action='store_true')
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
