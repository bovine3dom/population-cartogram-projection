#!/usr/bin/env python3
"""Open audited sparse borders in source geometry before population flow fitting."""
import argparse
import json
import math
from pathlib import Path

from shapely import STRtree, union_all
from shapely.geometry import mapping

from review_flow import read_shapes
from review_layout import read_csv
from save_review import digest


def contact_pairs(shapes):
    labels = sorted(shapes)
    geometries = [shapes[c] for c in labels]
    tree = STRtree(geometries)
    return {(labels[i], labels[j]) for i, g in enumerate(geometries)
            for j in tree.query(g, predicate='intersects') if j > i
            and g.boundary.intersection(geometries[j].boundary).length > 1e-8}


def open_seams(shapes, selected, width, maximum_area_loss=.1, maximum_fragment_loss=0.):
    if (not math.isfinite(width) or not 0 < width or not 0 < maximum_area_loss < 1
            or not 0 <= maximum_fragment_loss < maximum_area_loss):
        raise ValueError('Use positive width and an area-loss limit below one')
    before = contact_pairs(shapes)
    if not selected <= before:
        raise ValueError('Selected border has no shared source edge')
    cuts = {c: [] for c in shapes}
    for a, b in sorted(selected):
        seam = shapes[a].boundary.intersection(shapes[b].boundary).buffer(width/2)
        cuts[a].append(seam)
        cuts[b].append(seam)
    result, removed = {}, []
    for c, g in shapes.items():
        changed = g.difference(union_all(cuts[c])) if cuts[c] else g
        fragments = 0.
        if changed.geom_type == 'MultiPolygon':
            largest = max(changed.geoms, key=lambda p: p.area)
            fragments = (changed.area-largest.area)/g.area
            if fragments <= maximum_fragment_loss:
                changed = largest
        loss = 1-changed.area/g.area
        if changed.geom_type != 'Polygon' or changed.is_empty or not changed.is_valid:
            raise ValueError(f'Seam splits or invalidates component {c}')
        if loss > maximum_area_loss:
            raise ValueError(f'Seam removes too much source area from {c}')
        result[c] = changed
        if loss > 0:
            removed.append(dict(component=c, source_area_fraction=loss, fragment_area_fraction=fragments))
    after = contact_pairs(result)
    lost = before-after
    if lost-selected:
        raise ValueError('Seam also removes an unselected contact: '+str(sorted(lost-selected)))
    if not selected <= lost or after-before:
        raise ValueError('Selected cuts did not open, or a new contact formed')
    return result, removed


def run(root, output, pair, width_km=25., maximum_fragment_loss=0.):
    if output.exists():
        raise ValueError('Use a new output directory')
    inputs = root/'world-55000-dissolved-input'
    source = root/'world-55000-mainland-flow/input/geometry.geojson'
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    audit = json.loads(audit_path.read_text())
    for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if audit['inputs'].get(str(p)) != digest(p):
            raise ValueError('Population audit inputs differ')
    shapes = read_shapes(source)
    rows = {r['component_id']: r for r in read_csv(inputs/'groups.csv') if r['component_id'] in shapes}
    main = lambda code: max((c for c in rows if rows[c]['country_id'] == code), key=lambda c: int(rows[c]['tiles']))
    selected = {tuple(sorted(main(code) for code in p.split(':'))) for p in pair}
    if any(len(p) != 2 or p[0] == p[1] for p in selected):
        raise ValueError('Use pairs of distinct country codes')
    eligible = {tuple(sorted((b['a'], b['b']))): b for b in audit['borders'] if b['eligible']}
    if not selected <= eligible.keys():
        raise ValueError('Every cut must pass both population-density limits')
    result, removed = open_seams(shapes, selected, width_km/6.371, maximum_fragment_loss=maximum_fragment_loss)
    output.mkdir(parents=True)
    geometry = output/'geometry.geojson'
    geometry.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g)) for c,g in sorted(result.items())]), separators=(',', ':'))+'\n')
    report = dict(width_km=width_km, maximum_fragment_loss=maximum_fragment_loss, cuts=sorted(selected), removed=removed,
                  eligible_borders=[eligible[p] for p in sorted(selected)],
                  geometry_sha256=digest(geometry), script_sha256=digest(Path(__file__)),
                  inputs={str(p): digest(p) for p in [source, audit_path, inputs/'groups.csv', inputs/'geographic-contacts.csv']},
                  limits=['Artificial source-space seams, not real seas. Widths are Equal Earth approximations.',
                          'All output source components stay connected. Small fragments may be removed only within the explicit area limit. No unselected source contact may disappear.',
                          'This changes source geometry only, before any fit. Population and tile budgets are not edited.',
                          'The density builder must retain every source population in its original component, including points inside removed seams.',
                          'A single continuous deformation may still compress the seam. Shape improvement is not guaranteed.',
                          'Any downstream tile fit must use a contact policy that excludes these selected pairs.'])
    (output/'cuts.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--pair', action='append', required=True, help='Two ISO codes separated by a colon')
    parser.add_argument('--width-km', type=float, default=25.)
    parser.add_argument('--maximum-fragment-loss', type=float, default=0.)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
