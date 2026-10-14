#!/usr/bin/env python3
"""Partition a shared land footprint by capacity; topology is not constrained."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile
import time

import numpy as np
from scipy.optimize import minimize
from scipy.ndimage import distance_transform_edt
from scipy.special import logsumexp

from compact_regions import guide_costs, fit_guide_centres
from land_envelope import build, write_cells
from review_layout import load, read_csv, connectivity, holes
from save_review import digest


def dual(weights, costs, budgets, temperature):
    """Negative entropy-smoothed transport dual and its gradient."""
    scores=(weights[None,:]-costs)/temperature
    normalizer=logsumexp(scores,axis=1)
    probabilities=np.exp(scores-normalizer[:,None])
    return (temperature*normalizer.sum()-budgets@weights)/len(costs), (probabilities.sum(axis=0)-budgets)/len(costs)


def round_capacities(costs, budgets, weights):
    """Greedy residual correction, not a proof of minimum transport cost."""
    reduced=costs-weights[None,:]
    labels=reduced.argmin(axis=1)
    counts=np.bincount(labels,minlength=len(budgets))
    initial_error=int(np.abs(counts-budgets).sum())
    while np.any(counts!=budgets):
        donors=np.flatnonzero(counts[labels]>budgets[labels])
        receivers=np.flatnonzero(counts<budgets)
        penalties=reduced[np.ix_(donors,receivers)]-reduced[donors,labels[donors],None]
        row,col=np.unravel_index(penalties.argmin(),penalties.shape)
        point=donors[row];target=receivers[col];owner=labels[point]
        labels[point]=target;counts[owner]-=1;counts[target]+=1
    return labels,initial_error


def partition(costs,budgets,iterations=300):
    costs=np.asarray(costs,dtype=float);budgets=np.asarray(budgets)
    if costs.ndim!=2 or budgets.ndim!=1 or costs.shape[1]!=len(budgets) or not len(costs) or not np.isfinite(costs).all():raise ValueError('Invalid costs')
    if not np.isfinite(budgets).all() or np.any(budgets<=0) or np.any(budgets!=np.floor(budgets)) or budgets.sum()!=len(costs) or iterations<1:raise ValueError('Invalid capacities')
    budgets=budgets.astype(int)
    # Row shifts do not change assignment. Scale sets stable annealing temperatures.
    shifted=costs-costs.min(axis=1,keepdims=True)
    scale=max(1.,float(np.median(np.partition(shifted,min(1,len(budgets)-1),axis=1)[:,min(1,len(budgets)-1)])))
    shifted/=scale
    weights=np.zeros(len(budgets));history=[]
    for temperature in [1.,.2,.04,.008]:
        result=minimize(dual,weights,args=(shifted,budgets,temperature),jac=True,method='L-BFGS-B',options=dict(maxiter=iterations,ftol=1e-13,gtol=1e-8,maxls=40))
        weights=result.x-result.x.mean()
        labels=(shifted-weights[None,:]).argmin(axis=1)
        error=int(np.abs(np.bincount(labels,minlength=len(budgets))-budgets).sum())
        history.append(dict(temperature=temperature,iterations=int(result.nit),converged=bool(result.success),message=str(result.message),discrete_count_error=error))
        print(json.dumps(history[-1]),flush=True)
    labels,error=round_capacities(shifted,budgets,weights)
    return labels,dict(stages=history,residual_tiles_reassigned=error//2,cost_scale=scale,assignment_cost=float(costs[np.arange(len(costs)),labels].sum()))


def contact_groups(pairs):
    neighbours={c:set() for pair in pairs for c in pair}
    for a,b in pairs:neighbours[a].add(b);neighbours[b].add(a)
    remaining=set(neighbours);groups=[]
    while remaining:
        start=min(remaining);remaining.remove(start);group={start};queue=[start]
        while queue:
            for c in sorted(neighbours[queue.pop()]&remaining):
                remaining.remove(c);group.add(c);queue.append(c)
        groups.append(sorted(group))
    return groups


def run(inputs,layout,output,sigma=8.,guide=4.,anchor=.05,iterations=300,guide_layout=None,power=False,by_landmass=False,flow_geometry=None,flow_stretch=1.,flow_guide_weight=0.,sites=None,float_islands=False,dock_landmasses=False):
    if output.exists():raise ValueError('Output already exists')
    if not np.isfinite([sigma,guide,anchor]).all() or sigma<=0 or min(guide,anchor)<0:raise ValueError('Invalid settings')
    if guide_layout and (flow_geometry or sites):raise ValueError('Choose either a guide layout or flow geometry/projected sites')
    if dock_landmasses and not by_landmass:raise ValueError('Docking requires separate source land-border groups')
    if flow_stretch!=1 and not flow_geometry:raise ValueError('Flow stretch requires flow geometry')
    if not np.isfinite(flow_guide_weight) or flow_guide_weight<0 or (flow_guide_weight and not (flow_geometry and power)):raise ValueError('Flow guide cost requires flow geometry and power distance')
    started=time.monotonic()
    source_hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'validated.wkt',inputs/'geographic-contacts.csv',layout/'cells.csv']+([guide_layout/'cells.csv',guide_layout/'complete.txt'] if guide_layout else [])}
    script_hashes={name:digest(Path(__file__).with_name(name)) for name in ['partition_land.py','compact_regions.py','land_envelope.py','review_layout.py']}
    if sites:
        source_hashes[str(sites)]=digest(sites)
        script_hashes['population_sites.py']=digest(Path(__file__).with_name('population_sites.py'))
    if float_islands:script_hashes['shape_placement.py']=digest(Path(__file__).with_name('shape_placement.py'))
    if flow_geometry:
        source_hashes[str(flow_geometry)]=digest(flow_geometry)
        for name in ['flow_footprint.py','review_flow.py','shape_placement.py']:script_hashes[name]=digest(Path(__file__).with_name(name))
    shapes,tiles,_=load(inputs,layout)
    budgets={c:int(row['tiles']) for c,row in shapes.items()}
    if any(len(points)!=budgets[c] for c,points in tiles.items()):raise ValueError('Exact starting budgets required')
    pairs=[(row['a'],row['b']) for row in read_csv(inputs/'geographic-contacts.csv') if row['both_represented']=='true']
    movable={c for pair in pairs for c in pair};fixed=set(tiles)-movable
    if not movable:raise ValueError('No movable components')
    groups=contact_groups(pairs) if by_landmass else [sorted(movable)]
    groups.sort(key=lambda group:(-sum(budgets[c] for c in group),group))
    centres=alignment=flow=None
    if flow_geometry:
        from flow_footprint import prepare
        tiles,centres,flow=prepare(flow_geometry,tiles,fixed,budgets,flow_stretch)
    if guide_layout or sites:
        if sites:
            from population_sites import read_sites
            guides={c:{point} for c,point in read_sites(sites,tiles).items()}
        else:_,guides,_=load(inputs,guide_layout)
        centres,alignment=fit_guide_centres(tiles,guides,budgets)
    margin=max(64,int(np.ceil(4*sigma))+2)
    if power:
        # Power costs need sites, not dense per-country outline grids.
        points=np.array(sorted(set().union(*tiles.values())))
        lower=points.min(axis=0)-margin;upper=points.max(axis=0)+margin
        origin=tuple(lower.tolist());shape=tuple((upper-lower+1)[::-1].tolist());costs=None
    else:
        costs,origin=guide_costs(inputs,tiles,anchor,guide,margin=margin,centres=centres,budgets=budgets)
        shape=next(iter(costs.values())).shape
    target=np.zeros(shape,dtype=bool)
    result={} if float_islands else {c:set(tiles[c]) for c in fixed};assigned=set();records=[]
    for labels in groups:
        # Reserve other landmasses' starting cells and all earlier target cells.
        masks={c:points for c,points in tiles.items() if not (float_islands and c in fixed)}
        masks['__assigned__']=assigned
        mask,envelope=build(masks,set(masks)-set(labels),origin,shape,sigma,count=sum(budgets[c] for c in labels),dock=dock_landmasses)
        if np.any(mask&target):raise AssertionError('Landmass targets overlap')
        target|=mask;yy,xx=np.nonzero(mask)
        if power:
            positions=np.array([centres[c] if centres is not None else np.mean(list(tiles[c]),axis=0) for c in labels])
            points=np.column_stack((xx+origin[0],yy+origin[1]))
            matrix=((points[:,None,:]-positions[None,:,:])**2).sum(axis=2)
            if flow_guide_weight:
                for i,c in enumerate(labels):
                    guide_mask=np.zeros(shape,dtype=bool)
                    for x,y in tiles[c]:guide_mask[y-origin[1],x-origin[0]]=True
                    distance=distance_transform_edt(~guide_mask)
                    matrix[:,i]+=flow_guide_weight*distance[yy,xx]**2
        else:matrix=np.column_stack([costs[c][yy,xx] for c in labels])
        assignment,solver=partition(matrix,[budgets[c] for c in labels],iterations)
        for index,c in enumerate(labels):
            result[c]=set(zip((xx[assignment==index]+origin[0]).tolist(),(yy[assignment==index]+origin[1]).tolist()))
            assigned.update(result[c])
        records.append(dict(components=labels,envelope=envelope,solver=solver))
    del costs
    island_shifts={}
    if float_islands:
        from shape_placement import place
        blocked={p for x,y in assigned for p in [(x,y),(x+1,y),(x-1,y),(x,y+1),(x,y-1)]}
        for c in sorted(fixed,key=lambda c:(-budgets[c],c)):
            centre=np.mean(list(tiles[c]),axis=0)
            moved=place(tiles[c],centre,blocked);result[c]=moved
            island_shifts[c]=(np.mean(list(moved),axis=0)-centre).tolist()
            blocked.update(p for x,y in moved for p in [(x,y),(x+1,y),(x-1,y),(x,y+1),(x,y-1)])
    if any(len(result[c])!=budgets[c] for c in tiles):raise AssertionError('Capacity changed')
    if sum(map(len,result.values()))!=len(set().union(*result.values())):raise AssertionError('Overlapping cells')
    disconnected={c:n for c,points in result.items() if (n:=connectivity(points))!=1}
    holed={c:n for c,points in result.items() if (n:=holes(points))}
    record=dict(method='Capacity partition of a shared footprint; entropy-smoothed dual then greedy residual correction',sigma=sigma,guide=guide if not power else None,anchor=anchor if not power else None,cost='uniform squared centre distance' if power else 'outline and area-normalized centre distance',guide_layout=str(guide_layout) if guide_layout else None,guide_alignment=alignment,sites=str(sites) if sites else None,maximum_iterations_per_stage=iterations,by_landmass=by_landmass,dock_landmasses=dock_landmasses,flow_geometry=str(flow_geometry) if flow_geometry else None,flow=flow,flow_guide_weight=flow_guide_weight,flow_guide_cost='Weighted squared distance from the raw flow-region raster, added to uniform squared site distance' if flow_guide_weight else None,partitions=records,fixed_components=0 if float_islands else len(fixed),translated_islands=island_shifts,float_islands=float_islands,disconnected_components=disconnected,components_with_holes=holed,inputs=source_hashes,scripts=script_hashes,elapsed_seconds=time.monotonic()-started,limit='Diagnostic only. No connectivity, border, or hole constraint. Exact counts and footprint occupancy are not approval. Residual correction is greedy, not an optimality certificate. The footprint can remove real coasts or fill real water.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='partition-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        write_cells(temp/'envelope.csv',target,origin)
        record['cells_sha256']=digest(temp/'cells.csv');record['envelope_sha256']=digest(temp/'envelope.csv')
        (temp/'partition.json').write_text(json.dumps(record,indent=2)+'\n')
        (temp/'complete.txt').write_text('mode=capacity-partition\ncounts=exact\ncontacts=unconstrained\ntopology=unchecked-by-solver\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    for name,default in [('sigma',8.),('guide',4.),('anchor',.05)]:parser.add_argument('--'+name,type=float,default=default)
    parser.add_argument('--iterations',type=int,default=300)
    parser.add_argument('--guide-layout',type=Path)
    parser.add_argument('--sites',type=Path,help='CSV of projected component sites; align to the starting or flow raster by translation and positive uniform scale')
    parser.add_argument('--flow-geometry',type=Path,help='Use continuous geometry for the footprint and sites, with original budgets')
    parser.add_argument('--flow-guide-weight',type=float,default=0.,help='Add squared distance from each raw flow region to the power cost')
    parser.add_argument('--flow-stretch',type=float,default=1.,help='Area-preserving horizontal stretch of the flow footprint and sites')
    parser.add_argument('--power',action='store_true',help='Use uniform squared centre distance instead of outline costs')
    parser.add_argument('--dock-landmasses',action='store_true',help='Translate disconnected target pieces within each source land-border group until they touch; add no connector cells')
    parser.add_argument('--float-islands',action='store_true',help='Do not reserve isolated island cells inside the target; translate intact islands outside the completed mainland')
    parser.add_argument('--by-landmass',action='store_true',help='Partition each connected source land-border group separately')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
