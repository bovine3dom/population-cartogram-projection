#!/usr/bin/env python3
"""Test source openings with all unrelated country vertices fixed."""
import argparse
import json
import math
from pathlib import Path

from shapely import affinity, coverage_simplify
from shapely.geometry import mapping

from assemble_independent import CUTS
from independent_kontur_flow import normalized
from review_flow import read_shapes
from review_layout import read_csv
from save_review import digest
from welded_boundary_fit import WeldedMesh, seed_cut_gap


def run(root,output):
    if output.exists():
        raise ValueError('Use a new output directory')
    source_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    contacts_path = groups_path.with_name('geographic-contacts.csv')
    audit = json.loads(audit_path.read_text())
    if any(audit['inputs'].get(str(p)) != digest(p) for p in [groups_path,contacts_path]):
        raise ValueError('Audit inputs differ')
    native = read_shapes(source_path)
    groups = {r['component_id']:r for r in read_csv(groups_path)}
    budgets = {c:int(groups[c]['tiles']) for c in native}
    scale = math.sqrt(sum(budgets.values())/sum(g.area for g in native.values()))
    source = {c:affinity.scale(g,scale,scale,origin=(0,0)) for c,g in native.items()}
    main = {code:max((c for c in source if c[:3]==code),key=budgets.get) for code in {v for pair in CUTS for v in pair}}
    cuts = {tuple(sorted((main[a],main[b]))) for a,b in CUTS}
    if not cuts <= {tuple(sorted((r['a'],r['b']))) for r in audit['borders'] if r['eligible']}:
        raise ValueError('Unaudited source cut')
    output.mkdir(parents=True)
    report = dict(scale=scale,cuts=sorted(cuts),cases=[],inputs={str(p):digest(p) for p in [source_path,groups_path,audit_path,contacts_path]},
                  script_sha256=digest(Path(__file__)),limits=['Source opening only. No population flow or tile fit.',
                  'All nodes of countries outside the cut set stay fixed, including shared border nodes.',
                  'The nominal target is not the measured gap. Inspect movement and validity.'])
    for tolerance in [.1,.5,1.,2.]:
        simplified = dict(zip(source,coverage_simplify(list(source.values()),tolerance)))
        for gap in [2.,8.,16.,32.]:
            mesh = WeldedMesh(simplified,{c:normalized(g,budgets[c]) for c,g in simplified.items()},budgets,cuts,edge_length=8.)
            before = mesh.initial.copy()
            entry = dict(tolerance=tolerance,gap=gap)
            try:
                entry['seed'] = seed_cut_gap(mesh,gap,local=True)
                shapes = mesh.polygons(mesh.initial)
                entry['maximum_movement'] = float(abs(mesh.initial-before).max())
                entry['contacts'] = [dict(a=a,b=b,cut=(a,b) in cuts,gap=shapes[a].distance(shapes[b]),shared_length=shapes[a].boundary.intersection(shapes[b].boundary).length) for a,b in sorted(mesh.initial_contacts)]
                file = output/f'source-{tolerance:g}-{gap:g}.geojson'
                file.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(affinity.scale(g,1/scale,1/scale,origin=(0,0)))) for c,g in shapes.items()]),separators=(',',':'))+'\n')
                entry['geometry_sha256'] = digest(file)
            except Exception as error:
                entry['error'] = str(error)
            report['cases'].append(entry)
            (output/'experiment.json').write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(entry),flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    run(**vars(parser.parse_args()))
