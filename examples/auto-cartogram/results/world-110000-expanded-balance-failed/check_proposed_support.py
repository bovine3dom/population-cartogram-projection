from pathlib import Path
import hashlib,json,sys
sys.path.insert(0,'examples/auto-cartogram')
from check_transport import check,rows
from check_support import equal_target_cut
base=Path('output/auto-cartogram');raw=base/'world-110000-transport-r3-grouped'
checked=check(raw)
command=json.loads((base/'world-jobs/world-110000-r3-expanded-command.json').read_text())
selected={command[i+1] for i,arg in enumerate(command) if arg=='--expand-group'}
sources=list(rows(raw/'sources.csv'));targets=list(rows(raw/'targets.csv'))
si={r['id']:i for i,r in enumerate(sources)};ti={(float(r['x']),float(r['y'])):i for i,r in enumerate(targets)}
support=[set() for _ in sources]
for r in rows(raw/'mapping.csv'):support[si[r['id']]].add(ti[float(r['x']),float(r['y'])])
added=0
for i,r in enumerate(sources):
 if r['group_id'] not in selected:continue
 extra=set()
 for j in support[i]:
  x,y=float(targets[j]['x']),float(targets[j]['y'])
  for dx,dy in [(0,1),(0,-1),(1,0),(-1,0)]:
   k=ti.get((x+dx,y+dy))
   if k is not None and targets[k]['group_id']==r['group_id']:extra.add(k)
 added+=len(extra-support[i]);support[i]|=extra
results=[]
for group in sorted(selected):
 source_indices=[i for i,r in enumerate(sources) if r['group_id']==group];target_indices=[i for i,r in enumerate(targets) if r['group_id']==group];local={j:i for i,j in enumerate(target_indices)}
 result=equal_target_cut([int(float(sources[i]['value'])) for i in source_indices],[[local[j] for j in support[i]] for i in source_indices],len(local))
 result['group_id']=group;results.append(result)
report=dict(added_pairs=added,selected_groups=results,infeasible_selected_groups=sum(not r['exact_marginals_feasible'] for r in results),checked_inputs=checked,rule='One rook step from each original target, within the same selected group. This checks proposed support, not exported weights.',script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),cut_checker_sha256=hashlib.sha256(Path('examples/auto-cartogram/check_support.py').read_bytes()).hexdigest())
(base/'world-jobs/world-110000-expanded-support-check.json').write_text(json.dumps(report,indent=2)+'\n')
print(report['added_pairs'],report['infeasible_selected_groups'])
