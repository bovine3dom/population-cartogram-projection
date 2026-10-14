#!/usr/bin/env python3
"""Translate intact shapes with geographic springs and convex-hull repulsion."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile
import time

import numpy as np
from scipy.optimize import minimize
from scipy.spatial import ConvexHull, Delaunay
from shapely.geometry import Polygon

from review_layout import load, read_csv, connectivity, holes, NEIGHBOURS
from shape_placement import place
from save_review import digest


def tile_hull(cells):
    points=np.array(sorted(cells),dtype=float);centre=points.mean(axis=0)
    corners=np.concatenate([points+offset for offset in [(-.5,-.5),(-.5,.5),(.5,-.5),(.5,.5)]])-centre
    hull=corners[ConvexHull(corners).vertices]
    edges=np.roll(hull,-1,axis=0)-hull
    normals=np.column_stack((-edges[:,1],edges[:,0]));normals/=np.linalg.norm(normals,axis=1)[:,None]
    return hull,normals


class Stress:
    def __init__(self,tiles,centres,required,collision=100.,spring=1.,anchor=.01,spatial=.03,gap=.8):
        self.labels=sorted(tiles);self.ids={c:i for i,c in enumerate(self.labels)}
        self.initial=np.array([centres[c] for c in self.labels]);self.hulls=[tile_hull(tiles[c]) for c in self.labels]
        self.low=np.array([h.min(axis=0) for h,n in self.hulls]);self.high=np.array([h.max(axis=0) for h,n in self.hulls])
        self.pairs=np.array(np.triu_indices(len(self.labels),1)).T;self.cache={}
        self.collision=collision;self.spring=spring;self.anchor=anchor;self.gap=gap
        edges={tuple(sorted((self.ids[a],self.ids[b]))):1. for a,b in required}
        if len(self.labels)>=3:
            for triangle in Delaunay(self.initial).simplices:
                for i,j in [(0,1),(1,2),(2,0)]:edges.setdefault(tuple(sorted((int(triangle[i]),int(triangle[j])))),spatial)
        elif len(self.labels)==2:edges.setdefault((0,1),spatial)
        self.edges=[];self.targets=[];self.weights=[]
        for (a,b),weight in sorted(edges.items()):
            difference=self.initial[b]-self.initial[a];distance=np.linalg.norm(difference)
            direction=difference/distance if distance>1e-10 else np.array([1.,0.])
            if (self.labels[a],self.labels[b]) in required:
                distance=(self.hulls[a][0]@direction).max()-(self.hulls[b][0]@direction).min()+gap
            self.edges.append((a,b));self.targets.append(direction*distance);self.weights.append(weight)
        self.edges=np.array(self.edges,dtype=int).reshape(-1,2);self.targets=np.array(self.targets).reshape(-1,2);self.weights=np.array(self.weights)

    def penetration(self,a,b,positions):
        key=(a,b)
        if key not in self.cache:
            ha,na=self.hulls[a];hb,nb=self.hulls[b];axes=np.concatenate((na,nb))
            pa=ha@axes.T;pb=hb@axes.T
            self.cache[key]=(axes,pa.max(axis=0)-pb.min(axis=0),pb.max(axis=0)-pa.min(axis=0))
        axes,left,right=self.cache[key];shift=axes@(positions[a]-positions[b])
        distances=np.concatenate((left+shift+self.gap,right-shift+self.gap))
        index=int(distances.argmin());depth=distances[index]
        if depth<=0:return 0.,np.zeros(2)
        normal=axes[index] if index<len(axes) else -axes[index-len(axes)]
        return float(depth),normal

    def objective(self,flat):
        positions=flat.reshape(-1,2);difference=positions-self.initial
        value=.5*self.anchor*np.sum(difference*difference);gradient=self.anchor*difference
        if len(self.edges):
            a,b=self.edges.T;difference=positions[b]-positions[a]-self.targets
            force=self.spring*self.weights[:,None]*difference
            value+=.5*np.sum(force*difference);np.add.at(gradient,a,-force);np.add.at(gradient,b,force)
        if len(self.pairs):
            a,b=self.pairs.T;low=positions+self.low;high=positions+self.high
            candidates=self.pairs[np.all((high[a]+self.gap>low[b]) & (high[b]+self.gap>low[a]),axis=1)]
            for a,b in candidates:
                depth,normal=self.penetration(int(a),int(b),positions)
                value+=.5*self.collision*depth*depth
                force=self.collision*depth*normal;gradient[a]+=force;gradient[b]-=force
        return float(value),gradient.ravel()


def run(inputs,templates,output,spacing=1.,iterations=3000,collision=100.,spring=1.,anchor=.01,spatial=.03,gap=.8):
    if output.exists():raise ValueError('Output already exists')
    if iterations<1 or spacing<=0 or any(not math.isfinite(v) or v<0 for v in [spacing,collision,spring,anchor,spatial,gap]):raise ValueError('Invalid stress settings')
    rows,tiles,_=load(inputs,templates)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 or holes(tiles[c]) for c in rows):raise ValueError('Invalid templates')
    lines=(inputs/'validated.wkt').read_text().splitlines()
    polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
    scale=spacing*math.sqrt(sum(map(len,tiles.values()))/sum(p.area for p in polygons.values()))
    centres={c:np.array([p.centroid.x,p.centroid.y])*scale for c,p in polygons.items()}
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    state=Stress(tiles,centres,required,collision,spring,anchor,spatial,gap)
    started=time.monotonic();history=[]
    def callback(x):
        energy,_=state.objective(x);history.append(dict(iteration=len(history)+1,energy=energy))
        if len(history)%25==0:print(f'Stress iteration {len(history)}: {energy:.6f}',flush=True)
    initial=state.objective(state.initial.ravel())[0]
    result=minimize(state.objective,state.initial.ravel(),jac=True,method='L-BFGS-B',callback=callback,
        options=dict(maxiter=iterations,maxfun=iterations*30,maxls=40,ftol=1e-11,gtol=1e-5,maxcor=20))
    if not np.isfinite(result.x).all() or result.fun>initial+1e-6:raise ValueError('Invalid stress result')
    positions=result.x.reshape(-1,2);blocked=set();placed={}
    for c in sorted(tiles,key=lambda c:(-len(tiles[c]),c)):
        moved=place(tiles[c],positions[state.ids[c]],blocked);placed[c]=moved;blocked.update(moved)
        if gap>=1:blocked.update((x+dx,y+dy) for x,y in moved for dx,dy in NEIGHBOURS)
    scripts=[Path(__file__),Path(__file__).with_name('shape_placement.py')]
    metadata=dict(method='Geographic spring displacement with convex-hull collision penalties, followed by exact integer translation; no border paths',
        spacing=spacing,maximum_iterations=iterations,iterations=int(result.nit),success=bool(result.success),message=str(result.message),
        collision=collision,spring=spring,anchor=anchor,spatial=spatial,gap=gap,initial_energy=initial,final_energy=float(result.fun),
        elapsed_seconds=time.monotonic()-started,
        inputs={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'validated.wkt',inputs/'geographic-contacts.csv',templates/'cells.csv']},
        scripts={p.name:digest(p) for p in scripts},
        limit='Convex hulls overestimate some shapes. Soft penalties do not prove that the continuous hulls are disjoint. Final integer placement prevents overlap but can change order and contacts. No shape is distorted; input holes remain omitted.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='stress-',dir=output.parent))
    try:
        with (temp/'cells.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
            for c,points in sorted(placed.items()):writer.writerows((c,x,y) for x,y in sorted(points))
        with (temp/'centres.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','original_x','original_y','optimized_x','optimized_y'])
            writer.writerows((c,*state.initial[i],*positions[i]) for i,c in enumerate(state.labels))
        with (temp/'history.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=['iteration','energy']);writer.writeheader();writer.writerows(history)
        (temp/'stress.json').write_text(json.dumps(metadata,indent=2)+'\n')
        (temp/'complete.txt').write_text('mode=shape-stress\ncounts=exact\ncontacts=not-required\n')
        temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return metadata


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','templates','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--iterations',type=int,default=3000)
    for name,default in [('spacing',1.),('collision',100.),('spring',1.),('anchor',.01),('spatial',.03),('gap',.8)]:parser.add_argument('--'+name,type=float,default=default)
    args=parser.parse_args();print(json.dumps(run(args.inputs,args.templates,args.output,args.spacing,args.iterations,args.collision,args.spring,args.anchor,args.spatial,args.gap),indent=2))
