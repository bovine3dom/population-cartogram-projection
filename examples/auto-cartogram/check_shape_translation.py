#!/usr/bin/env python3
"""Check that each placed component is an unchanged, integer-translated template."""
import argparse
import csv
import json
from pathlib import Path

from review_layout import load
from save_review import digest


def run(inputs,templates,layout,output):
    if output.exists():raise ValueError('Output already exists')
    rows,source,_=load(inputs,templates);_,target,_=load(inputs,layout)
    shifts=[]
    for c in sorted(source):
        a,b=source[c],target[c]
        dx=min(x for x,y in b)-min(x for x,y in a);dy=min(y for x,y in b)-min(y for x,y in a)
        if {(x+dx,y+dy) for x,y in a}!=b:raise ValueError(f'Changed template shape: {c}')
        if len(b)!=int(rows[c]['tiles']):raise ValueError(f'Incorrect template count: {c}')
        shifts.append(dict(component_id=c,country_id=rows[c]['country_id'],tiles=len(b),dx=dx,dy=dy))
    report=dict(components=len(shifts),tiles=sum(r['tiles'] for r in shifts),all_shapes_are_integer_translations=True,
        inputs={str(p):digest(p) for p in [inputs/'groups.csv',templates/'cells.csv',layout/'cells.csv']},script_sha256=digest(Path(__file__)),
        limit='Proves that represented tile templates did not change. Does not prove correct positions, source-hole preservation, or separate representation of zero-budget islands.')
    output.mkdir(parents=True)
    with (output/'translations.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(shifts[0]));writer.writeheader();writer.writerows(shifts)
    (output/'translation-check.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','templates','layout','output']:parser.add_argument(name,type=Path)
    args=parser.parse_args();run(args.inputs,args.templates,args.layout,args.output)
