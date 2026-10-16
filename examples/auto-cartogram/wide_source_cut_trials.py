#!/usr/bin/env python3
"""Test wide early source cuts, with an explicit short-border alternative."""
import argparse
import json
from pathlib import Path
import time

from shapely.geometry import mapping

from assemble_independent import CUTS
from cut_flow_source import open_seams
from kontur_subregion_flow import run as flow
from review_flow import read_shapes
from review_layout import read_csv
from save_review import digest


def short_closures(primary, borders, maximum_length=50., maximum_population=500000.):
    """Find short, low-total-population edges closing a two-edge bypass."""
    records = {tuple(sorted((r['a'],r['b']))):r for r in borders}
    neighbours = {}
    for a,b in records:
        neighbours.setdefault(a,set()).add(b)
        neighbours.setdefault(b,set()).add(a)
    additions = set()
    for a,b in primary:
        for c in neighbours[a]&neighbours[b]:
            edges = [tuple(sorted((a,c))),tuple(sorted((b,c)))]
            if any(e in primary for e in edges):
                continue
            allowed = [e for e in edges if records[e].get('length_km',float('inf')) <= maximum_length
                       and records[e].get('corridor_population',float('inf')) <= maximum_population]
            if allowed:
                additions.add(min(allowed,key=lambda e:records[e]['corridor_population']))
    return additions


def run(root, output, widths=(100.,250.,500.,1000.), grid=512):
    if output.exists():
        raise ValueError('Use a new output directory')
    source = root/'world-55000-mainland-flow/input/geometry.geojson'
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    contacts_path = root/'world-55000-dissolved-input/geographic-contacts.csv'
    shapes = read_shapes(source)
    groups = {r['component_id']:r for r in read_csv(groups_path)}
    audit = json.loads(audit_path.read_text())
    for path in [groups_path,contacts_path]:
        if audit['inputs'].get(str(path)) != digest(path):
            raise ValueError('Audit inputs differ')
    main = {code:max((c for c in shapes if c[:3]==code),key=lambda c:int(groups[c]['tiles'])) for code in {v for p in CUTS for v in p}}
    primary = {tuple(sorted((main[a],main[b]))) for a,b in CUTS}
    by_pair = {tuple(sorted((r['a'],r['b']))):r for r in audit['borders']}
    if any(not by_pair[p]['eligible'] for p in primary):
        raise ValueError('Primary cut fails the density audit')
    additions = short_closures(primary,audit['borders'])
    output.mkdir(parents=True)
    report = dict(started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),grid=grid,
                  primary=sorted(primary),short_closures=[by_pair[p] for p in sorted(additions)],
                  maximum_source_area_loss=.8,maximum_fragment_loss=.05,cases=[],
                  inputs={str(p):digest(p) for p in [source,audit_path,groups_path,contacts_path]},
                  script_sha256=digest(Path(__file__)),
                  limits=['Research only. The short-border policy is different from the original density-only rule.',
                          'The alternative permits a retained bypass edge only if it is at most 50 km long and its audited corridor has at most 500000 people.',
                          'Source land can be removed, but no component population or tile budget is removed. Outside population centres are reassigned to the nearest patch of the same component.',
                          'The geographic reference remains unchanged. Exact patch partitions can change after cutting.',
                          'Every unselected source contact must remain. No tile fit or production export is changed.'])
    def save():
        (output/'experiment.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    trials = [('control',0.,set())]+[(f'{policy}-{width:g}',width,cuts) for width in widths
                                      for policy,cuts in [('strict',primary),('short',primary|additions)]]
    for name,width,cuts in trials:
        folder = output/name
        folder.mkdir()
        entry = dict(name=name,width_km=width,cuts=sorted(cuts),complete=False)
        report['cases'].append(entry);save()
        try:
            changed,removed = (open_seams(shapes,cuts,width/6.371,maximum_area_loss=.8,maximum_fragment_loss=.05)
                               if cuts else (shapes,[]))
            geometry = folder/'geometry.geojson'
            geometry.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in changed.items()]),separators=(',',':'))+'\n')
            entry.update(removed=removed,source_sha256=digest(geometry));save()
            flow(root,folder/'flow',cell_size=200.,strengths=(0.,.9),grid=grid,timeout=600,geometry=geometry)
            details = json.loads((folder/'flow/experiment.json').read_text())
            entry.update(complete=all(r.get('solver_success') and r.get('complete') for r in details['runs']),
                         population=details['population'],patches=details['patches'],
                         flow_report_sha256=digest(folder/'flow/experiment.json'))
        except Exception as error:
            entry['error'] = str(error)
        entry['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        save();print(json.dumps(entry),flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--widths',type=float,nargs='+',default=[100.,250.,500.,1000.])
    parser.add_argument('--grid',type=int,default=512)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
