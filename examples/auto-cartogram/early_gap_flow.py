#!/usr/bin/env python3
"""Open shared-mesh cuts before the population flow and advect the same patches."""
import argparse
import csv
import json
import math
from pathlib import Path
import subprocess

import numpy as np
from shapely import STRtree, affinity, coverage_simplify, make_valid, union_all
from shapely.geometry import Polygon, mapping, shape

from assemble_independent import CUTS
from independent_kontur_flow import normalized
from review_flow import draw, read_shapes
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error
from welded_boundary_fit import WeldedMesh, seed_cut_gap


def polygonal(g):
    if not g.area:
        return Polygon()
    if g.geom_type in ('Polygon','MultiPolygon'):
        return g
    return union_all([p for p in g.geoms if p.geom_type in ('Polygon','MultiPolygon')])


def simplify_patches(features, scale, tolerance):
    """Simplify the complete patch coverage, not countries independently."""
    originals = [affinity.scale(shape(f['geometry']),scale,scale,origin=(0,0)) for f in features]
    simplified = coverage_simplify(originals,tolerance)
    if any(g.geom_type not in ('Polygon','MultiPolygon') or not g.is_valid or g.is_empty for g in simplified):
        raise ValueError('Simplification removes or breaks a population patch')
    changes = [dict(patch_id=f['properties']['patch_id'],changed_area=a.symmetric_difference(b).area,source_area=a.area)
               for f,a,b in zip(features,originals,simplified)]
    result = [dict(type='Feature',properties=f['properties'],geometry=mapping(g)) for f,g in zip(features,simplified)]
    return result,changes


def advect_patches(features, mesh, before, after, scale, audit=None):
    """Clip patches to source triangles and apply the corresponding affine map."""
    if audit is None:
        audit = {}
    audit.update(piece_repairs=0,maximum_piece_area_error=0.)
    left,right = before.reshape(-1,2),after.reshape(-1,2)
    triangles = [Polygon(left[t]) for t in mesh.triangles]
    tree = STRtree(triangles)
    countries = mesh.polygons(before)
    labels = list(countries)
    owners = STRtree(list(countries.values()))
    triangle_owner = [labels[int(owners.query(t.representative_point(),predicate='within')[0])] for t in triangles]
    mapped = {(c,tuple(np.round(left[i],8))):tuple(right[i]) for c,rings in mesh.rings.items() for ring in rings for i in ring}
    transforms = []
    for ids in mesh.triangles:
        a,b = left[ids],right[ids]
        transforms.append(np.column_stack((b[1]-b[0],b[2]-b[0]))@np.linalg.inv(np.column_stack((a[1]-a[0],a[2]-a[0]))))
    def transport(piece, index, country):
        ids = mesh.triangles[index]
        def point(p):
            key = country,tuple(np.round(p,8))
            if key not in mapped:
                p = np.asarray(p)
                q = right[ids[0]]+transforms[index]@(p-left[ids[0]])
                for u,v in zip(ids,np.roll(ids,-1)):
                    u,v = sorted((u,v))
                    direction = left[v]-left[u]
                    t = np.clip(np.dot(p-left[u],direction)/np.dot(direction,direction),0.,1.)
                    if np.linalg.norm(p-(left[u]+t*direction)) < 1e-8:
                        q = right[u]+t*(right[v]-right[u])
                        break
                mapped[key] = tuple(q)
            return mapped[key]
        parts = list(piece.geoms) if piece.geom_type == 'MultiPolygon' else [piece]
        result = []
        for g in parts:
            warped = Polygon([point(p) for p in g.exterior.coords],[[point(p) for p in ring.coords] for ring in g.interiors])
            if not warped.is_valid:
                warped = polygonal(make_valid(warped))
                audit['piece_repairs'] += 1
            expected_area = g.area*np.linalg.det(transforms[index])
            error = abs(warped.area-expected_area)
            audit['maximum_piece_area_error'] = max(audit['maximum_piece_area_error'],error)
            tolerance = 2e-8*max(1.,g.length*np.linalg.norm(transforms[index],ord=2))
            if error > min(1e-5,tolerance):
                raise ValueError(f'Patch transport area error: {country}, triangle {index}, error {error}, expected {expected_area}, limit {min(1e-5,tolerance)}')
            result.append(warped)
        return union_all(result)
    result = []
    for f in features:
        source = affinity.scale(shape(f['geometry']),scale,scale,origin=(0,0))
        parts = []
        covered = 0.
        for i in tree.query(source,predicate='intersects'):
            if triangle_owner[i] != f['properties']['component_id']:
                continue
            piece = polygonal(source.intersection(triangles[i]))
            if piece.area:
                covered += piece.area
                parts.append(transport(piece,i,f['properties']['component_id']))
        if abs(covered-source.area) > max(1e-6,source.area*1e-7):
            raise ValueError('Patch not covered by source triangulation: '+f['properties']['patch_id'])
        warped = polygonal(union_all(parts))
        if warped.geom_type not in ('Polygon','MultiPolygon') or not warped.is_valid or warped.is_empty:
            raise ValueError('Invalid or disconnected warped patch: '+f['properties']['patch_id'])
        result.append(dict(type='Feature',properties=f['properties'],geometry=mapping(warped)))
    return result


def run(root, output, gap=8., grid=512, solve=True, source_simplify=.1, gap_steps=0):
    if output.exists() or not math.isfinite(gap) or gap < 0 or not math.isfinite(source_simplify) or source_simplify < 0 or grid < 16:
        raise ValueError('Use a new output directory and valid nonnegative geometry settings')
    source_path = root/'world-55000-mainland-flow/input/geometry.geojson'
    groups_path = root/'world-55000-dissolved-input/groups.csv'
    patch_path = root/'kontur-patch-flow-200-floor/patches.geojson'
    targets_path = root/'kontur-patch-flow-200-floor/blend-0.9/areas.csv'
    data_path = root/'kontur-patch-flow-200-floor/patch-data.json'
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    contacts_path = root/'world-55000-dissolved-input/geographic-contacts.csv'
    binary = (root/'vendor/cartogram-cpp/build/Release/cartogram').resolve()
    groups = {r['component_id']:r for r in read_csv(groups_path)}
    native = read_shapes(source_path)
    scale = math.sqrt(sum(int(groups[c]['tiles']) for c in native)/sum(g.area for g in native.values()))
    features,changes = simplify_patches(json.loads(patch_path.read_text())['features'],scale,source_simplify)
    source = {c:union_all([shape(f['geometry']) for f in features if f['properties']['component_id']==c]) for c in native}
    if any(g.geom_type != 'Polygon' or not g.is_valid for g in source.values()):
        raise ValueError('Simplified patches break a source component')
    budgets = {c:int(groups[c]['tiles']) for c in source}
    main = {code:max((c for c in source if c[:3]==code),key=lambda c:budgets[c]) for code in {v for p in CUTS for v in p}}
    cuts = {tuple(sorted((main[a],main[b]))) for a,b in CUTS}
    audit = json.loads(audit_path.read_text())
    for p in [groups_path,contacts_path]:
        if audit['inputs'].get(str(p)) != digest(p):
            raise ValueError('Population audit inputs differ')
    if not cuts <= {tuple(sorted((r['a'],r['b']))) for r in audit['borders'] if r['eligible']}:
        raise ValueError('Unaudited source cut')
    mesh = WeldedMesh(source,{c:normalized(g,budgets[c]) for c,g in source.items()},budgets,cuts,edge_length=8.)
    before = mesh.initial.copy()
    initial_checks = mesh.checks(before)
    if not initial_checks['valid'] or initial_checks['overlap'] > 1e-6:
        raise ValueError('Invalid original world mesh')
    old_triangles = mesh.triangles.copy()
    old_minimum = mesh.minimum_triangle_area.copy()
    seed = seed_cut_gap(mesh,gap,gap_steps)
    print('source opening',json.dumps(seed),flush=True)
    output.mkdir(parents=True)
    (output/'opening.json').write_text(json.dumps(seed,indent=2)+'\n')
    if gap and not seed['applied_target']:
        raise ValueError('Requested source opening failed; do not run an unchanged flow')
    after = mesh.initial.copy()
    # Use the triangulation from before the deformation for patch transport.
    mesh.triangles = old_triangles
    mesh.minimum_triangle_area = old_minimum
    transport_audit = {}
    warped = advect_patches(features,mesh,before,after,1.,transport_audit)
    geometry = output/'patches.geojson'
    geometry.write_text(json.dumps(dict(type='FeatureCollection',features=warped),separators=(',',':'))+'\n')
    targets = read_csv(targets_path)
    if {f['properties']['patch_id'] for f in warped} != {r['patch_id'] for r in targets}:
        raise ValueError('Patch target labels differ')
    with (output/'areas.csv').open('w',newline='') as stream:
        writer = csv.DictWriter(stream,fieldnames=['patch_id','tiles'],lineterminator='\n')
        writer.writeheader();writer.writerows(targets)
    def components(items):
        return {c:union_all([shape(f['geometry']) for f in items if f['properties']['component_id']==c])
                for c in source}
    prepared = components(warped)
    if any(g.geom_type != 'Polygon' or not g.is_valid for g in prepared.values()):
        raise ValueError('Patch transport breaks a component')
    expected = mesh.polygons(after)
    if any(prepared[c].symmetric_difference(expected[c]).area > 1e-5 for c in prepared):
        raise ValueError('Transported patches do not cover the opened mesh')
    source_contacts = [dict(a=a,b=b,cut=(a,b) in cuts,gap=prepared[a].distance(prepared[b]),
                            shared_length=prepared[a].boundary.intersection(prepared[b].boundary).length,
                            mesh_shared_length=expected[a].boundary.intersection(expected[b].boundary).length)
                       for a,b in sorted(mesh.initial_contacts)]
    if any(not p['cut'] and p['shared_length'] < .99999*p['mesh_shared_length'] for p in source_contacts):
        raise ValueError('Patch transport loses a retained source border')
    draw(output/'source.svg',prepared,groups,'Gap before population flow',
         f'Opening target: {gap:g} tile units. Exact saved patch populations and targets are retained.',
         method='Original Equal Earth source; shared-border mesh opening before flow.')
    subprocess.run(['rsvg-convert',str(output/'source.svg'),'-o',str(output/'source.png')],check=True)
    report = dict(gap_steps=gap_steps,transport_audit=transport_audit,source_contacts=source_contacts,population=sum(r['population'] for r in json.loads(data_path.read_text())),
                  target_total=sum(float(r['tiles']) for r in targets),source_simplify=source_simplify,patch_geometry_changes=changes,gap=gap,grid=grid,seed=seed,initial_checks=initial_checks,source_checks=mesh.checks(after),
                  cuts=sorted(cuts),patches=len(warped),components=len(source),scale=scale,complete=False,
                  inputs={str(p):digest(p) for p in [source_path,groups_path,patch_path,targets_path,data_path,audit_path,contacts_path,binary]},
                  script_sha256=digest(Path(__file__)),mesh_sha256=digest(Path(__file__).with_name('welded_boundary_fit.py')),
                  limits=['Experimental source opening, not real sea.',
                          'Same patch labels and target populations; patch geometry is transported before any population fit.',
                          'The complete patch coverage is simplified first; patch labels and populations are unchanged.',
                          'This remains a global continuous flow, but it starts with a wider source gap.',
                          'Mainland guide only; no island or lake placement and no tile fit.'])
    def save():
        (output/'experiment.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    if not solve:
        return report
    command = [str(binary),str(geometry.resolve()),str((output/'areas.csv').resolve()),'--skip_projection','--id','patch_id','--area','tiles',
               '--n_grid_rows_or_cols',str(grid),'--max_allowed_autoscale_grid_length','2048','--timeout','600','--export_preprocessed']
    report['command'] = command;save()
    with (output/'solver.log').open('w') as log:
        process = subprocess.run(command,cwd=output,stdout=log,stderr=subprocess.STDOUT,timeout=720)
    report['exit_code'] = process.returncode;save()
    if process.returncode:
        raise ValueError('Population solver failed')
    solved = json.loads((output/'areas_cartogram.geojson').read_text())['features']
    if {f['properties']['patch_id'] for f in solved} != {f['properties']['patch_id'] for f in warped}:
        raise ValueError('Solver patch labels differ')
    by_id = {f['properties']['patch_id']:f['properties']['component_id'] for f in warped}
    for f in solved:
        f['properties']['component_id'] = by_id[f['properties']['patch_id']]
    fitted = components(solved)
    if any(g.geom_type != 'Polygon' or not g.is_valid for g in fitted.values()):
        raise ValueError('Solver breaks a component')
    path = output/'components.geojson'
    path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in fitted.items()]),separators=(',',':'))+'\n')
    total_area = sum(g.area for g in fitted.values())
    target_total = sum(budgets.values())
    report.update(complete=True,geometry_sha256=digest(path),
                  countries=[dict(component=c,geographic_error=outline_error(g,native[c]),area_error=g.area/total_area*target_total/budgets[c]-1)
                             for c,g in fitted.items()],
                  contacts=[dict(a=a,b=b,cut=(a,b) in cuts,gap=fitted[a].distance(fitted[b]),shared_length=fitted[a].boundary.intersection(fitted[b].boundary).length)
                            for a,b in sorted(mesh.initial_contacts)])
    save()
    draw(output/'review.svg',fitted,groups,'Population flow after early gap',f'Opening target: {gap:g} tile units; grid {grid}.',
         method='Same 90% Kontur patch targets after source deformation.')
    subprocess.run(['rsvg-convert',str(output/'review.svg'),'-o',str(output/'review.png')],check=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--gap',type=float,default=8.)
    parser.add_argument('--grid',type=int,default=512)
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--source-simplify',type=float,default=.1)
    parser.add_argument('--gap-steps',type=int,default=0)
    args=parser.parse_args()
    run(args.root,args.output,args.gap,args.grid,not args.prepare_only,args.source_simplify,args.gap_steps)
