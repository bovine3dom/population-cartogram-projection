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

from review_layout import load, read_csv, connectivity, holes
from shape_placement import place_all
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
        self.order=None;self.order_weight=0.
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

    def pair_energy_gradient(self,a,b,positions):
        depth,normal=self.penetration(a,b,positions)
        return .5*self.collision*depth*depth,self.collision*depth*normal

    def objective(self,flat):
        positions=flat.reshape(-1,2);difference=positions-self.initial
        value=.5*self.anchor*np.sum(difference*difference);gradient=self.anchor*difference
        if len(self.edges):
            a,b=self.edges.T;difference=positions[b]-positions[a]-self.targets
            force=self.spring*self.weights[:,None]*difference
            value+=.5*np.sum(force*difference);np.add.at(gradient,a,-force);np.add.at(gradient,b,force)
        if self.order is not None:
            energy,force=self.order.objective(positions)
            value+=self.order_weight*energy;gradient+=self.order_weight*force
        if len(self.pairs):
            a,b=self.pairs.T;low=positions+self.low;high=positions+self.high
            candidates=self.pairs[np.all((high[a]+self.gap>low[b]) & (high[b]+self.gap>low[a]),axis=1)]
            for a,b in candidates:
                energy,force=self.pair_energy_gradient(int(a),int(b),positions)
                value+=energy;gradient[a]+=force;gradient[b]-=force
        return float(value),gradient.ravel()


def weight_springs(state,rows):
    masses=np.array([float(rows[c]['group_population']) for c in state.labels])
    mean=masses.sum()/len({rows[c]['country_id'] for c in state.labels})
    if mean<=0:raise ValueError('Population weights require positive total population')
    if len(state.edges):
        a,b=state.edges.T
        state.weights*=np.clip(np.sqrt(np.minimum(masses[a],masses[b])/mean),.02,5.)


def run(inputs,templates,output,spacing=1.,iterations=3000,collision=100.,spring=1.,anchor=.01,spatial=.03,gap=.8,source_polygons=None,raster=False,no_false_contacts=False,start_from_templates=False,smooth_collision=False,ocean_scale=0.,order_weight=0.,coast_anchors=False,local_order=0.,mass_weighted=False):
    if output.exists():raise ValueError('Output already exists')
    if iterations<1 or spacing<=0 or any(not math.isfinite(v) or v<0 for v in [spacing,collision,spring,anchor,spatial,gap,ocean_scale,order_weight,local_order]):raise ValueError('Invalid stress settings')
    scripts=[Path(__file__),Path(__file__).with_name('shape_placement.py')]
    if source_polygons or raster or smooth_collision:scripts.extend(Path(__file__).with_name(name) for name in ['concave_stress.py','prepare_flow.py'])
    if raster or smooth_collision:scripts.append(Path(__file__).with_name('raster_stress.py'))
    if smooth_collision:scripts.append(Path(__file__).with_name('smooth_raster_stress.py'))
    if order_weight:scripts.append(Path(__file__).with_name('geographic_order.py'))
    if coast_anchors:
        if not source_polygons:raise ValueError('Coast anchors require source polygons')
        scripts.append(Path(__file__).with_name('coast_anchors.py'))
    script_hashes={p.name:digest(p) for p in scripts}
    input_hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'validated.wkt',inputs/'geographic-contacts.csv',templates/'cells.csv']+([source_polygons] if source_polygons else [])}
    rows,tiles,_=load(inputs,templates)
    if any(len(tiles[c])!=int(rows[c]['tiles']) or connectivity(tiles[c])!=1 or holes(tiles[c]) for c in rows):raise ValueError('Invalid templates')
    lines=(inputs/'validated.wkt').read_text().splitlines()
    polygons={lines[i].split('\t')[1]:Polygon([tuple(map(float,p.split())) for p in lines[i+1].split('\t')]) for i in range(2,len(lines),3)}
    scale=spacing*math.sqrt(sum(map(len,tiles.values()))/sum(p.area for p in polygons.values()))
    centres={c:np.array([p.centroid.x,p.centroid.y])*scale for c,p in polygons.items()}
    required={tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true'}
    started=time.monotonic()
    state_type=Stress
    if source_polygons:
        from concave_stress import ConcaveStress
        state_type=ConcaveStress
    if smooth_collision:raster=True
    if raster:
        from raster_stress import RasterStress
        state_type=RasterStress
    if smooth_collision:
        from smooth_raster_stress import SmoothRasterStress
        state_type=SmoothRasterStress
    state=state_type(tiles,centres,required,collision,spring,anchor,spatial,gap)
    if source_polygons:state.border_targets(source_polygons,tiles,required)
    if order_weight:
        from geographic_order import GeographicOrder
        state.order=GeographicOrder(state.labels,rows,margin=.01*math.sqrt(sum(map(len,tiles.values()))),local_degrees=local_order,mass_weighted=mass_weighted);state.order_weight=order_weight
    ocean_length=ocean_scale*math.sqrt(sum(map(len,tiles.values())))
    if ocean_length:
        for index,(a,b) in enumerate(state.edges):
            if (state.labels[a],state.labels[b]) in required:continue
            distance=np.linalg.norm(state.targets[index])
            if distance:state.targets[index]*=ocean_length*np.arcsinh(distance/ocean_length)/distance
    coast_count=0
    if coast_anchors:
        from coast_anchors import apply
        coast_count=apply(state,source_polygons,tiles,required,scale,ocean_length)
    if mass_weighted:weight_springs(state,rows)
    history=[]
    def callback(x):
        energy,_=state.objective(x);history.append(dict(iteration=len(history)+1,energy=energy))
        if len(history)%25==0:print(f'Stress iteration {len(history)}: {energy:.6f}',flush=True)
    start=np.array([np.mean(list(tiles[c]),axis=0) for c in state.labels]) if start_from_templates else state.initial
    initial=state.objective(start.ravel())[0]
    result=minimize(state.objective,start.ravel(),jac=True,method='L-BFGS-B',callback=callback,
        options=dict(maxiter=iterations,maxfun=iterations*30,maxls=40,ftol=1e-11,gtol=1e-5,maxcor=20))
    if not np.isfinite(result.x).all() or result.fun>initial+1e-6:raise ValueError('Invalid stress result')
    positions=result.x.reshape(-1,2)
    placed=place_all(tiles,{c:positions[state.ids[c]] for c in tiles},required if no_false_contacts else None,gap>=1)
    displacements=[float(np.linalg.norm(np.mean(list(placed[c]),axis=0)-positions[state.ids[c]])) for c in tiles]
    metadata=dict(method='Geographic spring displacement with collision penalties, followed by exact integer translation; no border paths',
        collision_geometry='signed-distance raster' if raster else 'convex pieces' if source_polygons else 'convex hulls',border_anchors=bool(source_polygons),
        no_false_contacts=no_false_contacts,start_from_templates=start_from_templates,smooth_collision=smooth_collision,
        ocean_scale_fraction=ocean_scale,ocean_scale_tiles=ocean_length,
        order_weight=order_weight,local_order_degrees=local_order,order_constraints=state.order.count if state.order else 0,
        coast_anchors=coast_anchors,coast_anchor_pairs=coast_count,mass_weighted=mass_weighted,
        maximum_integer_placement_shift=max(displacements),integer_placement_shifts_over_two_tiles=sum(d>2 for d in displacements),
        spacing=spacing,maximum_iterations=iterations,iterations=int(result.nit),success=bool(result.success),message=str(result.message),
        collision=collision,spring=spring,anchor=anchor,spatial=spatial,gap=gap,initial_energy=initial,final_energy=float(result.fun),
        elapsed_seconds=time.monotonic()-started,
        inputs=input_hashes,scripts=script_hashes,
        limit='Collision geometry is approximate. Convex pieces use outlines simplified by 0.75 tile; raster penalties use bilinear interpolation or a 0.6-tile Gaussian filter with cubic splines. Soft penalties do not prove that continuous shapes are disjoint. Final integer placement prevents overlap but can change order and contacts. No tile shape is distorted; input holes remain omitted.')
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
    for name,default in [('spacing',1.),('collision',100.),('spring',1.),('anchor',.01),('spatial',.03),('gap',.8),('ocean-scale',0.),('order-weight',0.),('local-order',0.)]:parser.add_argument('--'+name,type=float,default=default)
    parser.add_argument('--source-polygons',type=Path,help='Use concave collision pieces and anchors on actual source borders')
    for name in ['raster','no-false-contacts','start-from-templates','smooth-collision','coast-anchors','mass-weighted']:parser.add_argument('--'+name,action='store_true')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
