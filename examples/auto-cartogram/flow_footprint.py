"""Use continuous flow only for a land footprint and country sites."""
import math

import numpy as np
from shapely import affinity, contains_xy

from review_flow import read_shapes
from review_layout import NEIGHBOURS
from shape_placement import place


def prepare(path,templates,fixed,budgets):
    geometries=read_shapes(path)
    if set(geometries)!=set(templates):raise ValueError('Flow geometry component labels differ')
    scale=math.sqrt(sum(budgets.values())/sum(g.area for g in geometries.values()))
    geometries={c:affinity.scale(g,scale,scale,origin=(0,0)) for c,g in geometries.items()}
    centres={c:(g.centroid.x,g.centroid.y) for c,g in geometries.items()}
    tiles={};fallback=[]
    for c in sorted(set(templates)-fixed):
        g=geometries[c];xmin,ymin,xmax,ymax=g.bounds
        yy,xx=np.mgrid[math.floor(ymin):math.ceil(ymax)+1,math.floor(xmin):math.ceil(xmax)+1]
        mask=contains_xy(g,xx,yy)
        points=set(zip(xx[mask].tolist(),yy[mask].tolist()))
        if not points:
            p=g.representative_point();points={(round(p.x),round(p.y))};fallback.append(c)
        tiles[c]=points
    blocked={q for points in tiles.values() for x,y in points for q in [(x,y)]+[(x+dx,y+dy) for dx,dy in NEIGHBOURS]}
    for c in sorted(fixed,key=lambda c:(-budgets[c],c)):
        tiles[c]=place(templates[c],centres[c],blocked)
        blocked.update(q for x,y in tiles[c] for q in [(x,y)]+[(x+dx,y+dy) for dx,dy in NEIGHBOURS])
    return tiles,centres,dict(scale=scale,subtile_fallback_components=fallback,
        movable_raster_cells=sum(len(tiles[c]) for c in set(tiles)-fixed),
        requested_movable_cells=sum(budgets[c] for c in set(tiles)-fixed),
        limit='Flow supplies sites and a raster footprint, not final country boundaries or quotas. Empty raster components use one representative sample. Raster samples may overlap. Each target landmass receives the original requested budget. Isolated source-shaped templates are translated away from the raw mainland footprint before partitioning.')
