#!/usr/bin/env python3
"""Move empty lake cells with recorded rigid translations of their shore countries."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from review_layout import load, read_csv
from save_review import digest


def run(inputs,layout,reference,separation,output):
    if output.exists():raise ValueError('Use a new output')
    _,_,owner=load(inputs,layout)
    original=load(inputs,reference)[2]
    record=json.loads(separation.read_text())
    if record['inputs'].get(str(reference/'cells.csv'))!=digest(reference/'cells.csv'):
        raise ValueError('Translation reference differs')
    moves={r['component']:(r['dx'],r['dy']) for r in record['moves']}
    waters=defaultdict(list)
    for r in read_csv(reference/'lake-cells.csv'):waters[r['lake_id']].append(r)
    report=json.loads((reference/'lake-placement.json').read_text())
    result=[];used=set();translations=[]
    for lake in report['lakes']:
        if not lake.get('accepted'):continue
        rows=waters[lake['lake_id']]
        points={(int(r['x']),int(r['y'])) for r in rows}
        shore={original.get(q) for p in points for q in adjacent(p) if q not in points}
        shifts={moves.get(c,(0,0)) for c in shore}
        shift=next(iter(shifts)) if len(shifts)==1 else (0,0)
        moved={(x+shift[0],y+shift[1]) for x,y in points}
        if moved & (owner.keys()|used):raise ValueError('Lake overlaps land or another lake')
        actual={owner.get(q) for p in moved for q in adjacent(p) if q not in moved}
        if not set(lake['required_shores'])<=actual<=set(lake['allowed_shores']):
            raise ValueError('Lake shore constraints failed: '+lake['name'])
        used.update(moved)
        result.extend(dict(lake_id=lake['lake_id'],name=lake['name'],x=x,y=y) for x,y in sorted(moved))
        if shift!=(0,0):
            translations.append(dict(lake_id=lake['lake_id'],name=lake['name'],dx=shift[0],dy=shift[1]))
            lake['centre']=[sum(p[i] for p in moved)/len(moved) for i in (0,1)]
    assert len(result)==sum(map(len,waters.values()))
    output.mkdir(parents=True)
    shutil.copyfile(layout/'cells.csv',output/'cells.csv')
    with (output/'lake-cells.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=['lake_id','name','x','y']);writer.writeheader();writer.writerows(result)
    transport=dict(translations=translations,
                   inputs={str(p):digest(p) for p in [layout/'cells.csv',reference/'cells.csv',reference/'lake-cells.csv',reference/'lake-placement.json',separation]},
                   script_sha256=digest(Path(__file__)),
                   limits=['Only a common recorded rigid translation can move a lake. Shared shores must still pass their original constraints.',
                           'No land tile moves. Empty lake counts and IDs stay fixed.'])
    report['rigid_transport']=transport
    (output/'lake-placement.json').write_text(json.dumps(report,indent=2)+'\n')
    (output/'lake-transport.json').write_text(json.dumps(transport,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=rigid-empty-lake-transport\ncounts=exact\napproval=none\n')
    return transport


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','reference','separation','output']:parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
