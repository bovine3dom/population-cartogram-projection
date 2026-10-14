#!/usr/bin/env python3
"""Compare country-level contacts on the explicitly matched OWID/source scope."""
import argparse
import json
from pathlib import Path

from review_gaps import read_cells
from review_layout import read_csv
from save_review import digest


def country_contacts(owners,common):
    return {tuple(sorted((c,owners[q]))) for (x,y),c in owners.items()
        for q in [(x+1,y),(x,y+1)] if c in common and owners.get(q) in common and owners[q]!=c}


def run(inputs,owid,iso_codes,layouts,output):
    if output.exists():raise ValueError('Output already exists')
    files=[inputs/'groups.csv',inputs/'geographic-contacts.csv',owid,iso_codes]+[p/'cells.csv' for p in layouts]
    hashes={str(p):digest(p) for p in files}
    scripts={p.name:digest(p) for p in [Path(__file__),Path(__file__).with_name('review_gaps.py'),Path(__file__).with_name('review_layout.py')]}
    ids={r['component_id']:r['country_id'] for r in read_csv(inputs/'groups.csv')}
    codes={str(int(r['numeric'])):r['alpha_3'] for r in json.loads(iso_codes.read_text())['3166-1']}
    original,source=read_cells(owid,True)
    common={codes[c] for c in original.values() if c in codes}&set(ids.values())
    required={tuple(sorted((ids[r['a']],ids[r['b']]))) for r in read_csv(inputs/'geographic-contacts.csv')
        if ids[r['a']] in common and ids[r['b']] in common and ids[r['a']]!=ids[r['b']]}
    cases=[]
    for name,owners in [('OWID',{p:codes.get(c) for p,c in original.items()})]+[
        (str(layout),{p:ids[c] for p,c in read_cells(layout/'cells.csv')[0].items()}) for layout in layouts]:
        actual=country_contacts(owners,common)
        cases.append(dict(name=name,retained=len(required&actual),missing=len(required-actual),unsupported=len(actual-required),
            missing_pairs=sorted(required-actual),unsupported_pairs=sorted(actual-required)))
    report=dict(common_country_ids=sorted(common),required_country_pairs=sorted(required),
        numeric_to_alpha3={c:codes.get(c) for c in sorted(set(original.values()))},
        excluded_owid_codes=sorted(c for c in set(original.values()) if codes.get(c) not in common),
        owid_coordinate_audit=source,cases=cases,inputs=hashes,scripts=scripts,
        limit='Country-level contacts only, on the matched country subset. This does not compare component-level topology, overseas positions, or geographic order. ISO alpha-3 values that differ from source ADM0 IDs are excluded, not guessed. Required pairs include source borders with unrepresented components. Unsupported contacts are not necessarily errors in the same geographic dataset used to create OWID. OWID coordinate conflicts use the final row for the contact check; the raw conflicts remain reported.')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','owid','iso_codes','output']:parser.add_argument(name,type=Path)
    parser.add_argument('layouts',type=Path,nargs='+')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
