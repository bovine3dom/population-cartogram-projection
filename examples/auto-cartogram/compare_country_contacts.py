#!/usr/bin/env python3
"""Compare country-level contacts on the explicitly matched OWID/source scope."""
import argparse
import json
from pathlib import Path

from review_gaps import read_cells
from review_layout import read_csv, axis_order, NEIGHBOURS
from save_review import digest


def country_contacts(owners,common):
    return {tuple(sorted((c,owners[q]))) for (x,y),c in owners.items()
        for q in [(x+1,y),(x,y+1)] if c in common and owners.get(q) in common and owners[q]!=c}


def main_components(owners):
    countries={}
    for p,c in owners.items():countries.setdefault(c,set()).add(p)
    result={}
    for c,remaining in countries.items():
        best=set()
        while remaining:
            start=remaining.pop();piece={start};stack=[start]
            while stack:
                x,y=stack.pop()
                for dx,dy in NEIGHBOURS:
                    p=(x+dx,y+dy)
                    if p in remaining:remaining.remove(p);piece.add(p);stack.append(p)
            if not best or (len(piece),min(piece))>(len(best),min(best)):best=piece
        result[c]=best
    return result


def run(inputs,owid,iso_codes,layouts,output,components=None):
    if output.exists():raise ValueError('Output already exists')
    files=[inputs/'groups.csv',inputs/'geographic-contacts.csv',owid,iso_codes]+[p/'cells.csv' for p in layouts]+([components] if components else [])
    hashes={str(p):digest(p) for p in files}
    scripts={p.name:digest(p) for p in [Path(__file__),Path(__file__).with_name('review_gaps.py'),Path(__file__).with_name('review_layout.py')]}
    rows=read_csv(inputs/'groups.csv')
    ids={r['component_id']:r['country_id'] for r in rows};country_ids=set(ids.values())
    codes={str(int(r['numeric'])):r['alpha_3'] for r in json.loads(iso_codes.read_text())['3166-1']}
    mapped=dict(codes);aliases={}
    if components:
        candidates={}
        for r in read_csv(components):candidates.setdefault(str(int(r['raw_country_code'])),set()).add(r['country_id'])
        for code,values in candidates.items():
            if mapped.get(code) not in country_ids and len(values)==1:
                target=next(iter(values))
                if target in country_ids:mapped[code]=target;aliases[code]=target
    original,source=read_cells(owid,True)
    common={mapped[c] for c in original.values() if c in mapped}&country_ids
    required={tuple(sorted((ids[r['a']],ids[r['b']]))) for r in read_csv(inputs/'geographic-contacts.csv')
        if ids[r['a']] in common and ids[r['b']] in common and ids[r['a']]!=ids[r['b']]}
    primary={};population={}
    for r in rows:
        c=r['country_id'];mass=float(r['group_population']);population[c]=population.get(c,0)+mass
        if c not in primary or mass>float(primary[c]['group_population']):primary[c]=r
    order_shapes={c:r for c,r in primary.items() if c in common and population[c]>=10_000_000}
    cases=[]
    for name,owners in [('OWID',{p:mapped.get(c) for p,c in original.items()})]+[
        (str(layout),{p:ids[c] for p,c in read_cells(layout/'cells.csv')[0].items()}) for layout in layouts]:
        actual=country_contacts(owners,common)
        main=main_components({p:c for p,c in owners.items() if c in order_shapes})
        if set(main)!=set(order_shapes):raise ValueError('Missing country in direction comparison')
        tested,errors=axis_order(order_shapes,main,same_country=False,threshold=5)
        cases.append(dict(name=name,retained=len(required&actual),missing=len(required-actual),unsupported=len(actual-required),
            axis_comparisons=tested,axis_order_errors=len(errors),axis_error_pairs=errors,
            missing_pairs=sorted(required-actual),unsupported_pairs=sorted(actual-required)))
    report=dict(common_country_ids=sorted(common),required_country_pairs=sorted(required),
        numeric_to_alpha3={c:codes.get(c) for c in sorted(set(original.values()))},
        numeric_to_source_country={c:mapped.get(c) for c in sorted(set(original.values()))},
        source_aliases={c:aliases[c] for c in sorted(set(original.values())&aliases.keys())},
        excluded_owid_codes=sorted(c for c in set(original.values()) if mapped.get(c) not in common),
        owid_coordinate_audit=source,axis_country_ids=sorted(order_shapes),axis_population_threshold=10_000_000,axis_degree_threshold=5,
        cases=cases,inputs=hashes,scripts=scripts,
        limit='Country-level contacts only, on the matched country subset. This does not compare component-level topology or overseas positions. Direction checks use the largest four-connected output piece of each matched country with at least 10 million source people, and source main-component bounds with a five-degree separation. They are diagnostics, not proof of geographic correctness. ISO alpha-3 values are matched first. Optional source component records supply aliases only where a numeric code has one unique source country ID. Remaining unmatched codes are excluded. Required pairs include source borders with unrepresented components. Unsupported contacts are not necessarily errors in the same geographic dataset used to create OWID. OWID coordinate conflicts use the final row for the contact check; the raw conflicts remain reported.')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','owid','iso_codes','output']:parser.add_argument(name,type=Path)
    parser.add_argument('layouts',type=Path,nargs='+');parser.add_argument('--components',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
