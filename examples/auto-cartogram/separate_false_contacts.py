#!/usr/bin/env python3
"""Remove false contacts with short rigid translations; retain all true contacts."""
import argparse
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from dock_true_borders import contacts
from review_layout import load, read_csv
from save_review import digest


def separate(tiles, required, blocked=(), radius=4, maximum_tiles=550):
    result={c:set(p) for c,p in tiles.items()}
    owners={p:c for c,points in result.items() for p in points}
    blocked=set(blocked);moves=[]
    shifts=sorted(((dx,dy) for dx in range(-radius,radius+1) for dy in range(-radius,radius+1)
                   if 0<dx*dx+dy*dy<=radius*radius),key=lambda p:(p[0]**2+p[1]**2,p))
    for c in sorted(result,key=lambda c:(len(result[c]),c)):
        if len(result[c])>maximum_tiles:continue
        actual=contacts(owners)
        current={p for p in actual if c in p}
        if not current-required:continue
        outside={p:d for p,d in owners.items() if d!=c}
        candidates=[]
        for dx,dy in shifts:
            moved={(x+dx,y+dy) for x,y in result[c]}
            if moved & (outside.keys() | blocked):continue
            trial_owner=outside|{p:c for p in moved}
            if any(owners.get(q)!=trial_owner.get(q) for p in blocked for q in adjacent(p)):continue
            boundary={tuple(sorted((c,outside[q]))) for p in moved for q in adjacent(p) if q in outside}
            if (current & required)-boundary or boundary-required-current:continue
            if len(boundary-required)>=len(current-required):continue
            candidates.append(((len(boundary-required),dx*dx+dy*dy,dx,dy),moved,boundary))
        if not candidates:continue
        score,moved,boundary=min(candidates,key=lambda x:x[0])
        result[c]=moved;owners=outside|{p:c for p in moved}
        moves.append(dict(component=c,dx=score[2],dy=score[3],removed_false=sorted(current-required-boundary)))
    return result,moves


def run(inputs,layout,output,radius=4):
    if output.exists() or radius<1:raise ValueError('Use a new output and positive radius')
    rows,tiles,owners=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) for c in tiles):raise ValueError('Exact counts required')
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    lakes=layout/'lake-cells.csv'
    water={(int(r['x']),int(r['y'])) for r in read_csv(lakes)} if lakes.exists() else set()
    result,moves=separate(tiles,required,water,radius)
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
    for name in ['lake-cells.csv','lake-placement.json']:
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record=dict(radius=radius,moves=moves,
                inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv']+([lakes] if lakes.exists() else [])},
                script_sha256=digest(Path(__file__)),cells_sha256=digest(output/'cells.csv'),
                limits=['Short rigid translations only. All true contacts are retained. No new false contacts.',
                        'Lake cells and their shore labels stay fixed. Coast access and source-axis order need separate review.',
                        'Small gaps can grow. No production approval.'])
    (output/'separation.json').write_text(json.dumps(record,indent=2)+'\n')
    (output/'complete.txt').write_text('mode=false-contact-separation\ncounts=exact\napproval=none\n')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--radius',type=int,default=4)
    run(**vars(parser.parse_args()))
