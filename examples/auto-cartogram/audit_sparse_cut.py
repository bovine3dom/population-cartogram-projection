#!/usr/bin/env python3
"""Find a low-cost audited cut in the current contact graph without moving tiles."""
import argparse
import json
from pathlib import Path

import networkx as nx

from dock_true_borders import contacts
from review_layout import load, read_csv
from save_review import digest


def cut(actual, required, borders, source, target):
    eligible = {tuple(sorted((b['a'], b['b']))): b for b in borders if b['eligible']}
    # Count cuts first, with an additional cost for corridor population.
    costs = {p: 1+eligible[p]['corridor_population']/1e6 if p in eligible else 1e-6
             for p in actual if p in eligible or p not in required}
    barrier = sum(costs.values())+1
    graph = nx.Graph()
    for a, b in sorted(actual):
        graph.add_edge(a, b, capacity=costs.get((a, b), barrier))
    value, (left, _) = nx.minimum_cut(graph, source, target)
    crossing = sorted(p for p in actual if (p[0] in left) != (p[1] in left))
    protected = graph.copy()
    protected.remove_edges_from(costs)
    path = nx.shortest_path(protected, source, target) if nx.has_path(protected, source, target) else []
    return dict(feasible=value < barrier, cost=value, protected_path=path,
                cut=[dict(a=a, b=b, audited_sparse=(a, b) in eligible,
                          false_contact=(a, b) not in required,
                          protected=(a, b) in required and (a, b) not in eligible) for a, b in crossing])


def run(inputs, layout, audit, output, source, target):
    rows, tiles, owners = load(inputs, layout)
    population = json.loads(audit.read_text())
    for path in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if population['inputs'].get(str(path)) != digest(path):
            raise ValueError('Population audit uses different inputs')
    main = lambda code: max((c for c in tiles if rows[c]['country_id'] == code), key=lambda c: len(tiles[c]))
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    result = cut(set(contacts(owners)), required, population['borders'], main(source), main(target))
    result.update(source=source, target=target,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', audit, Path(__file__)]},
                  limits=['This is a contact-graph diagnostic, not a layout proposal or evidence of better shapes.',
                          'The cost is one per true cut plus corridor population in millions. False contacts have negligible cost and may be removed.',
                          'Every existing true contact above either density limit is protected. Already missing contacts are not added.',
                          'A feasible cut can still fail geometric, lake, island, or shape checks. No tiles are moved.'])
    output.write_text(json.dumps(result, indent=2)+'\n')
    return {k: result[k] for k in ['feasible', 'cost', 'cut', 'protected_path']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'audit', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--source', required=True)
    parser.add_argument('--target', required=True)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
