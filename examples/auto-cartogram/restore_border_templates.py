#!/usr/bin/env python3
"""Test source-shaped templates for small components with no retained true border."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np

from compact_regions import adjacent
from dock_true_borders import candidates, contacts
from review_layout import load, read_csv, connectivity
from save_review import digest


def restore(tiles, templates, required, positions, maximum_tiles=550, radius=64):
    result = {c: set(p) for c, p in tiles.items()}
    owners = {p: c for c, points in result.items() for p in points}
    moves = []
    for c in sorted(result, key=lambda c: (len(result[c]), c)):
        actual = contacts(owners)
        neighbours = {b if a == c else a for a, b in required if c in (a, b)}
        if not neighbours or len(result[c]) > maximum_tiles or any(c in p for p in actual & required):
            continue
        centre = np.mean(sorted(result[c]), axis=0)
        outside = {p: v for p, v in owners.items() if v != c}
        centres = {v: np.mean(sorted(result[v]), axis=0) for v in neighbours}
        best = None
        for kind, template in [('current', result[c]), ('source', templates[c])]:
            if len(template) != len(result[c]) or connectivity(template) != 1:
                raise ValueError('Template budget or connectivity differs')
            offset = np.rint(centre-np.mean(sorted(template), axis=0)).astype(int)
            local = {(x+int(offset[0]), y+int(offset[1])) for x, y in template}
            start = np.mean(sorted(local), axis=0)
            trial_tiles = dict(result, **{c: local})
            # Candidate generation needs the template owner at its provisional position.
            trial_owners = outside | {p: c for p in local}
            for dx, dy in sorted(candidates({c}, trial_tiles, trial_owners, required, radius)):
                target = start+np.array([dx, dy])
                if any(abs(positions[c][axis]-positions[n][axis]) > 2
                       and (positions[c][axis]-positions[n][axis])*(target[axis]-centres[n][axis]) <= 0
                       for n in neighbours for axis in (0, 1)):
                    continue
                shifted = {(x+dx, y+dy) for x, y in local}
                if shifted & outside.keys():
                    continue
                boundary = {tuple(sorted((c, outside[q]))) for p in shifted for q in adjacent(p) if q in outside}
                gained = boundary & required
                if not gained or boundary-required:
                    continue
                # Prefer all true neighbours, then short movement and the existing shape.
                score = (-len(gained), float(np.sum((target-centre)**2)), kind != 'current', dx, dy)
                if best is None or score < best[0]:
                    best = score, shifted, kind, boundary
        if best is None:
            continue
        _, shifted, kind, boundary = best
        result[c] = shifted
        owners = outside | {p: c for p in shifted}
        moves.append(dict(component=c, template=kind, gained=sorted(boundary & required),
                          removed_false=sorted(p for p in actual-required if c in p)))
    return result, moves


def run(inputs, layout, templates, output, maximum_tiles=550, radius=64):
    if output.exists() or min(maximum_tiles, radius) < 1:
        raise ValueError('Use a new output and positive limits')
    rows, original, owners = load(inputs, layout)
    native = load(inputs, templates)[1]
    if any(len(original[c]) != int(rows[c]['tiles']) for c in original):
        raise ValueError('Exact counts required')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    positions = {c: ((float(r['west'])+float(r['east']))/2, (float(r['south'])+float(r['north']))/2) for c, r in rows.items()}
    result, moves = restore(original, native, required, positions, maximum_tiles, radius)
    after_owner = {p: c for c, points in result.items() for p in points}
    before, after = contacts(owners), contacts(after_owner)
    if len(after_owner) != len(owners) or (before & required)-after or after-required-before:
        raise AssertionError('Overlap or border regression')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    record = dict(maximum_tiles=maximum_tiles, radius=radius, moves=moves,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', templates/'cells.csv']},
                  script_sha256=digest(Path(__file__)), cells_sha256=digest(output/'cells.csv'),
                  limits=['Only components with no retained true border can move.',
                          'The source template can change shape, but not tile count.',
                          'No new false contact or lost true contact is allowed.',
                          'Source bounding-box axis guards are approximate. No production approval.'])
    (output/'border-templates.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=source-border-templates\ncounts=exact\napproval=none\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'templates', 'output']:
        parser.add_argument(name, type=Path)
    run(**vars(parser.parse_args()))
