#!/usr/bin/env python3
"""Map projected population sites through a saved planar mesh."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.spatial import Delaunay

from population_sites import read_sites
from review_layout import read_csv
from save_review import digest


def interpolate(initial,transformed,triangles,points):
    initial,transformed,points=[np.asarray(a,dtype=float) for a in [initial,transformed,points]]
    triangles=np.asarray(triangles)
    if initial.ndim!=2 or initial.shape[1]!=2 or transformed.shape!=initial.shape or points.ndim!=2 or points.shape[1]!=2 or not all(np.isfinite(a).all() for a in [initial,transformed,points]):raise ValueError('Invalid mesh coordinates')
    mesh=Delaunay(initial)
    if {tuple(sorted(t)) for t in mesh.simplices}!={tuple(sorted(t)) for t in triangles}:raise ValueError('Saved mesh triangulation differs')
    for vertices in [initial,transformed]:
        edges=vertices[mesh.simplices[:,1:]]-vertices[mesh.simplices[:,0,None]]
        if np.any(np.linalg.det(edges)<=0):raise ValueError('Folded mesh')
    cells=mesh.find_simplex(points)
    if np.any(cells<0):raise ValueError('Site outside mesh frame')
    coordinates=np.einsum('nij,nj->ni',mesh.transform[cells,:2],points-mesh.transform[cells,2])
    weights=np.column_stack((coordinates,1-coordinates.sum(axis=1)))
    return np.einsum('ni,nij->nj',weights,transformed[mesh.simplices[cells]])


def run(sites,guide,output,source_scale=1000.):
    if output.exists():raise ValueError('Output already exists')
    if not np.isfinite(source_scale) or source_scale<=0:raise ValueError('Invalid source scale')
    rows=read_csv(sites);labels=[r['component_id'] for r in rows]
    points=np.array(list(read_sites(sites,labels).values()))
    metadata=json.loads((guide/'mesh-guide.json').read_text())['mesh']
    span=float(metadata['span']);centre=np.asarray(metadata['centre'],dtype=float)
    if not np.isfinite(span) or span<=0 or centre.shape!=(2,) or not np.isfinite(centre).all():raise ValueError('Invalid mesh normalization')
    with np.load(guide/'mesh.npz',allow_pickle=False) as mesh:
        mapped=interpolate(mesh['initial'],mesh['transformed'],mesh['triangles'],(points*source_scale-centre)/span)
    for row,point in zip(rows,mapped):row.update(x=float(point[0]),y=float(point[1]))
    report=dict(method='Piecewise affine interpolation through the saved mesh; no site refit',source_scale=source_scale,components=len(rows),coordinate_system='Normalized deformed mesh coordinates, as in geometry.geojson',inputs={str(p):digest(p) for p in [sites,guide/'mesh.npz',guide/'mesh-guide.json']},script_sha256=digest(Path(__file__)),limit='A transformed mean is not the mean of all transformed population cells. Sites can be outside their component outline. Population and component labels do not change.')
    output.mkdir(parents=True)
    with (output/'sites.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    report['sites_sha256']=digest(output/'sites.csv')
    (output/'sites.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['sites','guide','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--source-scale',type=float,default=1000.)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
