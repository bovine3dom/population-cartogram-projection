#!/usr/bin/env python3
"""Trial component matching and local OWID resizing with fixed country budgets."""
import argparse
import csv
import heapq
import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment
from shapely import affinity, transform, union_all
from shapely.geometry import Point, box, shape

from audit_owid_budgets import apportion, parts, source_scope, write_csv
from compact_regions import adjacent
from geographic_baseline import grow, simple_toggle
from shape_placement import place
from restore_reference_water import enclosed
from review_gaps import read_cells
from review_layout import connectivity
from save_review import digest

ALIASES = {'SDS':'SSD', 'PSX':'PSE', 'SAH':'ESH'}


def outline(points):
    return union_all([box(x-.5,y-.5,x+.5,y+.5) for x,y in sorted(points)])


def local_geometry(geometries, longitude, latitude):
    factor = math.cos(math.radians(latitude))
    return [transform(g, lambda xy: np.column_stack((((xy[:,0]-longitude+180)%360-180)*factor, xy[:,1]-latitude))) for g in geometries]


def visible_budgets(populations, total, minima):
    if len(populations)!=len(minima) or not populations or any(not math.isfinite(p) or p<=0 for p in populations) or any(m<1 or int(m)!=m for m in minima):
        raise ValueError('Use positive masses and integer visibility floors')
    if sum(minima)>total:raise ValueError('Visibility floor exceeds country budget')
    active=set(range(len(populations)));fixed={}
    while active:
        remaining=total-sum(fixed.values());mass=sum(populations[i] for i in active)
        low={i for i in active if populations[i]/mass*remaining<minima[i]}
        if not low:break
        for i in low:fixed[i]=minima[i]
        active-=low
    keys=sorted(active)
    if keys:
        _,counts=apportion([populations[i] for i in keys],total-sum(fixed.values()))
        fixed.update(zip(keys,counts))
    return [fixed[i] for i in range(len(populations))]


def match_components(tile_parts, rows, geometry, fixed, floors=None, target_neighbours=None, source_neighbours=None):
    """Match identities before computing budgets. Auto matches remain provisional."""
    floors=[1]*len(tile_parts) if floors is None else floors
    ids=[r['component_id'] for r in rows]
    population=np.array([float(r['population']) for r in rows])
    centres=np.array([[g.centroid.x,g.centroid.y] for g in geometry])
    targets=np.array([np.mean(sorted(p),axis=0) for p in tile_parts])
    counts=np.array([len(p) for p in tile_parts]);total=sum(counts)
    quotas=population/population.sum()*total
    allowed=np.ones((len(tile_parts),len(rows)),dtype=bool)
    if target_neighbours is not None:
        known=set().union(*source_neighbours)
        for t,neighbours in enumerate(target_neighbours):
            required=neighbours&known  # Ignore artwork-only country contacts.
            for s,actual in enumerate(source_neighbours):allowed[t,s]=required<=actual
    locked={t:ids.index(c) for t,c in fixed.items()}
    if any(not 0<=t<len(tile_parts) for t in locked) or len(set(locked.values()))!=len(locked):
        raise ValueError('Invalid reviewed crosswalk')
    if any(not allowed[t,s] for t,s in locked.items()):raise ValueError('Reviewed identity conflicts with source border context')
    # Fit positive per-axis scales. With too few anchors, use the geographic
    # extent of populated components. Never infer an identity from equal ranks.
    significant=quotas>=.25
    if not significant.any():significant[np.argmax(quotas)]=True
    lo=np.min([geometry[i].bounds[:2] for i in np.flatnonzero(significant)],axis=0)
    hi=np.max([geometry[i].bounds[2:] for i in np.flatnonzero(significant)],axis=0)
    tlo=np.min([np.min(list(p),axis=0) for p in tile_parts],axis=0)
    thi=np.max([np.max(list(p),axis=0) for p in tile_parts],axis=0)
    scale=np.maximum(thi-tlo,1)/np.maximum(hi-lo,1e-6)
    offset=tlo-lo*scale
    if len(locked)>=2:
        for axis in range(2):
            x=np.array([centres[s,axis] for s in locked.values()]);y=np.array([targets[t,axis] for t in locked])
            if np.ptp(x)>1e-5:
                slope,intercept=np.linalg.lstsq(np.column_stack((x,np.ones(len(x)))),y,rcond=None)[0]
                if slope>0:scale[axis]=slope;offset[axis]=intercept
    elif locked:
        t,s=next(iter(locked.items()));offset=targets[t]-centres[s]*scale
    mapped=centres*scale+offset
    span=np.maximum(thi-tlo,4)
    distance=np.sum(((targets[:,None,:]-mapped[None,:,:])/span)**2,axis=2)
    size=np.abs(np.log(np.maximum(counts[:,None],.25)/np.maximum(quotas[None,:],.25)))
    cost=np.where(allowed,distance+.035*size,1e6)
    chosen=dict(locked)
    ts=[i for i in range(len(tile_parts)) if i not in locked]
    ss=[i for i in range(len(rows)) if i not in locked.values()]
    if ts and ss:
        a,b=linear_sum_assignment(cost[np.ix_(ts,ss)])
        chosen.update({ts[t]:ss[s] for t,s in zip(a,b) if allowed[ts[t],ss[s]]})
    # Small islands follow the local extent of a larger matched neighbour,
    # rather than a country-wide affine fit through distorted island centres.
    anchors={t:s for t,s in chosen.items() if t in locked or (quotas[s]>=.02*total and counts[t]>=.02*total)}
    for s in range(len(rows)):
        if s in anchors.values() or not anchors:continue
        eligible={t:j for t,j in anchors.items() if quotas[j]>=4*quotas[s]}
        if not eligible:continue
        t,j=min(eligible.items(),key=lambda item:(geometry[s].distance(geometry[item[1]]),item[0]))
        if geometry[s].distance(geometry[j])>.25*math.sqrt(geometry[j].area):continue
        bounds=geometry[j].bounds;bottom=np.array(bounds[:2]);extent=np.maximum(np.array(bounds[2:])-bottom,1e-6)
        points=np.array(sorted(tile_parts[t]));lower=points.min(axis=0)-.5;upper=points.max(axis=0)+.5
        relative=(centres[s]-bottom)/extent
        inside=np.clip(relative,0,1)
        # Compress offshore distances; OWID deliberately moves remote islands.
        outside=relative-inside
        mapped[s]=lower+inside*(upper-lower)+np.sign(outside)*np.log1p(np.abs(outside))*(upper-lower)
    distance=np.sum(((targets[:,None,:]-mapped[None,:,:])/span)**2,axis=2)
    cost=np.where(allowed,distance+.07*size,1e6)
    if ts and ss:
        a,b=linear_sum_assignment(cost[np.ix_(ts,ss)])
        chosen=dict(locked);chosen.update({ts[t]:ss[s] for t,s in zip(a,b) if allowed[ts[t],ss[s]]})
    rejected={}
    for t,s in list(chosen.items()):
        if len(tile_parts)>1 and t not in locked and allowed[t].sum()>1 and cost[t,s]>.12:
            rejected[t]=s;del chosen[t]
    if not chosen:raise ValueError('No sufficiently close source identity; manual anchors required')
    # An unmatched source joins its nearest matched component in source space.
    # No target-artwork distance is used to decide where its population goes.
    groups={};records=[]
    for s,row in enumerate(rows):
        t=next((t for t,j in chosen.items() if j==s),None)
        if t is None:
            t=min(chosen,key=lambda k:(geometry[s].distance(geometry[chosen[k]]),k))
            reason='nearest_source_component'
        else:reason='reviewed_identity' if t in locked else 'automatic_identity_needs_review'
        groups[s]=t
        records.append(dict(component_id=ids[s],target_part=f'T{t+1}',population=float(population[s]),assignment=reason,
                            source_distance=geometry[s].distance(geometry[chosen[t]])))
    # Target fragments with no source identity join the nearest matched target.
    # They retain their relative area within that group, not a fictitious source.
    target_group={t:t for t in chosen}
    target_shapes=[outline(p) for p in tile_parts]
    for t in range(len(tile_parts)):
        if t not in chosen:target_group[t]=min(chosen,key=lambda k:(target_shapes[t].distance(target_shapes[k]),k))
    masses={t:sum(population[s] for s in groups if groups[s]==t) for t in chosen}
    keys=sorted(chosen)
    # Keep existing visible target pieces: reserve one cell for each piece.
    # This explicit visibility floor can prevent equal population per tile.
    group_counts=visible_budgets([masses[t] for t in keys],total,[sum(floors[k] for k,g in target_group.items() if g==t) for t in keys])
    budgets={};group_budgets={}
    for t,budget in zip(keys,group_counts):
        members=[k for k in target_group if target_group[k]==t]
        group_budgets[t]=budget
        allocated=visible_budgets([len(tile_parts[k]) for k in members],budget,[floors[k] for k in members])
        budgets.update(zip(members,allocated))
    audit=[]
    for t in range(len(tile_parts)):
        g=target_group[t];s=chosen[g]
        alternatives=sorted((float(cost[t,j]),ids[j]) for j in range(len(rows)) if j!=s)
        audit.append(dict(target_part=f'T{t+1}',group=f'T{g+1}',anchor_component=ids[s],
                          identity='reviewed' if t in locked else 'automatic_unreviewed' if t in chosen else 'nearest_target_group',
                          old_tiles=int(counts[t]),tiles=budgets[t],minimum_tiles=floors[t],group_population=float(masses[g]),group_tiles=group_budgets[g],
                          proportional_group_tiles=float(masses[g]/population.sum()*total),
                          rejected_component=ids[rejected[t]] if t in rejected else '',
                          match_cost=float(cost[t,s]),alternative_component=alternatives[0][1] if alternatives else '',
                          alternative_cost=alternatives[0][0] if alternatives else None))
    return budgets,records,audit


def resize_piece(cells, count, owner, label, protected, margin=3):
    """Edit a connected piece toward its uniformly scaled original outline."""
    original=set(cells);result=set(cells)
    guide=affinity.scale(outline(cells),*(2*[math.sqrt(count/len(cells))]),origin='centroid')
    distances={};queue=[]
    growing=count>len(cells)
    pinned={p for p in cells if any(owner.get(q) not in (None,label) for q in adjacent(p))}|(cells&protected)
    if not pinned and count!=len(cells):
        template,_=grow(outline(cells),count)
        obstacles=set(owner)-cells
        blocked=obstacles|protected|{(x+dx,y+dy) for x,y in obstacles for dx in (-1,0,1) for dy in (-1,0,1)}
        desired=np.mean(sorted(cells),axis=0);centre=np.mean(sorted(template),axis=0)
        moved=place(template,desired,blocked,maximum_radius=32,translation_bounds=[desired-centre-16,desired-centre+16])
        for p in cells:del owner[p]
        owner.update(dict.fromkeys(moved,label))
        actual=outline(moved);shift=np.mean(sorted(moved),axis=0)-desired
        shifted_guide=affinity.translate(guide,*shift)
        return moved,dict(shape_iou=actual.intersection(shifted_guide).area/actual.union(shifted_guide).area,
                          moved_tiles=len(cells-moved),added_tiles=len(moved-cells),pinned_tiles=0,translation=shift.tolist())
    def signed(p):
        if p not in distances:
            point=Point(p);d=guide.boundary.distance(point)
            distances[p]=-d if guide.covers(point) else d
        return distances[p]
    def offer(p):
        if growing:
            if p in owner or p in protected or signed(p)>margin:return
            if any(owner.get((p[0]+dx,p[1]+dy)) not in (None,label) for dx in (-1,0,1) for dy in (-1,0,1)):return
            score=signed(p)
        else:
            if p not in result or p in pinned:return
            if all(q in result for q in adjacent(p)):return
            score=-signed(p)
        heapq.heappush(queue,(score,p))
    for p in sorted(result):
        for q in adjacent(p):offer(q if growing else p)
    while len(result)!=count:
        while queue:
            _,p=heapq.heappop(queue)
            if (p in owner if growing else p not in result) or not simple_toggle(result,p):continue
            if growing:result.add(p);owner[p]=label
            else:result.remove(p);del owner[p]
            for dx in (-1,0,1):
                for dy in (-1,0,1):offer((p[0]+dx,p[1]+dy))
            break
        else:
            for p in result-original:del owner[p]
            for p in original:owner[p]=label
            raise ValueError('No topology-safe edit within the shape margin')
    assert connectivity(result)==1
    actual=outline(result)
    return result,dict(shape_iou=actual.intersection(guide).area/actual.union(guide).area,
                       moved_tiles=len(original-result),added_tiles=len(result-original),pinned_tiles=len(pinned))


def run(owid, components, polygons, iso_path, reviewed, output, contacts=None):
    if output.exists():raise ValueError('Use a new output')
    iso={r['alpha_3']:int(r['numeric']) for r in json.loads(iso_path.read_text())['3166-1']}
    reverse={v:k for k,v in iso.items()}
    old_owner,grid=read_cells(owid,owid=True)
    country_cells=defaultdict(set)
    for p,code in old_owner.items():country_cells[reverse.get(int(code),f'OWID_{code}')].add(p)
    source=defaultdict(list);scopes={}
    with components.open() as stream:
        for row in csv.DictReader(stream):
            scope=source_scope(row,iso);scope=ALIASES.get(scope,scope);scopes[row['component_id']]=scope
            if float(row['population'])>0:source[scope].append(row)
    neighbours=defaultdict(set)
    if contacts is not None:
        with contacts.open() as stream:
            for row in csv.DictReader(stream):
                a,b=row['a'],row['b']
                if a in scopes and b in scopes and scopes[a]!=scopes[b]:
                    neighbours[a].add(scopes[b]);neighbours[b].add(scopes[a])
    features={f['properties']['component_id']:shape(f['geometry']) for f in json.loads(polygons.read_text())['features']}
    locks=defaultdict(dict)
    with reviewed.open() as stream:
        for r in csv.DictReader(stream):locks[r['country']][int(r['target_part'][1:])-1]=r['component_id']
    tile_parts={c:parts(p) for c,p in country_cells.items()}
    original={f'{c}:T{i+1}':p for c,ps in tile_parts.items() for i,p in enumerate(ps)}
    current={k:set(v) for k,v in original.items()};owner={p:k for k,v in current.items() for p in v}
    water=enclosed(owner);protected=water|{q for p in water for q in adjacent(p)}
    reports=[];assignments=[];matches=[];unresolved=[]
    for c in sorted(tile_parts):
        ps=tile_parts[c];rows=sorted(source[c],key=lambda r:(-float(r['population']),r['component_id']))
        if not rows:unresolved.append(c);continue
        anchor=features[rows[0]['component_id']].centroid
        geometry=local_geometry([features[r['component_id']] for r in rows],anchor.x,anchor.y)
        floors=[max(1,len((p&protected)|{v for v in p if any(owner.get(q) not in (None,f'{c}:T{i+1}') for q in adjacent(v))})) for i,p in enumerate(ps)]
        target_neighbours=[{reverse.get(int(old_owner[q]),f'OWID_{old_owner[q]}') for p in part for q in adjacent(p) if q in old_owner and q not in country_cells[c]} for part in ps]
        budgets,record,audit=match_components(ps,rows,geometry,locks[c],floors,
            target_neighbours if contacts is not None and len(ps)>1 else None,[neighbours[r['component_id']] for r in rows])
        assignments.extend(dict(country=c,**r) for r in record)
        matches.extend(dict(country=c,**r) for r in audit)
        changed={i for i in budgets if budgets[i]!=len(ps[i])}
        edits={};status='unchanged'
        try:
            # Shrink first so growth can use the released water. Other countries
            # stay obstacles. Country edits are transactional if any part fails.
            for i in sorted(changed,key=lambda i:(budgets[i]-len(ps[i])>0,i)):
                label=f'{c}:T{i+1}'
                current[label],edits[label]=resize_piece(current[label],budgets[i],owner,label,protected)
            if enclosed(owner)!=water:raise ValueError('Enclosed water changed')
            if changed:status='resized'
        except ValueError as error:
            failed_label=label
            for i in range(len(ps)):
                label=f'{c}:T{i+1}'
                for p in current[label]:owner.pop(p,None)
            for i,p in enumerate(ps):
                label=f'{c}:T{i+1}';current[label]=set(p)
                owner.update(dict.fromkeys(p,label))
            edits={};status=f'blocked at {failed_label}: {error}'
        reports.append(dict(country=c,status=status,tiles=sum(map(len,ps)),parts=len(ps),edits=edits))
        print(c,status,flush=True)
    assert len(owner)==len(old_owner) and all(connectivity(p)==1 for p in current.values())
    assert enclosed(owner)==water
    for c,ps in tile_parts.items():assert sum(len(current[f'{c}:T{i+1}']) for i in range(len(ps)))==sum(map(len,ps))
    def borders(owners):return {tuple(sorted((c,owners[q]))) for p,c in owners.items() for q in adjacent(p) if q in owners and owners[q]!=c}
    assert borders(owner)==borders({p:k for k,v in original.items() for p in v})
    output.mkdir(parents=True)
    write_csv(output/'cells.csv',[dict(component_id=k,x=x,y=y) for k,points in sorted(current.items()) for x,y in sorted(points)])
    status_by_country={r['country']:r['status'] for r in reports}
    for r in matches:
        r['actual_tiles']=len(current[f"{r['country']}:{r['target_part']}"])
        r['resize_status']=status_by_country[r['country']]
    write_csv(output/'source-assignments.csv',assignments);write_csv(output/'matches.csv',matches)
    with owid.open() as stream:raw=[tuple(map(int,r)) for r in csv.reader(stream)]
    x0=min(r[0] for r in raw);y0=min(r[1] for r in raw);step=grid['input_grid_step']
    with (output/'owid-cartogram.csv').open('w',newline='') as stream:
        writer=csv.writer(stream,lineterminator='\n')
        for label,points in sorted(current.items()):
            c=label.split(':')[0];code=iso[c] if c in iso else int(c[5:])
            writer.writerows((x0+step*x,y0-step*y,code) for x,y in sorted(points))
    write_csv(output/'source-scopes-without-tiles.csv',[dict(country=c,population=sum(float(r['population']) for r in rows)) for c,rows in sorted(source.items()) if c not in tile_parts])
    (output/'report.json').write_text(json.dumps(dict(countries=reports,unresolved=unresolved,grid=grid,tiles=len(owner),
        enclosed_water_cells=len(water),country_counts_exact=True,part_contacts_unchanged=True,
        assigned_population=sum(r['population'] for r in assignments),
        grouped_population=sum(r['population'] for r in assignments if r['assignment']=='nearest_source_component'),
        inputs={str(p):digest(p) for p in (owid,components,polygons,iso_path,reviewed,Path(__file__))},
        dependencies={name:digest(Path(__file__).with_name(name)) for name in ('audit_owid_budgets.py','geographic_baseline.py','shape_placement.py','restore_reference_water.py','review_geography.py','review_gaps.py','review_layout.py','compact_regions.py')},
        code_aliases=ALIASES,contacts_sha256=digest(contacts) if contacts is not None else None,
        limits=['Experimental matching. Automatic identities need review before population fitting.',
                'Unreviewed matches above cost 0.12 fall back to the nearest group unless source border context uniquely identifies the component. The threshold is a trial heuristic.',
                'Nearest fallback stays within source country scope. Source scopes without OWID tiles remain unrepresented.',
                'Every target piece retains at least one tile and its pinned border/water cells. These floors can prevent exact population proportions.',
                'No new parts are created for islands joined to the mainland in OWID.',
                'Conflicting OWID labels use the existing last-row inventory convention, including Lesotho.',
                'No mapping Arrow file or production layout is replaced.']),indent=2)+'\n')
    return current,original,matches


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','components','polygons','iso_path','reviewed','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--contacts',type=Path,default=Path('output/auto-cartogram/world-55000-dissolved-input/geographic-contacts.csv'))
    run(**vars(parser.parse_args()))
