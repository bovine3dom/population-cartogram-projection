#!/usr/bin/env python3
"""Check whether Kontur patch labels can anchor boundary correspondence."""
import argparse
import json
from pathlib import Path

from kontur_boundary_map import labelled_arcs
from save_review import digest


def boundary_runs(features):
    _,arcs = labelled_arcs(features)
    return [arc['labels'] for arc in arcs]


def cyclic_match(a,b):
    return bool(a) and len(a)==len(b) and any(a==b[i:]+b[:i] for i in range(len(b)))


def run(root, output):
    if output.exists():
        raise ValueError('Use a new output directory')
    shared_path = root/'kontur-patch-flow-200-floor/blend-0.9/areas_cartogram.geojson'
    shared = json.loads(shared_path.read_text())['features']
    inputs = {str(shared_path):digest(shared_path)}
    records = []
    for code in ['RUS','CHN','IND','KAZ']:
        path = root/'independent-kontur-flow'/code/'blend-0.9/areas_cartogram.geojson'
        independent = json.loads(path.read_text())['features']
        ids = {f['properties']['patch_id'] for f in independent}
        selected = [f for f in shared if f['properties']['patch_id'] in ids]
        if {f['properties']['patch_id'] for f in selected} != ids:
            raise ValueError('Patch labels differ')
        left,right = boundary_runs(selected),boundary_runs(independent)
        records.append(dict(country=code,shared_runs=left,independent_runs=right,
                            matching_ring_count=len(left)==len(right),
                            ordered_patch_runs_match=len(left)==len(right) and all(cyclic_match(a,b) for a,b in zip(left,right))))
        inputs[str(path)] = digest(path)
    output.mkdir(parents=True)
    report = dict(countries=records,inputs=inputs,script_sha256=digest(Path(__file__)),
                  limits=['This checks label order only, not pointwise geometric correspondence.',
                          'Boundary segments below one billionth of ring length inherit the preceding label as numerical fragments.',
                          'No fitting, layout, population, or export is changed.'])
    (output/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
