#!/usr/bin/env python3
"""Balance completed island shards without adding cross-group pairs."""
import argparse
import csv
import json
from pathlib import Path
import time

from balance_transport import run
from check_transport import check
from save_review import digest


def balance(directory, wait=False):
    output=directory/'balanced';output.mkdir(exist_ok=True)
    with (directory/'targets.csv').open() as stream:expected={r['group_id'] for r in csv.DictReader(stream)}
    while True:
        completed=set()
        for source in sorted((directory/'raw').iterdir()):
            if not (source/'complete.txt').exists():continue
            group=source.name;target=output/group
            if target.exists():
                completed.add(group);continue
            attempts=[]
            for steps in range(5):
                try:
                    result=run(source,target,iterations=50000,tolerance=1e-4,expand_groups=[group] if steps else [],expansion_steps=max(1,steps))
                    attempts.append(dict(expansion_steps=steps,passed=True,result=result));break
                except ValueError as error:
                    attempts.append(dict(expansion_steps=steps,passed=False,error=str(error)))
                    print(group,steps,str(error),flush=True)
                finally:
                    (directory/(group+'-balance-attempts.json')).write_text(json.dumps(attempts,indent=2)+'\n')
            else:raise ValueError(f'No accepted balance for {group}')
            checked=check(target)
            if checked['cross_group_population']!=0 or checked['maximum_relative_target_error']>1e-4 or abs(checked['retained_share']-1)>1e-9:raise ValueError('Balance audit failed')
            print(group,'balanced',flush=True);completed.add(group)
        if completed==expected:
            (directory/'balance-complete.json').write_text(json.dumps(dict(groups=len(completed),script_sha256=digest(Path(__file__)),tolerance=1e-4,cross_group_population=0),indent=2)+'\n');return
        if not wait:raise ValueError(f'Only {len(completed)} of {len(expected)} groups are ready')
        time.sleep(10)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directory',type=Path);parser.add_argument('--wait',action='store_true')
    args=parser.parse_args();balance(args.directory,args.wait)
