#!/usr/bin/env python3
"""Experimental planar mesh guide; final mosaic budgets remain separate."""
import argparse
import json
from pathlib import Path
import time

import numpy as np
from scipy.optimize import OptimizeResult, minimize
from scipy.sparse import coo_matrix
from scipy.spatial import Delaunay, cKDTree
from shapely import STRtree, affinity, union_all
from shapely.geometry import Polygon, mapping

from review_flow import read_shapes
from review_layout import read_csv
from save_review import digest


def edge_matrices(vertices,triangles):
    corners=vertices[triangles]
    return np.stack((corners[:,1]-corners[:,0],corners[:,2]-corners[:,0]),axis=2)


class MeshObjective:
    """Area error and rotation-invariant shape/scale costs from Sargent (2024)."""
    def __init__(self,vertices,triangles,portions,targets,fixed):
        self.vertices=np.asarray(vertices,dtype=float);self.triangles=np.asarray(triangles,dtype=int)
        self.portions=portions.tocsr();self.targets=np.asarray(targets,dtype=float)
        self.free=~np.asarray(fixed,dtype=bool)
        edges=edge_matrices(self.vertices,self.triangles)
        self.areas=np.linalg.det(edges)/2
        if np.any(self.areas<=0) or np.any(self.targets<=0):raise ValueError('Positive mesh areas and targets required')
        self.inverse=np.linalg.inv(edges)
        original=np.asarray(self.portions.sum(axis=1)).ravel()
        if np.any(original<=0):raise ValueError('A region has no mesh area')
        covered=np.asarray(self.portions.sum(axis=0)).ravel();land=covered>0
        self.scale=np.ones(len(triangles))
        self.scale[land]=np.asarray(self.portions.T@(self.targets/original))[land]/covered[land]
        centres=self.vertices[self.triangles].mean(axis=1)
        if np.any(~land):self.scale[~land]=self.scale[np.flatnonzero(land)[cKDTree(centres[land]).query(centres[~land])[1]]]
        self.weight=self.areas*np.where(land,1.,.1)*(.2+.8*self.scale)
        self.normalizer=float(self.targets.sum())

    def unpack(self,values):
        vertices=self.vertices.copy();vertices[self.free]=np.asarray(values).reshape((-1,2));return vertices

    def evaluate(self,values,distortion=.1):
        vertices=self.unpack(values);jacobian=edge_matrices(vertices,self.triangles)@self.inverse
        determinant=np.linalg.det(jacobian)
        if not np.isfinite(jacobian).all():return float('inf'),np.zeros_like(values)
        # A quadratic extension of 1/det supplies a finite recovery gradient for
        # invalid line-search probes. No folded stage may be accepted or exported.
        epsilon=1e-5;safe=np.maximum(determinant,epsilon);delta=np.minimum(determinant-epsilon,0)
        reciprocal=1/safe-delta/epsilon**2+delta**2/epsilon**3
        derivative=-1/safe**2+2*delta/epsilon**3
        cofactor=np.empty_like(jacobian)
        cofactor[:,0,0]=jacobian[:,1,1];cofactor[:,0,1]=-jacobian[:,1,0]
        cofactor[:,1,0]=-jacobian[:,0,1];cofactor[:,1,1]=jacobian[:,0,0]
        squared=np.sum(jacobian**2,axis=(1,2));error=self.portions@determinant-self.targets
        area_cost=np.sum(error**2/self.targets)
        shape_cost=squared*reciprocal-2
        scale_cost=determinant/self.scale+self.scale*reciprocal-2
        cost=(area_cost+distortion*np.sum(self.weight*(.5*shape_cost+.2*scale_cost)))/self.normalizer
        gradient=(self.portions.T@(2*error/self.targets))[:,None,None]*cofactor
        shape_gradient=2*jacobian*reciprocal[:,None,None]+(squared*derivative)[:,None,None]*cofactor
        scale_gradient=(1/self.scale+self.scale*derivative)[:,None,None]*cofactor
        gradient+=distortion*self.weight[:,None,None]*(.5*shape_gradient+.2*scale_gradient)
        edges_gradient=gradient@self.inverse.transpose(0,2,1)/self.normalizer
        result=np.zeros_like(vertices)
        np.add.at(result,self.triangles[:,0],-edges_gradient.sum(axis=2))
        np.add.at(result,self.triangles[:,1],edges_gradient[:,:,0])
        np.add.at(result,self.triangles[:,2],edges_gradient[:,:,1])
        return float(cost),result[self.free].ravel()

    def step_bound(self,values,direction):
        current=edge_matrices(self.unpack(values),self.triangles)@self.inverse
        delta=np.zeros_like(self.vertices);delta[self.free]=direction.reshape((-1,2))
        change=edge_matrices(delta,self.triangles)@self.inverse
        a=np.linalg.det(change)
        b=current[:,0,0]*change[:,1,1]+change[:,0,0]*current[:,1,1]-current[:,0,1]*change[:,1,0]-change[:,0,1]*current[:,1,0]
        determinant=np.linalg.det(current);c=determinant-np.maximum(1e-10,.05*determinant)
        if np.any(c<=0):return 0.
        roots=[];linear=np.abs(a)<1e-20
        valid=linear&(b<0);roots.extend((-c[valid]/b[valid]).tolist())
        discriminant=b*b-4*a*c;valid=(~linear)&(discriminant>=0)
        q=-.5*(b[valid]+np.copysign(np.sqrt(discriminant[valid]),b[valid]))
        for candidates in [q/a[valid],np.divide(c[valid],q,out=np.full_like(q,np.inf),where=q!=0)]:
            roots.extend(candidates[candidates>0].tolist())
        return min(1.,.99*min(roots)) if roots else 1.

    def report(self,values):
        determinant=np.linalg.det(edge_matrices(self.unpack(values),self.triangles)@self.inverse)
        relative=(self.portions@determinant)/self.targets-1
        return dict(minimum_determinant=float(determinant.min()),folded_triangles=int(np.sum(determinant<=0)),maximum_relative_area_error=float(np.abs(relative).max()),weighted_absolute_area_error=float(np.sum(self.targets*np.abs(relative))/self.normalizer))


def bounded_lbfgs(objective,values,distortion,iterations):
    """Limited-memory BFGS with a determinant-bounded Armijo line search."""
    values=values.copy();cost,gradient=objective.evaluate(values,distortion);history=[]
    for turn in range(iterations):
        if np.linalg.norm(gradient,np.inf)<1e-7:
            return OptimizeResult(x=values,fun=cost,nit=turn,success=True,message='Gradient tolerance reached')
        direction=gradient.copy();alphas=[]
        for s,y,rho in reversed(history):
            alpha=rho*np.dot(s,direction);alphas.append(alpha);direction-=alpha*y
        if history:
            s,y,_=history[-1];direction*=np.dot(s,y)/np.dot(y,y)
        for (s,y,rho),alpha in zip(history,reversed(alphas)):
            direction+=s*(alpha-rho*np.dot(y,direction))
        direction=-direction;slope=float(gradient@direction)
        if slope>=0:history=[];direction=-gradient;slope=-float(gradient@gradient)
        step=objective.step_bound(values,direction)
        for _ in range(50):
            candidate=values+step*direction
            if np.array_equal(candidate,values):return OptimizeResult(x=values,fun=cost,nit=turn,success=False,message='No representable step remains')
            next_cost,next_gradient=objective.evaluate(candidate,distortion)
            if step>0 and next_cost<=cost+1e-4*step*slope:break
            step*=.5
        else:return OptimizeResult(x=values,fun=cost,nit=turn,success=False,message='Bounded line search stopped')
        s=candidate-values;y=next_gradient-gradient;curvature=float(s@y)
        if curvature>1e-12*np.linalg.norm(s)*np.linalg.norm(y):
            history.append((s,y,1/curvature));history=history[-10:]
        values=candidate;cost=next_cost;gradient=next_gradient
    return OptimizeResult(x=values,fun=cost,nit=iterations,success=False,message='Iteration limit reached')


def build_mesh(geometries,resolution=64):
    bounds=np.array([g.bounds for g in geometries]);lower=bounds[:,:2].min(axis=0);upper=bounds[:,2:].max(axis=0)
    span=float((upper-lower).max());centre=(lower+upper)/2
    # Normalize coordinates for optimization; keep a fixed rectangular water margin.
    normalized=[affinity.affine_transform(g,[1/span,0,0,1/span,-centre[0]/span,-centre[1]/span]) for g in geometries]
    extent=(upper-lower)/span+.4;lo=-extent/2;hi=extent/2
    nx=resolution;ny=max(4,round(resolution*extent[1]/extent[0]))
    xx,yy=np.meshgrid(np.linspace(lo[0],hi[0],nx+1),np.linspace(lo[1],hi[1],ny+1))
    vertices=np.column_stack((xx.ravel(),yy.ravel()));refinements=[]
    # Midpoint refinement avoids inserting tiny country boxes into coarse cells,
    # which can make nearly degenerate triangles and stall the area solve.
    for level in range(17):
        triangles=Delaunay(vertices).simplices.copy()
        polygons=[Polygon(v) for v in vertices[triangles]];tree=STRtree(polygons);selected=set();counts=[]
        for g in normalized:
            hits=[t for t in tree.query(g,predicate='intersects') if g.intersection(polygons[t]).area>0]
            counts.append(len(hits))
            if len(hits)<4:selected.update(hits)
        refinements.append(dict(level=level,vertices=len(vertices),triangles=len(triangles),minimum_region_support=min(counts)))
        if not selected or level==16:break
        corners=vertices[triangles[sorted(selected)]]
        midpoints=np.concatenate([(corners[:,a]+corners[:,b])/2 for a,b in [(0,1),(1,2),(2,0)]])
        vertices=np.unique(np.concatenate([vertices,midpoints]),axis=0)
    if np.any(np.linalg.det(edge_matrices(vertices,triangles))<=0):raise ValueError('Invalid initial mesh orientation')
    fixed=np.any(np.isclose(vertices,lo,atol=1e-12,rtol=0)|np.isclose(vertices,hi,atol=1e-12,rtol=0),axis=1)
    rows=[];cols=[];areas=[];pieces=[]
    for r,g in enumerate(normalized):
        region=[]
        for t in sorted(tree.query(g,predicate='intersects').tolist()):
            piece=g.intersection(polygons[t]);area=piece.area
            if area<=0:continue
            rows.append(r);cols.append(t);areas.append(area);region.append((t,piece))
        pieces.append(region)
    portions=coo_matrix((areas,(rows,cols)),shape=(len(geometries),len(triangles))).tocsr()
    expected=np.array([g.area for g in normalized]);actual=np.asarray(portions.sum(axis=1)).ravel()
    if not np.allclose(actual,expected,rtol=1e-8,atol=1e-14):raise ValueError('Mesh intersections lose source area')
    return vertices,triangles,portions,fixed,pieces,dict(span=span,centre=centre.tolist(),resolution=resolution,grid_shape=[nx,ny],refinements=refinements,region_triangle_counts=[len(p) for p in pieces])


def transform_pieces(objective,values,pieces,cleanup=None):
    vertices=objective.unpack(values);matrices=edge_matrices(vertices,objective.triangles)@objective.inverse
    starts=objective.vertices[objective.triangles[:,0]];ends=vertices[objective.triangles[:,0]]
    offsets=ends-np.einsum('tij,tj->ti',matrices,starts);result=[]
    for region in pieces:
        transformed=[]
        for t,piece in region:
            a=matrices[t];b=offsets[t]
            transformed.append(affinity.affine_transform(piece,[a[0,0],a[0,1],a[1,0],a[1,1],b[0],b[1]]))
        expected_area=sum(g.area for g in transformed)
        geometry=union_all(transformed,grid_size=1e-12)
        # Close numerical seams, not geographic gaps. Compare with the sum of
        # mapped pieces: an overlay failure must not silently lose a triangle.
        geometry=geometry.buffer(1e-11,join_style='mitre').buffer(-1e-11,join_style='mitre')
        error=abs(geometry.area-expected_area)
        if cleanup is not None:cleanup.append(dict(expected_area=expected_area,area_error=error))
        if error>max(1e-12,expected_area*1e-8):raise ValueError('Numerical seam cleanup changes too much area')
        if geometry.geom_type!='Polygon' or not geometry.is_valid or geometry.is_empty:raise ValueError('Mapped component is invalid or split')
        result.append(geometry)
    return result


def save_geometry(objective,values,pieces,source,labels,path):
    cleanup=[];mapped=transform_pieces(objective,values,pieces,cleanup);tree=STRtree(mapped);area=sum(g.area for g in mapped)
    overlaps=[(i,int(j)) for i,g in enumerate(mapped) for j in tree.query(g,predicate='intersects') if j>i and g.intersection(mapped[j]).area>area*1e-12]
    changed=sum(len(source[c].interiors)!=len(g.interiors) for c,g in zip(labels,mapped))
    if overlaps or changed:raise ValueError('Mapped regions overlap or change hole topology')
    features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in zip(labels,mapped)]
    path.write_text(json.dumps(dict(type='FeatureCollection',features=features),separators=(',',':'))+'\n')
    return dict(geometry_cleanup=cleanup,overlap_pairs=overlaps,changed_hole_counts=changed,geometry_sha256=digest(path))


def run(prepared,output,resolution=64,iterations=1000,distortions=(.3,.1,.03,.01),optimizer='bounded-lbfgs',stage_geometry=False):
    if output.exists():raise ValueError('Output already exists')
    if optimizer not in ('bounded-lbfgs','scipy'):raise ValueError('Unknown optimizer')
    if resolution<8 or iterations<1 or not distortions or any(not np.isfinite(w) or w<=0 for w in distortions):raise ValueError('Invalid solver settings')
    source=read_shapes(prepared/'geometry.geojson');rows=read_csv(prepared/'areas.csv');budgets={r['component_id']:float(r['tiles']) for r in rows};labels=sorted(source)
    if len(rows)!=len(budgets) or set(budgets)!=set(source) or any(not np.isfinite(v) or v<=0 for v in budgets.values()):raise ValueError('Invalid guide budgets')
    output.mkdir(parents=True);started=time.monotonic()
    record=dict(method='Planar fixed-frame mesh with area error and Sargent shape/scale distortion costs',reference='https://arxiv.org/abs/2411.17129',inputs={str(p):digest(p) for p in [prepared/'geometry.geojson',prepared/'areas.csv']},script_sha256=digest(Path(__file__)),optimizer=optimizer,stage_geometry=stage_geometry,maximum_iterations_per_stage=iterations,reciprocal_extension_threshold=1e-5,minimum_accepted_determinant=1e-12,union_precision=1e-12,seam_cleanup_radius=1e-11,stages=[],limit='Independent planar experiment, not the paper sphere or hybrid implementation. Reference triangles use Equal Earth planar geometry, not spherical geometry. Fixed frame and nearest-land water scale differ from the paper. Small regions share mesh degrees of freedom. Guide areas can remain inaccurate. No final tile budgets change. Positive triangle areas are checked; output component validity and overlaps must also be checked. No connector paths are added.')
    def save():(output/'mesh-guide.json').write_text(json.dumps(record,indent=2)+'\n')
    save()
    try:
        vertices,triangles,portions,fixed,pieces,info=build_mesh([source[c] for c in labels],resolution)
        targets=np.array([budgets[c] for c in labels]);targets*=float(portions.sum())/targets.sum()
        objective=MeshObjective(vertices,triangles,portions,targets,fixed);values=vertices[~fixed].ravel();record['mesh']=info;record['vertices']=len(vertices);record['triangles']=len(triangles);record['initial']=objective.report(values);save()
        for weight in distortions:
            before=time.monotonic()
            result=bounded_lbfgs(objective,values,weight,iterations) if optimizer=='bounded-lbfgs' else minimize(objective.evaluate,values,args=(weight,),jac=True,method='L-BFGS-B',options=dict(maxiter=iterations,maxls=50,ftol=1e-12,gtol=1e-7))
            if not np.isfinite(result.fun):raise ValueError('Non-finite mesh objective')
            values=result.x;stage=dict(distortion_weight=weight,iterations=int(result.nit),converged=bool(result.success),message=str(result.message),cost=float(result.fun),elapsed_seconds=time.monotonic()-before,**objective.report(values))
            record['stages'].append(stage);save();print(json.dumps(stage),flush=True)
            if stage['minimum_determinant']<=1e-12:raise ValueError('Folded or collapsed mesh stage')
            if stage_geometry:
                filename=f'stage-{len(record["stages"])}.geojson'
                stage['geometry']=dict(file=filename,**save_geometry(objective,values,pieces,source,labels,output/filename));save()
        record.update(save_geometry(objective,values,pieces,source,labels,output/'geometry.geojson'))
        np.savez_compressed(output/'mesh.npz',initial=vertices,transformed=objective.unpack(values),triangles=triangles,fixed=fixed)
        record['elapsed_seconds']=time.monotonic()-started;save()
    except Exception as error:
        record['error']=str(error);record['elapsed_seconds']=time.monotonic()-started;save();raise
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['prepared','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--resolution',type=int,default=64);parser.add_argument('--iterations',type=int,default=1000)
    parser.add_argument('--optimizer',choices=['bounded-lbfgs','scipy'],default='bounded-lbfgs')
    parser.add_argument('--stage-geometry',action='store_true',help='Save checked geometry after each distortion-weight stage')
    parser.add_argument('--distortions',type=float,nargs='+',default=[.3,.1,.03,.01])
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
