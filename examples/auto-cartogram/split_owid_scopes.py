#!/usr/bin/env python3
"""Divide combined OWID budgets using an explicit statistical-scope crosswalk."""
import argparse
import json
from pathlib import Path
import shutil

from shapely import affinity, union_all
from shapely.geometry import Point, shape

from audit_owid_budgets import apportion, write_csv
from compact_regions import adjacent
from dock_true_borders import contacts
from partition_landmass import partition
from fit_owid_landmass import load
from owid_landmass_world import inland_parts
from relax_owid_islands import owners, rows
from restore_reference_water import enclosed
from review_layout import connectivity
from save_review import digest


def connected_seed(points,guide,count):
    if not 0<count<len(points):raise ValueError('Both parts need at least one tile')
    def score(p):
        point=Point(p)
        return (guide.distance(point),point.distance(guide.centroid),p)
    # Try alternate starts if a narrow neck blocks a connected complement.
    for start in sorted(points,key=score):
        chosen={start}
        if connectivity(points-chosen)!=1:continue
        while len(chosen)<count:
            frontier={q for p in chosen for q in adjacent(p) if q in points-chosen}
            candidates=[q for q in frontier if connectivity(points-chosen-{q})==1]
            if not candidates:break
            chosen.add(min(candidates,key=score))
        if len(chosen)==count:return chosen
    raise ValueError('No connected seed and complement')


def transformed_guides(geometries,points):
    combined=union_all(list(geometries.values()));west,south,east,north=combined.bounds
    x0=min(x for x,y in points)-.5;y0=min(y for x,y in points)-.5
    width=max(x for x,y in points)-x0+.5;height=max(y for x,y in points)-y0+.5
    return {c:affinity.translate(affinity.scale(affinity.translate(g,-west,-south),
            width/(east-west),height/(north-south),origin=(0,0)),x0,y0) for c,g in geometries.items()}


def source_contacts(geometries):
    labels=sorted(geometries)
    return {tuple(sorted((a,b))) for i,a in enumerate(labels) for b in labels[i+1:]
            if geometries[a].intersection(geometries[b]).length>1e-6}


def run(parent,components,polygons,crosswalk,output,seconds=120,margin=12):
    if output.exists():raise ValueError('Use a new output directory')
    table=rows(crosswalk);source_rows=rows(components);by_id={r['component_id']:r for r in source_rows}
    if len({r['source_scope'] for r in table})!=len(table):raise ValueError('Each source scope must have one target')
    features=json.loads(polygons.read_text())['features']
    raw_geometry={f['properties']['component_id']:shape(f['geometry']) for f in features}
    scope_geometries={}
    for r in source_rows:scope_geometries.setdefault(r['country_id'],[]).append(raw_geometry[r['component_id']])
    scope_geometries={c:union_all(gs) for c,gs in scope_geometries.items()}
    if {r['source_scope'] for r in table}-scope_geometries.keys():raise ValueError('Unknown source scope')
    original=load(parent);working={c:set(ps) for c,ps in original.items()};before=owners(original)
    water=enclosed(before);record=dict(complete=False,approved=False,parent=str(parent),splits=[],
        inputs={str(p):digest(p) for p in (parent/'cells.csv',parent/'matches.csv',parent/'source-assignments.csv',components,polygons,crosswalk,Path(__file__),Path(__file__).with_name('partition_landmass.py'))})
    output.mkdir(parents=True)
    def save(): (output/'scope-splits.json').write_text(json.dumps(record,indent=2)+'\n')
    allocations={};mapping={r['source_scope']:r['target_scope'] for r in table};desired=contacts(before)
    for pool in dict.fromkeys(r['pool'] for r in table):
        rules=[r for r in table if r['pool']==pool];targets=list(dict.fromkeys(r['target_scope'] for r in rules))
        if len(targets)!=2 or pool not in targets:raise ValueError('Use a parent and one new display scope per pool')
        parent_label=pool+':T1';new=next(c for c in targets if c!=pool);new_label=new+':T1'
        if parent_label not in working or new_label in working or any(c.startswith(pool+':') and c!=parent_label for c in working):
            raise ValueError('Use a single-part parent and an absent new scope')
        included=[r for r in source_rows if r['country_id'] in {r['source_scope'] for r in rules}]
        mass={c:sum(float(r['population']) for r in included if mapping[r['country_id']]==c) for c in targets}
        quota,budget=apportion([mass[c] for c in targets],len(working[parent_label]))
        if min(budget)<1:raise ValueError('A scope needs a visibility policy at this resolution')
        allocations.update(zip(targets,budget))
        geos={c:union_all([raw_geometry[r['component_id']] for r in included if mapping[r['country_id']]==c]) for c in targets}
        guides=transformed_guides(geos,working[parent_label]);seed=connected_seed(working[parent_label],guides[new],allocations[new])
        seeded={c:set(ps) for c,ps in working.items()};seeded[parent_label]-=seed;seeded[new_label]=seed
        # Source adjacency determines the new label's neighbours, not the seed.
        current_neighbours={b if a==parent_label else a for a,b in desired if parent_label in (a,b)}
        relevant={c.split(':')[0] for c in current_neighbours}|set(targets)
        for c,g in scope_geometries.items():
            if c in targets:continue
            if any(g.intersection(geos[t]).length>1e-6 for t in targets):relevant.add(c)
        regional={c:geos.get(c,scope_geometries.get(c)) for c in relevant}
        regional={c:g for c,g in regional.items() if g is not None and c+':T1' in seeded}
        local_edges={(a+':T1',b+':T1') for a,b in source_contacts(regional)}
        movable={c+':T1' for c in regional}
        expected={pair for pair in desired if not set(pair)<=movable}|local_edges
        inland=inland_parts(working)
        # Retain the old coast status except for the explicitly inserted scope.
        # Kosovo is inland in the source graph; Somaliland and northern Cyprus
        # have source coast. Infer this from their unshared geographic boundary.
        other=union_all([g for c,g in regional.items() if c!=new])
        new_coast=geos[new].boundary.difference(other.buffer(1e-7)).length>1e-5
        if not new_coast:inland.add(new_label)
        preferred={c:set(ps) for c,ps in seeded.items()}
        preferred[new_label]={p for p in set().union(*(seeded[c] for c in movable)) if guides[new].covers(Point(p))} or seed
        local={c:seeded[c] for c in movable};footprint=set().union(*local.values())
        outside={p:c for p,c in owners(seeded).items() if c not in movable}
        fitted,attempts=partition(local,footprint,{c:len(ps) for c,ps in local.items()},radius=margin,seconds=seconds,
            exact_contacts=expected,outside=outside,inland=inland,preferred={c:preferred[c] for c in movable},perimeter_weight=.25)
        candidate={**seeded,**fitted} if fitted is not None else None
        entry=dict(pool=pool,targets=targets,populations=mass,budgets=dict(zip(targets,budget)),
            quotas=dict(zip(targets,quota)),movable=sorted(movable),accepted=candidate is not None,attempts=attempts,
            added_contacts=sorted(expected-desired),removed_contacts=sorted(desired-expected),new_scope_has_coast=new_coast)
        record['splits'].append(entry);save();print(json.dumps(entry),flush=True)
        if candidate is None:return record
        assert contacts(owners(candidate))==expected and set(owners(candidate))==set(before)
        assert enclosed(owners(candidate))==water
        working=candidate;desired=expected
    assignments=rows(parent/'source-assignments.csv');affected=set(mapping)
    kept=[r for r in assignments if by_id[r['component_id']]['country_id'] not in affected]
    added=[dict(country=mapping[r['country_id']],component_id=r['component_id'],target_part='T1',population=r['population'],
                assignment='explicit statistical-scope crosswalk',source_distance='')
           for r in source_rows if r['country_id'] in affected and float(r['population'])>0]
    assignments=kept+added
    if len({r['component_id'] for r in assignments})!=len(assignments):raise ValueError('Duplicate source population assignment')
    missing=[r for r in rows(parent/'source-scopes-without-tiles.csv') if r['country'] not in affected]
    old_missing=rows(parent/'source-scopes-without-tiles.csv')
    recovered=sum(float(r['population']) for r in old_missing if r['country'] in affected)
    prior_mass=sum(float(r['population']) for r in rows(parent/'source-assignments.csv'))
    assert sum(float(r['population']) for r in assignments)==prior_mass+recovered
    assert sum(float(r['population']) for r in missing)+sum(float(r['population']) for r in assignments)==prior_mass+sum(float(r['population']) for r in old_missing)
    matches=rows(parent/'matches.csv')
    for c,n in allocations.items():
        selected=[r for r in assignments if r['country']==c];population=sum(float(r['population']) for r in selected)
        row=next((r for r in matches if r['country']==c and r['target_part']=='T1'),None)
        if row is None:
            row={k:'' for k in matches[0]};matches.append(row)
        row.update(country=c,target_part='T1',group='T1',anchor_component=max(selected,key=lambda r:float(r['population']))['component_id'],
            identity='explicit_scope_crosswalk',old_tiles=len(original.get(c+':T1',set())),tiles=n,minimum_tiles=1,
            group_population=population,group_tiles=n,proportional_group_tiles=n,actual_tiles=n,resize_status='scope split')
    for c,ps in working.items():assert len(ps)==allocations.get(c.split(':')[0],len(original.get(c,set()))) and connectivity(ps)==1
    record.update(complete=True,total_tiles=len(owners(working)),parts=len(working),recovered_population=recovered,
        unchanged_land_mask=True,added_contacts=sorted(desired-contacts(before)),removed_contacts=sorted(contacts(before)-desired),
        remaining_unrepresented_population=sum(float(r['population']) for r in missing),enclosed_water_cells=len(water),
        changed_parts=[c for c,ps in working.items() if ps!=original.get(c,set())],
        source_assignment_count=len(assignments),source_scope_policy=str(crosswalk),
        numeric_export=False,numeric_export_reason='KOS, SOL, and CYN are source-scope IDs, not ISO numeric country codes')
    write_csv(output/'cells.csv',[dict(component_id=c,x=x,y=y) for c,ps in sorted(working.items()) for x,y in sorted(ps)])
    for name,rr in [('matches.csv',matches),('source-assignments.csv',assignments),('source-scopes-without-tiles.csv',missing)]:
        if rr:write_csv(output/name,rr)
        else:
            with (parent/name).open() as stream:(output/name).write_text(stream.readline())
    shutil.copyfile(crosswalk,output/'scope-crosswalk.csv')
    save();return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','components','polygons','crosswalk','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--seconds',type=float,default=120)
    parser.add_argument('--margin',type=int,default=12)
    raise SystemExit(0 if run(**vars(parser.parse_args()))['complete'] else 2)
