#!/usr/bin/env python3
"""Check that lake insertion retains every saved island-position improvement."""
import argparse
from collections import Counter
import json
from pathlib import Path

from dock_true_borders import contacts
from review_layout import connectivity, load, read_csv
from save_review import digest


def check(rows, original, islands, reference_water, combined, water):
    labels = set(rows)
    if any(set(t) != labels for t in [original, islands, combined]):
        raise ValueError('Component labels differ')
    if any(len(t[c]) != int(rows[c]['tiles']) or connectivity(t[c]) != 1
           for t in [original, islands, combined] for c in labels):
        raise ValueError('Component budget or connectivity changed')
    owners = {p: c for c, points in combined.items() for p in points}
    if len(owners) != sum(map(len, combined.values())):
        raise ValueError('Land overlaps')
    moved = {c for c in labels if original[c] != islands[c]}
    if any(combined[c] != islands[c] for c in moved):
        raise ValueError('An island-position improvement was lost')
    counts = lambda records: Counter((r['lake_id'], r['name']) for r in records)
    if counts(reference_water) != counts(water):
        raise ValueError('Named lake identities or water budgets changed')
    lake_points = {(int(r['x']), int(r['y'])) for r in water}
    if len(lake_points) != len(water) or lake_points & owners.keys():
        raise ValueError('Lake cells overlap land or each other')
    before_contacts = contacts({p: c for c, points in islands.items() for p in points})
    after_contacts = contacts(owners)
    if after_contacts != before_contacts:
        raise ValueError('Contact graph differs from the saved island layout')
    return dict(tiles=len(owners), components=len(labels), preserved_moved_components=len(moved),
                preserved_moved_tiles=sum(len(islands[c]) for c in moved),
                lakes=len(counts(water)), empty_lake_cells=len(lake_points),
                island_positions_exact=True, contact_graph_exact=True,
                lake_ids_and_budgets_exact=True, lake_coordinates_may_change=True,
                moved_components=sorted(moved))


def run(inputs, original, islands, reference_lakes, combined, output):
    rows, base, _ = load(inputs, original)
    _, moved, _ = load(inputs, islands)
    _, result, _ = load(inputs, combined)
    report = check(rows, base, moved, read_csv(reference_lakes/'lake-cells.csv'), result, read_csv(combined/'lake-cells.csv'))
    report['inputs'] = {str(p): digest(p) for p in [inputs/'groups.csv', original/'cells.csv', islands/'cells.csv',
                         reference_lakes/'lake-cells.csv', combined/'cells.csv', combined/'lake-cells.csv']}
    report['script_sha256'] = digest(Path(__file__))
    output.write_text(json.dumps(report, indent=2)+'\n')
    return {k: v for k, v in report.items() if k not in ['inputs', 'moved_components', 'script_sha256']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'original', 'islands', 'reference_lakes', 'combined', 'output']:
        parser.add_argument(name, type=Path)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
