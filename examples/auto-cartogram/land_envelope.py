#!/usr/bin/env python3
"""Build an area-matched land target from a smoothed automatic layout."""
import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_dilation, gaussian_filter, label
from scipy.signal import fftconvolve

from review_layout import load, read_csv
from review_gaps import draw
from save_review import digest


def dock_parts(target,blocked):
    """Translate separate target pieces until they touch; add no path cells."""
    parts,count=label(target);sizes=np.bincount(parts.ravel());result=np.zeros_like(target);moves=[]
    for index in sorted(range(1,count+1),key=lambda i:(-sizes[i],i)):
        yy,xx=np.nonzero(parts==index);left=int(xx.min());bottom=int(yy.min())
        if not result.any():
            result[yy,xx]=True;moves.append(dict(part=index,cells=len(xx),dx=0,dy=0));continue
        kernel=np.zeros((int(yy.max())-bottom+1,int(xx.max())-left+1),dtype=float)
        kernel[yy-bottom,xx-left]=1
        collisions=fftconvolve((result|blocked).astype(float),kernel[::-1,::-1],mode='valid')
        shore=binary_dilation(result)&~result
        contacts=fftconvolve(shore.astype(float),kernel[::-1,::-1],mode='valid')
        ys,xs=np.nonzero((collisions<.5)&(contacts>.5))
        if not len(xs):raise ValueError('No space to dock target piece')
        distance=(xs-left)**2+(ys-bottom)**2
        choice=np.lexsort((xs,ys,-np.rint(contacts[ys,xs]),distance))[0]
        dx=int(xs[choice])-left;dy=int(ys[choice])-bottom
        result[yy+dy,xx+dx]=True;moves.append(dict(part=index,cells=len(xx),dx=dx,dy=dy))
    if result.sum()!=target.sum() or label(result)[1]!=1 or np.any(result&blocked):raise AssertionError('Invalid docked target')
    return result,moves


def build(tiles,fixed,origin,shape,sigma,count=None,dock=False):
    if not math.isfinite(sigma) or sigma<=0:raise ValueError('Use a positive envelope scale')
    land=np.zeros(shape,dtype=bool);blocked=np.zeros(shape,dtype=bool)
    for c,points in tiles.items():
        for x,y in points:
            if c not in fixed:land[y-origin[1],x-origin[0]]=True
            else:
                for dx,dy in [(0,0),(1,0),(-1,0),(0,1),(0,-1)]:
                    ix=x+dx-origin[0];iy=y+dy-origin[1]
                    if 0<=iy<shape[0] and 0<=ix<shape[1]:blocked[iy,ix]=True
    sampled=int(land.sum())
    if not sampled:raise ValueError('No movable land cells')
    if count is None:count=sampled
    if not isinstance(count,(int,np.integer)) or count<1 or count>land.size:raise ValueError('Invalid target area')
    score=gaussian_filter(land.astype(float),sigma=sigma,mode='constant');score[blocked]=-np.inf
    order=np.lexsort((np.arange(score.size),-score.ravel()))[:count]
    if not np.isfinite(score.ravel()[order]).all():raise ValueError('Insufficient unblocked target cells')
    target=np.zeros(shape,dtype=bool);target.ravel()[order]=True
    original_parts=int(label(target)[1]);moves=[]
    if dock:target,moves=dock_parts(target,blocked)
    return target,dict(dock_parts=dock,original_connected_parts=original_parts,part_translations=moves,target_cells=count,sampled_land_cells=sampled,initial_empty_target_cells=int((target&~land).sum()),
        target_connected_parts=int(label(target)[1]),sigma_tiles=sigma,
        limit='A fixed experimental occupancy target, not a source coastline. Gaussian smoothing and an area quota move the outer boundary as well as filling gaps. The target can have several parts. Fixed islands and their side-neighbour cells are excluded. Countries keep separate budgets in the deformation solver.')


def write_cells(path,target,origin):
    with path.open('w',newline='') as stream:
        writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
        yy,xx=np.nonzero(target);writer.writerows(('target',int(x)+origin[0],int(y)+origin[1]) for y,x in zip(yy,xx))


def run(inputs,layout,output,sigma=8.):
    if output.exists():raise ValueError('Output already exists')
    if not math.isfinite(sigma) or sigma<=0:raise ValueError('Use a positive envelope scale')
    hashes={str(p):digest(p) for p in [inputs/'groups.csv',inputs/'geographic-contacts.csv',layout/'cells.csv']}
    scripts={p.name:digest(p) for p in [Path(__file__),Path(__file__).with_name('review_gaps.py')]}
    rows,tiles,owners=load(inputs,layout)
    if any(len(tiles[c])!=int(rows[c]['tiles']) for c in tiles):raise ValueError('Envelope preview requires exact input counts')
    contacts=read_csv(inputs/'geographic-contacts.csv')
    fixed=set(tiles)-{r[k] for r in contacts if r['both_represented']=='true' for k in ['a','b']}
    margin=max(64,math.ceil(4*sigma)+2);origin=(min(x for x,y in owners)-margin,min(y for x,y in owners)-margin)
    shape=(max(y for x,y in owners)-origin[1]+margin+1,max(x for x,y in owners)-origin[0]+margin+1)
    target,report=build(tiles,fixed,origin,shape,sigma)
    land=np.zeros(shape,dtype=bool);movable=np.zeros(shape,dtype=bool)
    for (x,y),c in owners.items():
        land[y-origin[1],x-origin[0]]=True
        if c not in fixed:movable[y-origin[1],x-origin[0]]=True
    report.update(inputs=hashes,scripts=scripts)
    output.mkdir(parents=True);write_cells(output/'envelope.csv',target,origin)
    (output/'envelope.json').write_text(json.dumps(report,indent=2)+'\n')
    draw(output/'envelope.svg',land,movable&~target,{0:target&~land},'Area-matched land envelope',
        legend='Grey: existing tiles. Red: movable land outside the target. Orange: empty target cells. Isolated islands stay fixed.')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--sigma',type=float,default=8.)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
