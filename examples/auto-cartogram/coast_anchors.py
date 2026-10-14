"""Set non-border spring targets from nearest points on source coastlines."""
import json

import numpy as np
from shapely import transform
from shapely.geometry import Polygon, shape
from shapely.ops import nearest_points

from prepare_flow import equal_earth


def apply(state,polygons,tiles,required,scale,ocean_length=0.):
    source={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    projected={c:transform(Polygon(p.exterior),equal_earth) for c,p in source.items()}
    centres={c:np.array(p.centroid.coords[0]) for c,p in projected.items()}
    factors={c:np.sqrt(len(tiles[c])/p.area) for c,p in projected.items()}
    count=0
    for index,(a,b) in enumerate(state.edges):
        ca,cb=state.labels[a],state.labels[b]
        if (ca,cb) in required:continue
        pa,pb=nearest_points(projected[ca].boundary,projected[cb].boundary)
        pa=np.array(pa.coords[0]);pb=np.array(pb.coords[0]);gap=(pb-pa)*scale
        length=np.linalg.norm(gap)
        if ocean_length and length:gap*=ocean_length*np.arcsinh(length/ocean_length)/length
        state.targets[index]=(pa-centres[ca])*factors[ca]-(pb-centres[cb])*factors[cb]+gap
        count+=1
    return count
