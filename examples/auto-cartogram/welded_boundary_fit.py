#!/usr/bin/env python3
"""Fit independent shape guides with shared vertices along retained borders."""
import argparse
import json
import math
from pathlib import Path
import subprocess

import numpy as np
from scipy import sparse
from shapely import STRtree, constrained_delaunay_triangles, coverage_simplify, is_valid_reason, linestrings, points, union_all
from shapely.geometry import Point, Polygon, mapping
from shapely.geometry.polygon import orient

from assemble_independent import COUNTRIES, CUTS
from independent_kontur_flow import normalized
from review_flow import read_shapes, draw
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error


def key(p):
    return tuple(np.round(p, 8))


def sample_ring(ring, maximum_edge=2., shared_edges=frozenset()):
    xy = np.asarray(ring.coords)
    result = []
    for a,b in zip(xy[:-1],xy[1:]):
        minimum = 2 if tuple(sorted((key(a),key(b)))) in shared_edges else 1
        count = max(minimum, math.ceil(np.linalg.norm(b-a)/maximum_edge))
        result.extend(a+(b-a)*i/count for i in range(count))
    return np.array([key(p) for p in result])


def target_ring(source, target, centre):
    """Ordered arclength matching, with a fixed cyclic phase; no rotation."""
    source_lengths = np.linalg.norm(np.roll(source,-1,axis=0)-source,axis=1)
    fractions = np.r_[0.,np.cumsum(source_lengths)[:-1]]/source_lengths.sum()
    xy = np.asarray(target.coords)
    lengths = np.linalg.norm(np.diff(xy,axis=0),axis=1)
    lengths = np.r_[0.,np.cumsum(lengths)]
    lengths /= lengths[-1]
    candidates = [np.column_stack([np.interp((fractions+phase)%1, lengths, xy[:,axis]) for axis in range(2)])
                  for phase in np.arange(128)/128]
    return min(candidates, key=lambda p: float(np.mean(np.sum((source-centre-p)**2,axis=1))))


def sample_guides(source, preferred, edge_length, shared_edges, mappers=None):
    """Refine crossing target chords on both sides of each source edge."""
    from kontur_boundary_map import ContourSamplingError
    samples, references, parameters = {}, {}, {}
    for c,g in source.items():
        g,reference = orient(g),orient(preferred[c])
        rings,targets = [g.exterior,*g.interiors],[reference.exterior,*reference.interiors]
        if len(rings) != len(targets):
            raise ValueError('Reference hole count differs: '+c)
        for ri,(ring,target) in enumerate(zip(rings,targets)):
            samples[c,ri] = sample_ring(ring,edge_length,shared_edges)
            references[c,ri] = target
            mapper = mappers[c][ri] if mappers else None
            if mapper and len(mapper.source['labels']) > 1:
                parameters[c,ri] = mapper.locations_on_ring(ring,samples[c,ri])
    history = []
    for iteration in range(17):
        wanted, split = {}, set()
        for (c,ri),xy in samples.items():
            mapper = mappers[c][ri] if mappers else None
            try:
                wanted[c,ri] = (mapper.sample(parameters[c,ri]) if (c,ri) in parameters else
                                target_ring(xy,references[c,ri],np.array(source[c].centroid.coords[0])))
            except ContourSamplingError as error:
                if not error.edges:
                    raise ValueError(f'{c}, ring {ri}: degenerate target contour') from error
                for i in error.edges:
                    split.add(tuple(sorted((key(xy[i]),key(xy[(i+1)%len(xy)])))))
            except ValueError as error:
                raise ValueError(f'{c}, ring {ri}: {error}') from error
        if not split:
            return samples,wanted,history
        if iteration == 16:
            raise ValueError('Target contour refinement did not converge')
        history.append(dict(round=iteration,split_edges=len(split)))
        for label,xy in samples.items():
            refined, refined_parameters = [], []
            ts = parameters.get(label)
            for i,(a,b) in enumerate(zip(xy,np.roll(xy,-1,axis=0))):
                refined.append(a)
                if ts is not None:
                    refined_parameters.append(ts[i])
                if tuple(sorted((key(a),key(b)))) in split:
                    midpoint = key((a+b)/2)
                    if midpoint in (key(a),key(b)):
                        raise ValueError('Contour refinement reached coordinate precision')
                    refined.append(midpoint)
                    if ts is not None:
                        refined_parameters.append((ts[i]+.5*((ts[(i+1)%len(ts)]-ts[i])%1))%1)
            samples[label] = np.asarray(refined)
            if ts is not None:
                parameters[label] = np.asarray(refined_parameters)
    raise AssertionError('Unreachable')


def signed_area(p):
    return .5*np.sum(p[:,0]*np.roll(p[:,1],-1)-p[:,1]*np.roll(p[:,0],-1))


def area_gradient(p):
    following, previous = np.roll(p,-1,axis=0), np.roll(p,1,axis=0)
    return .5*np.column_stack((following[:,1]-previous[:,1], previous[:,0]-following[:,0]))


class WeldedMesh:
    def __init__(self, source, preferred, budgets, cuts, edge_length=2., mappers=None):
        self.labels = sorted(source)
        self.budgets = np.array([budgets[c] for c in self.labels])
        edge_counts = {}
        for g in source.values():
            for ring in [g.exterior,*g.interiors]:
                for a,b in zip(list(ring.coords)[:-1],list(ring.coords)[1:]):
                    edge = tuple(sorted((key(a),key(b))))
                    edge_counts[edge] = edge_counts.get(edge,0)+1
        shared_edges = {e for e,n in edge_counts.items() if n == 2}
        samples, wanted_rings, self.refinement = sample_guides(source,preferred,edge_length,shared_edges,mappers)
        local, targets, country_rings, owners = [], [], {}, {}
        edge_owners = {}
        for c in self.labels:
            country_rings[c] = []
            for ri in range(1+len(source[c].interiors)):
                xy, wanted = samples[c,ri], wanted_rings[c,ri]
                ids = list(range(len(local),len(local)+len(xy)))
                local.extend(xy)
                targets.extend(wanted)
                country_rings[c].append(ids)
                for i,j in zip(ids, ids[1:]+ids[:1]):
                    edge = tuple(sorted((key(local[i]),key(local[j]))))
                    edge_owners.setdefault(edge,[]).append((c,i,j))
                    owners[c,key(local[i])] = i
        parent = list(range(len(local)))
        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i
        def weld(i,j):
            parent[find(i)] = find(j)
        self.shared = []
        for edge, entries in edge_owners.items():
            if len(entries) > 2:
                raise ValueError('Non-manifold source edge')
            if len(entries) != 2:
                continue
            (a,ai,aj),(b,bi,bj) = entries
            pair = tuple(sorted((a,b)))
            if pair not in cuts:
                for coordinate in edge:
                    weld(owners[a,coordinate],owners[b,coordinate])
            self.shared.append((pair, entries, pair in cuts))
        matched_lengths = {}
        for pair,entries,_ in self.shared:
            _,i,j = entries[0]
            matched_lengths[pair] = matched_lengths.get(pair,0.)+float(np.linalg.norm(local[j]-local[i]))
        for ai,a in enumerate(self.labels):
            for b in self.labels[ai+1:]:
                length = source[a].boundary.intersection(source[b].boundary).length
                if abs(length-matched_lengths.get((a,b),0.)) > 1e-5*max(1.,length):
                    raise ValueError('Mesh misses part of a shared border: '+str((a,b)))
        roots = sorted({find(i) for i in range(len(local))})
        compact = {r:i for i,r in enumerate(roots)}
        self.node = np.array([compact[find(i)] for i in range(len(local))])
        self.rings = {c:[self.node[ids] for ids in country_rings[c]] for c in self.labels}
        self.n = len(roots)
        initial = np.zeros((self.n+len(self.labels),2))
        initial[self.node] = np.array(local)
        self.initial_centres = np.array([[source[c].centroid.x,source[c].centroid.y] for c in self.labels])
        initial[self.n:] = self.initial_centres
        self.initial = initial.ravel()
        self.size = len(self.initial)
        # Each country's shape can translate. Only its retained border vertices
        # are shared with another country; preferred contours are not welded.
        rr,cc,vv,rhs = [],[],[],[]
        for ci,c in enumerate(self.labels):
            ids = [i for ring in country_rings[c] for i in ring]
            weight = 1/math.sqrt(len(ids))
            for i in ids:
                for axis in range(2):
                    row = len(rhs)
                    rr.extend([row,row]); cc.extend([2*self.node[i]+axis,2*(self.n+ci)+axis]); vv.extend([weight,-weight])
                    rhs.append(weight*targets[i][axis])
            for axis in range(2):
                rr.append(len(rhs));cc.append(2*(self.n+ci)+axis);vv.append(math.sqrt(.02))
                rhs.append(math.sqrt(.02)*self.initial_centres[ci,axis])
        # Elastic regularization within each country prevents tiny coastal
        # edges from folding before the large-scale shape can move. No spring
        # crosses a cut: its two copies have distinct node IDs.
        for rings in self.rings.values():
            for ring in rings:
                for a,b in zip(ring,np.roll(ring,-1)):
                    delta = initial[a]-initial[b]
                    weight = math.sqrt(.01)/max(np.linalg.norm(delta),.01)
                    for axis in range(2):
                        row = len(rhs)
                        rr.extend([row,row]);cc.extend([2*a+axis,2*b+axis]);vv.extend([weight,-weight])
                        rhs.append(weight*delta[axis])
        design = sparse.coo_matrix((vv,(rr,cc)),shape=(len(rhs),self.size)).tocsc()
        self.hessian = (design.T@design).tocsc()
        self.linear = np.asarray(design.T@np.array(rhs)).ravel()
        self.design, self.rhs = design, np.array(rhs)
        self.remesh(self.initial)
        self.initial_contacts = {pair for pair,_,_ in self.shared}
        self.cuts = set(cuts)
        if not self.cuts <= self.initial_contacts:
            raise ValueError('Cut not present in mesh')

    def remesh(self, flat):
        xy = flat.reshape(-1,2)
        triangles = []
        for c,g in self.polygons(flat).items():
            lookup = {tuple(xy[i]):i for ring in self.rings[c] for i in ring}
            for triangle in constrained_delaunay_triangles(g).geoms:
                ids = [lookup[tuple(p)] for p in list(triangle.exterior.coords)[:3]]
                if signed_area(xy[ids]) < 0:
                    ids.reverse()
                if signed_area(xy[ids]) > 1e-10:
                    triangles.append(ids)
        self.triangles = np.asarray(triangles)
        self.minimum_triangle_area = np.array([signed_area(xy[t]) for t in self.triangles])*1e-5

    def polygons(self, flat):
        xy = flat.reshape(-1,2)
        return {c:Polygon(xy[rings[0]], [xy[r] for r in rings[1:]]) for c,rings in self.rings.items()}

    def areas(self, flat):
        xy = flat.reshape(-1,2)
        return np.array([sum(signed_area(xy[r]) for r in self.rings[c]) for c in self.labels])

    def energy(self, flat):
        residual = self.design@flat-self.rhs
        return .5*float(residual@residual)

    def equalities(self, flat):
        xy = flat.reshape(-1,2)
        rr,cc,vv = [],[],[]
        for ci,c in enumerate(self.labels):
            for ring in self.rings[c]:
                gradient = area_gradient(xy[ring])/self.budgets[ci]
                for node,values in zip(ring,gradient):
                    for axis in range(2):
                        rr.append(ci);cc.append(2*node+axis);vv.append(values[axis])
        jac = sparse.coo_matrix((vv,(rr,cc)),shape=(len(self.labels),self.size)).tocsc()
        return jac, (self.budgets-self.areas(flat))/self.budgets

    def inequalities(self, flat):
        xy = flat.reshape(-1,2)
        rr,cc,vv,lower = [],[],[],[]
        def row(coefficients, bound):
            index = len(lower)
            for node,vector in coefficients:
                for axis in range(2):
                    rr.append(index);cc.append(2*node+axis);vv.append(vector[axis])
            lower.append(bound)
        for triangle in self.triangles:
            p = xy[triangle]
            inverse = np.linalg.inv(np.column_stack((p[1]-p[0],p[2]-p[0])))
            # Bound every entry of F-I to 0.2. Its spectral norm is then below
            # one, so triangles cannot flip anywhere along the proposed step.
            # This is a step-size constraint, not a permanent shape constraint.
            for axis in range(2):
                for column in range(2):
                    coefficients = []
                    for node,value in zip(triangle,[-inverse[:,column].sum(),*inverse[:,column]]):
                        vector = np.zeros(2);vector[axis] = value
                        coefficients.append((node,vector))
                    row(coefficients,-.2)
                    row([(node,-vector) for node,vector in coefficients],-.2)
        # Generic near-contact repulsion. It uses current edge locations, not
        # original border pairings. No attraction or target gap is added.
        polygons = self.polygons(flat)
        for c in self.labels:
            edges = np.array([(a,b) for ring in self.rings[c] for a,b in zip(ring,np.roll(ring,-1))])
            tree = STRtree(linestrings(xy[edges]))
            for d in self.labels:
                if d != c and polygons[c].distance(polygons[d]) > .02:
                    continue
                other_edges = [(a,b) for ring in self.rings[d] for a,b in zip(ring,np.roll(ring,-1))]
                samples = [(a,b,.5) for a,b in other_edges]+[(a,a,0.) for a,b in other_edges]
                locations = np.array([(1-t)*xy[a]+t*xy[b] for a,b,t in samples])
                if d == c:
                    candidates = tree.query(points(locations),predicate='dwithin',distance=.5).T
                else:
                    indices,distances = tree.query_nearest(points(locations),return_distance=True,all_matches=True)
                    candidates = indices[:,distances < .02].T
                for oi,ei in candidates:
                    a,b = edges[ei];u,v,t = samples[oi]
                    if {a,b} == {u,v} or (u == v and u in (a,b)) or (d == c and {a,b}&{u,v}):
                        continue
                    direction = xy[b]-xy[a]
                    length = np.linalg.norm(direction)
                    if length < 1e-10:
                        continue
                    normal = np.array([direction[1],-direction[0]])/length
                    point = locations[oi]
                    fraction = np.clip(np.dot(point-xy[a],direction)/length**2,0,1)
                    nearest = xy[a]+fraction*direction
                    if d == c and polygons[c].contains(Point((point+nearest)/2)):
                        # Inside-country separation is handled by the triangle
                        # constraints; only repel across exterior water here.
                        continue
                    separation = point-nearest
                    distance = np.linalg.norm(separation)
                    if distance > 1e-8:
                        # A nearby finite edge is not a global half-plane.
                        # Use the actual separating vector so every valid
                        # current configuration admits the zero displacement.
                        normal = separation/distance
                        if d != c and polygons[c].contains(Point(point)):
                            # A small accepted overlap is penetration, not a
                            # positive clearance pointing into the neighbour.
                            normal = -normal
                    gap = np.dot(separation,normal)
                    row([(u,(1-t)*normal),(v,t*normal),(a,-(1-fraction)*normal),(b,-fraction*normal)],-gap)
        jac = sparse.coo_matrix((vv,(rr,cc)),shape=(len(lower),self.size)).tocsc()
        return jac,np.array(lower)

    def checks(self, flat):
        polygons = self.polygons(flat)
        valid = all(g.is_valid and not g.is_empty for g in polygons.values())
        if not valid:
            return dict(valid=False, polygon_valid=False, invalid={c:is_valid_reason(g) for c,g in polygons.items() if not g.is_valid}, overlap=None,
                        maximum_area_error=float(np.max(np.abs(self.areas(flat)/self.budgets-1))))
        overlap = sum(g.area for g in polygons.values())-union_all(list(polygons.values())).area
        xy = flat.reshape(-1,2)
        triangle_ok = all(signed_area(xy[t]) >= minimum*.9 for t,minimum in zip(self.triangles,self.minimum_triangle_area))
        return dict(valid=bool(triangle_ok), polygon_valid=True, triangles_valid=bool(triangle_ok), overlap=max(0.,float(overlap)),
                    maximum_area_error=float(np.max(np.abs(self.areas(flat)/self.budgets-1))))


def save_collision_trace(mesh, current, step, directory, entry, inequality, lower):
    """Save a rejected proposal, not a candidate layout."""
    directory.mkdir(parents=True)
    before,after = mesh.polygons(current),mesh.polygons(current+step)
    features,overlaps = [],[]
    for stage,shapes in [('current',before),('proposed',after)]:
        features.extend(dict(type='Feature',properties=dict(stage=stage,component_id=c),geometry=mapping(g))
                        for c,g in shapes.items())
    for i,a in enumerate(mesh.labels):
        for b in mesh.labels[i+1:]:
            intersection = after[a].intersection(after[b])
            if intersection.area > 1e-8:
                overlaps.append(dict(a=a,b=b,area=intersection.area,cut=tuple(sorted((a,b))) in mesh.cuts))
                features.append(dict(type='Feature',properties=dict(stage='overlap',a=a,b=b),geometry=mapping(intersection)))
    residual = inequality@step-lower
    report = dict(step=entry,overlaps=sorted(overlaps,key=lambda p:-p['area']),
                  maximum_linear_violation=max(0.,float(-residual.min())),
                  current_checks=mesh.checks(current),proposed_checks=mesh.checks(current+step),
                  rings={c:[r.tolist() for r in rings] for c,rings in mesh.rings.items()},
                  cuts=sorted(mesh.cuts),budgets=dict(zip(mesh.labels,mesh.budgets.tolist())),
                  limits=['Rejected solver proposal; not a layout.',
                          'Constraint residuals are in the original row units, not all in distance units.'])
    np.savez_compressed(directory/'step.npz',initial=mesh.initial,current=current,step=step)
    (directory/'geometry.geojson').write_text(json.dumps(dict(type='FeatureCollection',features=features))+'\n')
    (directory/'trace.json').write_text(json.dumps(report,indent=2)+'\n')


def fit(mesh, iterations=60, trust=2., trace_directory=None):
    import osqp
    current = mesh.initial.copy()
    history = []
    identity = sparse.eye(mesh.size,format='csc')
    for iteration in range(iterations):
        eq,rhs = mesh.equalities(current)
        inequality,lower = mesh.inequalities(current)
        if lower.max(initial=-np.inf) > 1e-7:
            checks = mesh.checks(current)
            # An accepted tolerance-sized overlap needs a corrective step;
            # zero displacement must not be required to remain feasible.
            if not checks['valid'] or not 0 < checks['overlap'] < 1e-6:
                raise ValueError('Collision linearization excludes the valid current mesh')
        # Penalized area slacks keep each subproblem feasible while the curved
        # area constraints are linearized. Report actual final area errors.
        count = len(rhs)
        constraints = sparse.bmat([[eq,-sparse.eye(count)],
                                   [inequality,sparse.csc_matrix((len(lower),count))],
                                   [identity,sparse.csc_matrix((mesh.size,count))]],format='csc')
        solver = osqp.OSQP()
        solver.setup(P=sparse.block_diag([mesh.hessian+.01*identity,1e5*sparse.eye(count)],format='csc'),
                     q=np.r_[mesh.hessian@current-mesh.linear,np.zeros(count)],
                     A=constraints, l=np.r_[rhs,lower,np.full(mesh.size,-trust)],
                     u=np.r_[rhs,np.full(len(lower),np.inf),np.full(mesh.size,trust)],
                     verbose=False,eps_abs=1e-6,eps_rel=1e-6,max_iter=30000,polishing=True)
        solver.warm_start(x=np.r_[np.zeros(mesh.size),-rhs])
        solution = solver.solve(raise_error=False)
        entry = dict(iteration=iteration,trust=trust,status=solution.info.status,qp_iterations=int(solution.info.iter),
                     primal_residual=float(solution.info.prim_res),dual_residual=float(solution.info.dual_res))
        if solution.info.status_val not in (1,2):
            history.append(entry)
            print(json.dumps(entry),flush=True)
            if solution.info.status_val == 7 and trust > .02:
                trust = max(.02,trust/2)
                continue
            break
        step = solution.x[:mesh.size]
        before = mesh.energy(current)+1e5*np.sum((mesh.areas(current)/mesh.budgets-1)**2)
        accepted = False
        for alpha in 2.**-np.arange(18):
            proposed = current+alpha*step
            checks = mesh.checks(proposed)
            merit = mesh.energy(proposed)+1e5*np.sum((mesh.areas(proposed)/mesh.budgets-1)**2)
            if alpha == 1:
                entry['full_step_checks'] = checks
                entry['full_step_merit'] = merit
                entry['initial_merit'] = before
                if (trace_directory is not None and not trace_directory.exists()
                        and checks['polygon_valid'] and checks['overlap'] > 1e-6):
                    save_collision_trace(mesh,current,step,trace_directory,entry,inequality,lower)
            if checks['valid'] and checks['overlap'] < 1e-6 and merit <= before+1e-8:
                current = proposed
                mesh.remesh(current)
                entry.update(alpha=float(alpha),energy=mesh.energy(current),**checks)
                accepted = True
                break
        history.append(entry)
        print(json.dumps(entry),flush=True)
        if not accepted:
            if trust > .02:
                trust = max(.02,trust/2)
                continue
            break
        if np.max(np.abs(alpha*step)) < 1e-6:
            break
        if alpha < .25:
            trust = max(.02,trust/2)
        elif alpha == 1:
            trust = min(2.,trust*1.25)
    return current,history


def run(root, output, iterations=60, source_simplify=.05, edge_length=2., cases=('all-borders','sparse-cuts'), patch_guides=False, trace_collisions=False, countries=COUNTRIES):
    import osqp
    if (output.exists() or iterations < 1 or not math.isfinite(source_simplify) or source_simplify < 0
            or not math.isfinite(edge_length) or edge_length <= 0):
        raise ValueError('Use a new output directory and positive iteration limit')
    if len(countries) < 2 or len(set(countries)) != len(countries) or not set(countries) <= set(COUNTRIES):
        raise ValueError('Select at least two distinct supported countries')
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    rows = {r['component_id']:r for r in read_csv(groups_path)}
    guide_path = root/'kontur-patch-flow-200-floor/blend-0.9/components.geojson'
    guide = read_shapes(guide_path)
    guide_report = guide_path.parent.parent/'experiment.json'
    saved = next(r for r in json.loads(guide_report.read_text())['runs'] if r['strength'] == .9)
    if not saved['solver_success'] or saved['geometry_sha256'] != digest(guide_path):
        raise ValueError('Saved guide differs')
    scale = math.sqrt(sum(int(rows[c]['tiles']) for c in guide)/sum(g.area for g in guide.values()))
    main = {code:max((c for c in guide if c[:3]==code),key=lambda c:int(rows[c]['tiles'])) for code in countries}
    from shapely import affinity
    source = {c:affinity.scale(guide[c],scale,scale,origin=(0,0)) for c in main.values()}
    origin = union_all(list(source.values())).centroid
    source = {c:affinity.translate(g,-origin.x,-origin.y) for c,g in source.items()}
    simplified = coverage_simplify(list(source.values()),source_simplify)
    simplification = {c:outline_error(g,source[c]) for c,g in zip(source,simplified)}
    source = dict(zip(source,simplified))
    preferred,paths = {},[groups_path,guide_path,guide_report]
    for code,c in main.items():
        folder = root/('independent-kontur-flow' if code in ['RUS','CHN','IND','KAZ'] else 'independent-eurasia-neighbours')
        path = folder/code/'blend-0.9/component.geojson'
        details = folder/'experiment.json'
        saved_country = next(r for r in json.loads(details.read_text())['countries'] if r['component'] == c)
        saved_run = next(r for r in saved_country['runs'] if r['strength'] == .9)
        if not saved_run['complete'] or saved_run['exit_code'] or saved_run['output_sha256'] != digest(path):
            raise ValueError('Independent guide differs')
        preferred[c] = normalized(read_shapes(path)[c],int(rows[c]['tiles']))
        paths.extend([path,details])
    cuts = {tuple(sorted((main[a],main[b]))) for a,b in CUTS if a in main and b in main}
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    audit = json.loads(audit_path.read_text())
    contacts_path = root/'world-55000-dissolved-input/geographic-contacts.csv'
    for path in [groups_path,contacts_path]:
        if audit['inputs'].get(str(path)) != digest(path):
            raise ValueError('Population audit inputs differ')
    paths.append(contacts_path)
    eligible = {tuple(sorted((r['a'],r['b']))) for r in audit['borders'] if r['eligible']}
    if not cuts <= eligible:
        raise ValueError('Unaudited cut')
    paths.append(audit_path)
    native_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    native = read_shapes(native_path)
    paths.append(native_path)
    budgets = {c:int(rows[c]['tiles']) for c in source}
    mappers,matching = None,[]
    if patch_guides:
        from kontur_boundary_map import build
        mappers,extra,matching = build(root,main,scale,(origin.x,origin.y),budgets)
        paths.extend(extra)
        paths.append(Path(__file__).with_name('kontur_boundary_map.py'))
    output.mkdir(parents=True)
    report = dict(countries=list(countries),cuts=sorted(cuts),trace_collisions=trace_collisions,patch_guides=patch_guides,boundary_matching=matching,iterations=iterations,source_simplify=source_simplify,edge_length=edge_length,simplification=simplification,cases=[],inputs={str(p):digest(p) for p in paths},
                  script_sha256=digest(Path(__file__)),osqp_version=osqp.__version__,
                  limits=['Shared vertices preserve entire retained border polylines, not only point contacts.',
                          'Selected cuts duplicate boundary degrees of freedom. General geometric collision checks still apply.',
                          'The reference shapes use ordered arclength matching, not exact population-point correspondence.',
                          'Areas use penalized slack variables and sequential linearization. Actual area errors are reported.',
                          'This is a regional continuous-boundary experiment, not a tile map. External neighbours, islands, and lakes are omitted.'])
    for name in cases:
        if name not in ('all-borders','sparse-cuts'):
            raise ValueError('Unknown case')
        policy = cuts if name == 'sparse-cuts' else set()
        mesh = WeldedMesh(source,preferred,budgets,policy,edge_length,mappers)
        initial_checks = mesh.checks(mesh.initial)
        print(name,'initial',json.dumps(initial_checks),flush=True)
        if not initial_checks['valid'] or initial_checks['overlap'] > 1e-6:
            raise ValueError('Invalid initial mesh')
        flat,history = fit(mesh,iterations,trace_directory=output/name/'collision-trace' if trace_collisions else None)
        geometries = mesh.polygons(flat)
        folder = output/name
        folder.mkdir(exist_ok=True)
        case = dict(name=name,nodes=mesh.n,triangles=len(mesh.triangles),contour_refinement=mesh.refinement,
                    initial_checks=initial_checks,history=history,**mesh.checks(flat))
        case['countries'] = [dict(component=c,country=c[:3],geographic_error=outline_error(geometries[c],native[c]),
                                  preferred_error=outline_error(geometries[c],preferred[c]),area_error=geometries[c].area/budgets[c]-1) for c in mesh.labels]
        case['contacts'] = [dict(a=a,b=b,cut=(a,b) in policy,gap=geometries[a].distance(geometries[b]),
                                shared_length=geometries[a].boundary.intersection(geometries[b].boundary).length)
                            for a,b in sorted(mesh.initial_contacts)]
        case['welded_edge_mismatches'] = sum(set(mesh.node[[ai,aj]]) != set(mesh.node[[bi,bj]])
                                           for _,entries,cut in mesh.shared if not cut
                                           for (_,ai,aj),(_,bi,bj) in [entries])
        path = folder/'components.geojson'
        path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in geometries.items()]),separators=(',',':'))+'\n')
        case['geometry_sha256'] = digest(path)
        draw(folder/'review.svg',geometries,rows,'Shared-boundary fit: '+name,
             f'Whole retained borders welded. Overlap {case["overlap"]:.6f}; maximum area error {case["maximum_area_error"]:.2%}.',
             method='Independent Kontur guides; shared-vertex boundary optimization.')
        subprocess.run(['rsvg-convert',str(folder/'review.svg'),'-o',str(folder/'review.png')],check=True)
        report['cases'].append(case)
        (output/'experiment.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--iterations',type=int,default=60)
    parser.add_argument('--source-simplify',type=float,default=.05)
    parser.add_argument('--edge-length',type=float,default=2.)
    parser.add_argument('--cases',nargs='+',choices=['all-borders','sparse-cuts'],default=['all-borders','sparse-cuts'])
    parser.add_argument('--patch-guides',action='store_true')
    parser.add_argument('--trace-collisions',action='store_true')
    parser.add_argument('--countries',nargs='+',choices=COUNTRIES,default=COUNTRIES)
    run(**vars(parser.parse_args()))
