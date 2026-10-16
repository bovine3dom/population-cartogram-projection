"""Transport patch boundaries through a country mesh without joining triangle pieces."""
import numpy as np
from shapely import STRtree, make_valid, set_precision, union_all, is_valid_reason
from shapely.geometry import LineString, Point, Polygon, MultiPolygon, mapping, shape
from shapely import affinity


def coordinates(g):
    if g.is_empty:
        return []
    if hasattr(g,'geoms'):
        return [p for part in g.geoms for p in coordinates(part)]
    return list(g.coords)


def advect_patches(features, mesh, before, after, scale=1., audit=None):
    if audit is None:
        audit = {}
    audit.update(maximum_outside_distance=0.,source_vertices=0,output_vertices=0,precision_repairs=[])
    left,right = before.reshape(-1,2),after.reshape(-1,2)
    countries = mesh.polygons(before)
    labels = list(countries)
    country_tree = STRtree(list(countries.values()))
    triangles = [Polygon(left[t]) for t in mesh.triangles]
    owners = [labels[int(country_tree.query(t.representative_point(),predicate='within')[0])] for t in triangles]
    indices = {c:[i for i,owner in enumerate(owners) if owner==c] for c in labels}
    trees = {c:STRtree([triangles[i] for i in ids]) for c,ids in indices.items()}
    transforms = []
    for ids in mesh.triangles:
        a,b = left[ids],right[ids]
        transforms.append(np.column_stack((b[1]-b[0],b[2]-b[0]))@np.linalg.inv(np.column_stack((a[1]-a[0],a[2]-a[0]))))
    def key(p):
        return tuple(np.round(p,8))
    mapped = {(c,key(left[i])):tuple(right[i]) for c,rings in mesh.rings.items() for ring in rings for i in ring}
    edge_cache = {}
    def project(p,c):
        k = c,key(p)
        if k not in mapped:
            local = int(trees[c].nearest(Point(p)))
            i = indices[c][local]
            distance = triangles[i].distance(Point(p))
            audit['maximum_outside_distance'] = max(audit['maximum_outside_distance'],distance)
            if distance > 1e-7:
                raise ValueError('Patch boundary lies outside its source mesh')
            ids = mesh.triangles[i]
            q = right[ids[0]]+transforms[i]@(np.asarray(p)-left[ids[0]])
            for u,v in zip(ids,np.roll(ids,-1)):
                u,v = sorted((u,v))
                direction = left[v]-left[u]
                t = np.clip(np.dot(np.asarray(p)-left[u],direction)/np.dot(direction,direction),0.,1.)
                if np.linalg.norm(np.asarray(p)-(left[u]+t*direction)) < 1e-8:
                    q = right[u]+t*(right[v]-right[u])
                    break
            mapped[k] = tuple(q)
        return mapped[k]
    def edge(a,b,c):
        ka,kb = key(a),key(b)
        if ka == kb:
            return []
        reverse = ka > kb
        if reverse:
            a,b,ka,kb = b,a,kb,ka
        cache_key = c,ka,kb
        if cache_key not in edge_cache:
            a,b = np.asarray(a),np.asarray(b)
            line = LineString([a,b])
            direction = b-a
            fractions = {0.,1.}
            for local in trees[c].query(line,predicate='intersects'):
                i = indices[c][int(local)]
                for p in coordinates(line.intersection(triangles[i].boundary)):
                    fractions.add(float(np.clip(np.dot(np.asarray(p)-a,direction)/np.dot(direction,direction),0.,1.)))
            values = []
            for t in sorted(fractions):
                p = project(a+t*direction,c)
                if not values or p != values[-1]:
                    values.append(p)
            edge_cache[cache_key] = values
        values = edge_cache[cache_key]
        return (values[::-1] if reverse else values)[:-1]
    result = []
    for feature in features:
        c = feature['properties']['component_id']
        source = affinity.scale(shape(feature['geometry']),scale,scale,origin=(0,0))
        parts = list(source.geoms) if source.geom_type == 'MultiPolygon' else [source]
        def ring(r):
            points = list(r.coords)
            audit['source_vertices'] += len(points)-1
            out = [p for a,b in zip(points[:-1],points[1:]) for p in edge(a,b,c)]
            audit['output_vertices'] += len(out)
            return out
        polygons = [Polygon(ring(g.exterior),[ring(r) for r in g.interiors]) for g in parts]
        warped = MultiPolygon(polygons) if len(polygons)>1 else polygons[0]
        reason = is_valid_reason(warped)
        valid = make_valid(warped)
        if valid.geom_type == 'GeometryCollection':
            valid = union_all([g for g in valid.geoms if g.geom_type in ('Polygon','MultiPolygon')])
        cleaned = set_precision(valid,1e-8)
        distance = cleaned.hausdorff_distance(warped)
        area_change = abs(cleaned.area-warped.area)
        if (cleaned.is_empty or not cleaned.is_valid or cleaned.geom_type not in ('Polygon','MultiPolygon')
                or distance > 1e-7 or area_change > 1e-7*max(1.,warped.length)):
            raise ValueError('Boundary transport invalidates patch '+feature['properties']['patch_id']+': '+reason)
        audit['precision_repairs'].append(dict(patch_id=feature['properties']['patch_id'],reason=reason,
                                              boundary_distance=distance,area_change=area_change))
        result.append(dict(type='Feature',properties=feature['properties'],geometry=mapping(cleaned)))
    return result
