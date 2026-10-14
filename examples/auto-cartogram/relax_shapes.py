#!/usr/bin/env python3
"""Reduce position energy with exact translations and hard collision checks."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import tempfile
import time

import numpy as np

from concave_stress import ConcaveStress
from geographic_order import GeographicOrder
from review_layout import load, read_csv, connectivity, holes
from save_review import digest
from shape_placement import place
from shape_stress import Stress


def conditional(state,index,positions):
    """Return the exact separable conditional cost, apart from a constant."""
    weight=state.anchor;total=weight*state.initial[index].copy()
    for edge,(a,b) in enumerate(state.edges):
        if index not in (a,b):continue
        w=state.spring*state.weights[edge]
        target=positions[b]-state.targets[edge] if index==a else positions[a]+state.targets[edge]
        weight+=w;total+=w*target
    if weight<=0:raise ValueError('A component has no position anchor')
    mean=total/weight;hinges=[]
    for axis in range(2):
        coordinate=2*index+axis
        if state.order is None:
            hinges.append((np.array([]),np.array([]),np.array([])));continue
        order=state.order;left=order.a==coordinate;right=order.b==coordinate
        coefficients=np.concatenate((order.sign[left],-order.sign[right]))
        constants=np.concatenate((order.margin[left]-order.sign[left]*positions.ravel()[order.b[left]],
                                  order.margin[right]+order.sign[right]*positions.ravel()[order.a[right]]))
        weights=state.order_weight*np.concatenate((order.weight[left],order.weight[right]))
        hinges.append((coefficients,constants,weights))
    def cost(point):
        value=.5*weight*np.sum((point-mean)**2)
        for axis,(a,b,w) in enumerate(hinges):value+=.5*np.dot(w,np.maximum(a*point[axis]+b,0.)**2)
        return float(value)
    optimum=mean.copy()
    for axis,(a,b,w) in enumerate(hinges):
        if not len(a):continue
        knots=-b/a;lo=min(mean[axis],knots.min());hi=max(mean[axis],knots.max())
        for _ in range(50):
            mid=(lo+hi)/2;gradient=weight*(mid-mean[axis])+np.dot(w*a,np.maximum(a*mid+b,0.))
            if gradient>0:hi=mid
            else:lo=mid
        optimum[axis]=(lo+hi)/2
    return optimum,cost


def relax(state,tiles,required,rounds):
    tiles={c:set(points) for c,points in tiles.items()}
    positions=np.array([np.mean(list(tiles[c]),axis=0) for c in state.labels])
    state.pairs=np.empty((0,2),dtype=int)
    occupied=set().union(*tiles.values())
    halo=lambda cells:{(x+dx,y+dy) for x,y in cells for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]}-cells
    halos={c:halo(points) for c,points in tiles.items()};history=[]
    previous=state.objective(positions.ravel())[0]
    for iteration in range(rounds):
        moves=0
        for c in sorted(tiles,key=lambda c:(len(tiles[c]),c)):
            i=state.ids[c];target,cost=conditional(state,i,positions)
            blocked=occupied-tiles[c]
            for other,points in halos.items():
                if other!=c and tuple(sorted((c,other))) not in required:blocked.update(points)
            candidates=[place(tiles[c],target,blocked)]
            candidates.extend({(x+dx,y+dy) for x,y in tiles[c]} for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)])
            best=tiles[c];best_position=positions[i];best_cost=cost(best_position)
            for candidate in candidates:
                if candidate & blocked:continue
                centre=np.mean(list(candidate),axis=0);value=cost(centre)
                if value<best_cost-1e-8:best=candidate;best_position=centre;best_cost=value
            if best is tiles[c]:continue
            occupied.difference_update(tiles[c]);occupied.update(best);tiles[c]=best;halos[c]=halo(best);positions[i]=best_position;moves+=1
        energy=state.objective(positions.ravel())[0]
        if energy>previous+1e-6:raise AssertionError('Position energy increased')
        history.append(dict(round=iteration+1,moves=moves,energy=energy));previous=energy
        print(f'Relaxation round {iteration+1}: {moves} moves, energy {energy:.6f}',flush=True)
        if not moves:break
    return tiles,history


def run(inputs,layout,output,polygons,rounds=30):
    if output.exists() or rounds<1:raise ValueError('Use a new output and positive round count')
    started=time.monotonic();metadata=json.loads((layout/'stress.json').read_text())
    files=[inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv',layout/'stress.json',layout/'centres.csv',polygons]
    hashes={str(p):digest(p) for p in files}
    scripts={p.name:digest(p) for p in [Path(__file__)]+[Path(__file__).with_name(n) for n in ['shape_stress.py','shape_placement.py','concave_stress.py','geographic_order.py','coast_anchors.py','prepare_flow.py']]}
    if metadata.get('coast_anchors') and metadata['scripts']['coast_anchors.py']!=scripts['coast_anchors.py']:raise ValueError('Coast target source differs; use the corrected run')
    rows,tiles,owner=load(inputs,layout)
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    actual={tuple(sorted((c,owner[q]))) for (x,y),c in owner.items() for q in [(x+1,y),(x,y+1)] if q in owner and owner[q]!=c}
    if actual-required:raise ValueError('Initial layout has false contacts')
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 or holes(tiles[c]) for c in rows):raise ValueError('Invalid input shapes')
    centres={r['component_id']:np.array([float(r['original_x']),float(r['original_y'])]) for r in read_csv(layout/'centres.csv')}
    state=Stress(tiles,centres,required,**{k:metadata[k] for k in ['collision','spring','anchor','spatial','gap']})
    if metadata['border_anchors']:ConcaveStress.border_targets(state,polygons,tiles,required)
    ocean_length=metadata['ocean_scale_tiles']
    if ocean_length:
        for index,(a,b) in enumerate(state.edges):
            if (state.labels[a],state.labels[b]) in required:continue
            distance=np.linalg.norm(state.targets[index])
            if distance:state.targets[index]*=ocean_length*np.arcsinh(distance/ocean_length)/distance
    if metadata.get('coast_anchors'):
        from coast_anchors import apply
        from shapely.geometry import Polygon
        lines=(inputs/'validated.wkt').read_text().splitlines()
        area=sum(Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]).area for i in range(2,len(lines),3))
        scale=metadata['spacing']*np.sqrt(sum(map(len,tiles.values()))/area)
        hashes[str(inputs/'validated.wkt')]=digest(inputs/'validated.wkt')
        apply(state,polygons,tiles,required,scale,ocean_length)
    if metadata['order_weight']:
        state.order=GeographicOrder(state.labels,rows,margin=.01*np.sqrt(sum(map(len,tiles.values()))));state.order_weight=metadata['order_weight']
    state.pairs=np.empty((0,2),dtype=int)
    initial=state.objective(np.array([np.mean(list(tiles[c]),axis=0) for c in state.labels]).ravel())[0]
    result,history=relax(state,tiles,required,rounds)
    report=dict(method='Conditional position relaxation with exact integer translations; no required contacts or shape changes',
        initial_energy=initial,final_energy=history[-1]['energy'],rounds=len(history),history=history,
        elapsed_seconds=time.monotonic()-started,inputs=hashes,scripts=scripts,
        limit='Lower position energy does not prove geographic correctness. Missing borders remain permitted. No new population transport is approved.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='relax-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(result.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        (temp/'relax.json').write_text(json.dumps(report,indent=2)+'\n')
        (temp/'complete.txt').write_text('mode=shape-placement\ncounts=exact\ncontacts=not-required\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output','polygons']:parser.add_argument(name,type=Path)
    parser.add_argument('--rounds',type=int,default=30)
    args=parser.parse_args();run(args.inputs,args.layout,args.output,args.polygons,args.rounds)
