"""Set non-border spring targets from nearest points on source coastlines."""
import json

import numpy as np
from shapely import transform
from shapely.geometry import Polygon, shape
from shapely.ops import nearest_points

from prepare_flow import equal_earth


def template_point(points,offset):
    candidates=points+np.clip(offset-points,-.5,.5)
    return candidates[np.argmin(np.sum((candidates-offset)**2,axis=1))]


def apply(state,polygons,tiles,required,scale,ocean_length=0.):
    source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    # The WKT initializer uses unit-radius Equal Earth; the flow helper uses 1000.
    projected={c:transform(Polygon(p.exterior),lambda points:equal_earth(points)/1000) for c,p in source.items()}
    centres={c:np.array(p.centroid.coords[0]) for c,p in projected.items()}
    factors={c:np.sqrt(len(tiles[c])/p.area) for c,p in projected.items()}
    local={c:np.array(sorted(points),dtype=float) for c,points in tiles.items()}
    local={c:points-points.mean(axis=0) for c,points in local.items()}
    count=0
    for index,(a,b) in enumerate(state.edges):
        ca,cb=state.labels[a],state.labels[b]
        if (ca,cb) in required:continue
        pa,pb=nearest_points(projected[ca].boundary,projected[cb].boundary)
        pa=np.array(pa.coords[0]);pb=np.array(pb.coords[0]);gap=(pb-pa)*scale
        length=np.linalg.norm(gap)
        if ocean_length and length:gap*=ocean_length*np.arcsinh(length/ocean_length)/length
        offsets=[template_point(local[c],(point-centres[c])*factors[c]) for c,point in [(ca,pa),(cb,pb)]]
        state.targets[index]=offsets[0]-offsets[1]+gap
        count+=1
    return count
