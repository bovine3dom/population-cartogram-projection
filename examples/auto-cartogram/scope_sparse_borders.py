#!/usr/bin/env python3
"""Restrict a population-audited border experiment to one country's neighbours."""
import argparse
import json
from pathlib import Path

from review_layout import load
from save_review import digest


def scope(report, rows, tiles, country, minimum_tiles=16):
    if minimum_tiles < 1 or country not in {r['country_id'] for r in rows.values()}:
        raise ValueError('Use a represented country and a positive tile limit')
    result = dict(report)
    result['borders'] = []
    for border in report['borders']:
        a, b = border['a'], border['b']
        selected = (country in {rows[c]['country_id'] for c in (a, b)}
                    and min(len(tiles[a]), len(tiles[b])) >= minimum_tiles)
        result['borders'].append(dict(border, eligible=border['eligible'] and selected,
                                     scope_selected=selected, population_eligible=border['eligible']))
    if not any(b['eligible'] for b in result['borders']):
        raise ValueError('No eligible borders in this scope')
    result['scope'] = dict(country=country, minimum_tiles=minimum_tiles,
                           rule='Both endpoints must meet the tile limit. One endpoint must belong to the selected country.')
    return result


def run(inputs, layout, audit, output, country, minimum_tiles=16):
    rows, tiles, _ = load(inputs, layout)
    report = json.loads(audit.read_text())
    for path in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if report['inputs'].get(str(path)) != digest(path):
            raise ValueError('Population audit uses different inputs')
    report = scope(report, rows, tiles, country, minimum_tiles)
    report['scope']['inputs'] = {str(p): digest(p) for p in [audit, layout/'cells.csv', Path(__file__)]}
    output.write_text(json.dumps(report, indent=2)+'\n')
    return [b['countries'] for b in report['borders'] if b['eligible']]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'audit', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--country', required=True)
    parser.add_argument('--minimum-tiles', type=int, default=16)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
