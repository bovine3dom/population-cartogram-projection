"""Use convex pieces to retain coastal bays in the displacement model."""
import heapq
import json

import numpy as np
from shapely import constrained_delaunay_triangles, transform, union_all
from shapely.geometry import box, shape, Polygon

from prepare_flow import equal_earth
from shape_stress import Stress


def convex_pieces(cells,tolerance=.75):
    centre=np.mean(list(cells),axis=0)
    polygon=union_all([box(x-.5,y-.5,x+.5,y+.5) for x,y in cells]).simplify(tolerance,preserve_topology=True)
    triangles=list(constrained_delaunay_triangles(polygon).geoms)
    neighbours={i:set() for i in range(len(triangles))};edges={}
    for i,triangle in enumerate(triangles):
        points=list(triangle.exterior.coords)
        for a,b in zip(points,points[1:]):
            edge=tuple(sorted((a,b)))
            if edge in edges:
                j=edges[edge];neighbours[i].add(j);neighbours[j].add(i)
            else:edges[edge]=i
    pieces=dict(enumerate(triangles));queue=[(i,j) for i,n in neighbours.items() for j in n if i<j];heapq.heapify(queue)
    while queue:
        a,b=heapq.heappop(queue)
        if a not in pieces or b not in pieces or b not in neighbours[a]:continue
        merged=pieces[a].union(pieces[b]);hull=merged.convex_hull
        if hull.area-merged.area>1e-8:continue
        pieces[a]=hull;del pieces[b]
        linked=(neighbours[a]|neighbours[b])-{a,b};neighbours[a]=linked
        for c in linked:
            neighbours[c].discard(b);neighbours[c].add(a);heapq.heappush(queue,tuple(sorted((a,c))))
        del neighbours[b]
    result=[]
    for polygon in pieces.values():
        vertices=np.array(polygon.exterior.coords[:-1])-centre
        edges=np.roll(vertices,-1,axis=0)-vertices
        normals=np.column_stack((-edges[:,1],edges[:,0]));normals/=np.linalg.norm(normals,axis=1)[:,None]
        result.append((vertices,normals))
    return result


class ConcaveStress(Stress):
    def __init__(self,tiles,centres,required,collision=100.,spring=1.,anchor=.01,spatial=.03,gap=.8):
        super().__init__(tiles,centres,required,collision,spring,anchor,spatial,gap)
        self.pieces=[convex_pieces(tiles[c]) for c in self.labels];self.piece_cache={}
        self.piece_low=[np.array([v.min(axis=0) for v,n in parts]) for parts in self.pieces]
        self.piece_high=[np.array([v.max(axis=0) for v,n in parts]) for parts in self.pieces]

    def pair_energy_gradient(self,a,b,positions):
        lowa=self.piece_low[a]+positions[a];higha=self.piece_high[a]+positions[a]
        lowb=self.piece_low[b]+positions[b];highb=self.piece_high[b]+positions[b]
        possible=np.all((higha[:,None,:]+self.gap>lowb[None,:,:]) & (highb[None,:,:]+self.gap>lowa[:,None,:]),axis=2)
        value=0.;gradient=np.zeros(2)
        for i,j in zip(*np.nonzero(possible)):
            key=(a,b,int(i),int(j))
            if key not in self.piece_cache:
                ha,na=self.pieces[a][i];hb,nb=self.pieces[b][j];axes=np.concatenate((na,nb))
                pa=ha@axes.T;pb=hb@axes.T
                self.piece_cache[key]=(axes,pa.max(axis=0)-pb.min(axis=0),pb.max(axis=0)-pa.min(axis=0))
            axes,left,right=self.piece_cache[key];shift=axes@(positions[a]-positions[b])
            distances=np.concatenate((left+shift+self.gap,right-shift+self.gap));index=int(distances.argmin());depth=distances[index]
            if depth<=0:continue
            normal=axes[index] if index<len(axes) else -axes[index-len(axes)]
            value+=.5*self.collision*depth*depth;gradient+=self.collision*depth*normal
        return value,gradient

    def border_targets(self,polygons,tiles,required):
        source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
        projected={c:transform(Polygon(p.exterior),equal_earth) for c,p in source.items()}
        scales={c:np.sqrt(len(tiles[c])/p.area) for c,p in projected.items()}
        for index,(a,b) in enumerate(self.edges):
            ca,cb=self.labels[a],self.labels[b]
            if (ca,cb) not in required:continue
            line=source[ca].boundary.intersection(source[cb].boundary)
            if line.is_empty or line.length<=0:raise ValueError(f'No source border: {ca}, {cb}')
            point=line.interpolate(line.length/2)
            shared=equal_earth(np.array([[point.x,point.y]]))[0]
            offsets=[(shared-np.array(projected[c].centroid.coords[0]))*scales[c] for c in [ca,cb]]
            direction=self.initial[b]-self.initial[a];norm=np.linalg.norm(direction)
            self.targets[index]=offsets[0]-offsets[1]+(self.gap*direction/norm if norm else 0)
