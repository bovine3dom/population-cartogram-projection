"""Use continuous flow only for a land footprint and country sites."""
import math

import numpy as np
from shapely import affinity, contains_xy

from review_flow import read_shapes
from review_layout import NEIGHBOURS
from shape_placement import place


def prepare(path,templates,fixed,budgets,stretch=1.,projected_sites=None,sites_in_flow=False):
    if not math.isfinite(stretch) or stretch<=0:raise ValueError('Use a positive flow stretch')
    if sites_in_flow and (projected_sites is None or set(projected_sites)!=set(templates)):raise ValueError('Flow-coordinate sites require every component')
    geometries=read_shapes(path)
    missing=set(templates)-set(geometries)
    if set(geometries)-set(templates) or missing-fixed or (missing and projected_sites is None):raise ValueError('Flow geometry component labels differ; missing isolated components require projected sites')
    scale=math.sqrt(sum(budgets[c] for c in geometries)/sum(g.area for g in geometries.values()))
    geometries={c:affinity.scale(g,scale*stretch,scale/stretch,origin=(0,0)) for c,g in geometries.items()}
    centres={c:(g.centroid.x,g.centroid.y) for c,g in geometries.items()}
    island_alignment=None
    if sites_in_flow:
        centres={c:tuple(np.asarray(point)*[scale*stretch,scale/stretch]) for c,point in projected_sites.items()}
        island_alignment=dict(x_scale=scale*stretch,y_scale=scale/stretch,translation=[0.,0.],rotation_degrees=0)
    elif missing:
        from compact_regions import fit_guide_centres
        if set(projected_sites)!=set(templates):raise ValueError('Projected site labels differ')
        _,island_alignment=fit_guide_centres({c:{centres[c]} for c in geometries},{c:{projected_sites[c]} for c in geometries},budgets)
        for c in missing:centres[c]=tuple(np.asarray(projected_sites[c])*island_alignment['scale']+island_alignment['translation'])
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
    return tiles,centres,dict(scale=scale,area_preserving_stretch=stretch,x_scale=scale*stretch,y_scale=scale/stretch,subtile_fallback_components=fallback,
        excluded_isolated_components=sorted(missing),island_site_alignment=island_alignment,sites_in_flow=sites_in_flow,
        movable_raster_cells=sum(len(tiles[c]) for c in set(tiles)-fixed),
        requested_movable_cells=sum(budgets[c] for c in set(tiles)-fixed),
        limit='Flow supplies sites and a raster footprint, not final country boundaries or quotas. Empty raster components use one representative sample. Raster samples may overlap. Each target landmass receives the original requested budget. Isolated source-shaped templates are translated away from the raw mainland footprint before partitioning.')
