"""Match ordered coastline arcs using the patch labels shared by both fits."""
import json
import math

import numpy as np
from shapely import STRtree, points, union_all
from shapely.geometry import LinearRing, Point, shape
from shapely.geometry.polygon import orient


def labelled_arcs(features):
    labels = [f['properties']['patch_id'] for f in features]
    polygons = [shape(f['geometry']) for f in features]
    country = orient(union_all(polygons))
    tree = STRtree(polygons)
    result = []
    for ring in [country.exterior,*country.interiors]:
        xy = np.asarray(ring.coords)
        lengths = np.linalg.norm(np.diff(xy,axis=0),axis=1)
        indices = tree.query_nearest(points((xy[:-1]+xy[1:])/2),all_matches=False)
        owner = dict(zip(indices[0],indices[1]))
        valid = np.flatnonzero(lengths >= lengths.sum()*1e-9)
        if not len(valid):
            raise ValueError('Empty boundary')
        tags = [None]*len(lengths)
        last = labels[owner[int(valid[-1])]]
        for i,length in enumerate(lengths):
            if length >= lengths.sum()*1e-9:
                last = labels[owner[i]]
            tags[i] = last
        starts = [i for i in range(len(tags)) if tags[i] != tags[i-1]] or [0]
        arclength = np.r_[0.,np.cumsum(lengths)]/lengths.sum()
        result.append(dict(ring=ring,labels=[tags[i] for i in starts],starts=arclength[starts]))
    return country,result


class BoundaryMap:
    def __init__(self, source, target, source_scale=1., source_origin=(0.,0.), target_scale=1., target_origin=(0.,0.)):
        left,right = source['labels'],target['labels']
        shifts = [i for i in range(len(right)) if left == right[i:]+right[:i]]
        if not shifts:
            raise ValueError('Ordered boundary patch labels differ')
        if len(shifts) > 1:
            raise ValueError('Ambiguous repeated boundary label cycle')
        self.source,self.target,self.shift = source,target,shifts[0]
        self.source_scale,self.source_origin = source_scale,np.asarray(source_origin)
        self.target_scale,self.target_origin = target_scale,np.asarray(target_origin)
        self.maximum_order_correction = 0.

    def map(self, xy):
        raw = (xy+self.source_origin)/self.source_scale
        source_ring = self.source['ring']
        projected = np.array([source_ring.project(Point(p),normalized=True) for p in raw])
        unwrapped = np.unwrap(projected*2*np.pi)/(2*np.pi)
        ordered = np.maximum.accumulate(unwrapped)
        correction = float(np.max(ordered-unwrapped))
        if correction > .005:
            raise ValueError('Source projection changes boundary order')
        self.maximum_order_correction = max(self.maximum_order_correction,correction)
        # Keep a strict order if simplification projects adjacent points to the
        # same source location. This adjustment is at most 0.1% of perimeter.
        lengths = np.linalg.norm(np.roll(raw,-1,axis=0)-raw,axis=1)
        uniform = unwrapped[0]+np.r_[0.,np.cumsum(lengths)[:-1]]/lengths.sum()
        ordered = .999*ordered+.001*uniform
        starts = self.source['starts']
        relative = (starts-starts[0])%1
        distance = (ordered-starts[0])%1
        indices = np.searchsorted(relative,distance,side='right')-1
        fractions = (distance-relative[indices])/np.diff(np.r_[relative,1.])[indices]
        target_starts = self.target['starts']
        selected = (indices+self.shift)%len(target_starts)
        target_lengths = (np.roll(target_starts,-1)-target_starts)%1
        if len(target_lengths) == 1:
            target_lengths[0] = 1.
        locations = (target_starts[selected]+fractions*target_lengths[selected])%1
        result = np.array([self.target['ring'].interpolate(t,normalized=True).coords[0] for t in locations])
        result = (result-self.target_origin)*self.target_scale
        if not LinearRing(result).is_simple:
            raise ValueError('Mapped reference ring self-intersects')
        return result


def build(root, main, source_scale, source_origin, budgets):
    path = root/'kontur-patch-flow-200-floor/blend-0.9/areas_cartogram.geojson'
    shared = json.loads(path.read_text())['features']
    result,paths,records = {},[path],[]
    for code,c in main.items():
        folder = root/('independent-kontur-flow' if code in ['RUS','CHN','IND','KAZ'] else 'independent-eurasia-neighbours')
        path = folder/code/'blend-0.9/areas_cartogram.geojson'
        features = json.loads(path.read_text())['features']
        labels = {f['properties']['patch_id'] for f in features}
        selected = [f for f in shared if f['properties']['patch_id'] in labels]
        if {f['properties']['patch_id'] for f in selected} != labels:
            raise ValueError('Patch input labels differ')
        _,left = labelled_arcs(selected)
        country,right = labelled_arcs(features)
        if len(left) != len(right):
            raise ValueError('Boundary ring counts differ')
        target_scale = math.sqrt(budgets[c]/country.area)
        target_origin = (country.centroid.x,country.centroid.y)
        result[c],fallbacks = [],[]
        for a,b in zip(left,right):
            try:
                mapper = BoundaryMap(a,b,source_scale,source_origin,target_scale,target_origin)
                reason = None
            except ValueError as error:
                mapper,reason = None,str(error)
            result[c].append(mapper)
            fallbacks.append(reason)
        records.append(dict(component=c,runs=[len(a['labels']) for a in left],
                            shifts=[m.shift if m else None for m in result[c]],fallbacks=fallbacks))
        paths.append(path)
    return result,paths,records
