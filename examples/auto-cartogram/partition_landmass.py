"""Fit exact part budgets inside a fixed outline with sparse border variables."""
import time

import numpy as np
from scipy.optimize import Bounds, LinearConstraint, milp
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import breadth_first_order, maximum_flow
from scipy.spatial import cKDTree

from audit_owid_budgets import parts
from compact_regions import adjacent
from dock_true_borders import contacts


def partition(reference, footprint, budgets, radius=4, seconds=120):
    labels=sorted(reference);points=sorted(footprint)
    if set(labels)!=set(budgets) or any(n<1 or int(n)!=n for n in budgets.values()):
        raise ValueError('Use a positive integer budget for every part')
    if sum(budgets.values())!=len(points):raise ValueError('Outline area differs from budgets')
    source=set().union(*reference.values())
    centre=np.mean(sorted(source),axis=0);scale=(len(points)/len(source))**.5
    distances=np.column_stack([cKDTree(centre+scale*(np.array(sorted(reference[c]))-centre)).query(points)[0] for c in labels])
    nearest=distances.min(axis=1)
    radii=np.full(len(labels),float(radius))
    if radius<=0 or not np.isfinite(radius):raise ValueError('Use a positive candidate radius')
    # A max-flow check finds collective shortages, not just individual ones.
    # Widen only labels on the unsatisfied side of the residual minimum cut.
    for _ in range(20):
        allowed=distances<=nearest[:,None]+radii
        pi,ci=np.where(allowed);offset=1+len(labels);sink=offset+len(points)
        rr=np.r_[np.zeros(len(labels),dtype=int),ci+1,np.arange(len(points))+offset]
        cc=np.r_[np.arange(len(labels))+1,pi+offset,np.full(len(points),sink)]
        vv=np.r_[[budgets[c] for c in labels],np.ones(len(pi)+len(points),dtype=int)]
        graph=coo_matrix((vv,(rr,cc)),shape=(sink+1,sink+1)).tocsr()
        flow=maximum_flow(graph,0,sink)
        if flow.flow_value==len(points):break
        residual=graph-flow.flow;residual.eliminate_zeros()
        reachable=set(breadth_first_order(residual,0,return_predecessors=False))
        for j in range(len(labels)):
            if j+1 in reachable:radii[j]*=2
    else:return None,dict(reason='Candidate capacity search exhausted')
    choices={p:[labels[j] for j in range(len(labels)) if distances[i,j]<=nearest[i]+radii[j]]
             for i,p in enumerate(points)}
    fixed={p:cs[0] for p,cs in choices.items() if len(cs)==1}
    indices={(p,c):i for i,(p,c) in enumerate((p,c) for p in points if p not in fixed for c in choices[p])}
    lookup={p:i for i,p in enumerate(points)};label_index={c:i for i,c in enumerate(labels)}
    costs=[float(distances[lookup[p],label_index[c]]**2) for p,c in indices]
    integer_count=len(costs);constraints=[];lower=[];upper=[]
    def term(p,c):return (indices.get((p,c)),float(fixed.get(p)==c))
    def add(terms,lo=-np.inf,hi=np.inf):
        values={};constant=0.
        for (i,k),v in terms:
            if i is None:constant+=k*v
            else:values[i]=values.get(i,0)+v
        constraints.append(values);lower.append(lo-constant);upper.append(hi-constant)
    for p in points:
        if p not in fixed:add([(term(p,c),1) for c in choices[p]],1,1)
    for c in labels:add([(term(p,c),1) for p in points if c in choices[p]],budgets[c],budgets[c])
    source_coast={p for p in source if any(q not in source for q in adjacent(p))}
    coast={p for p in footprint if any(q not in footprint for q in adjacent(p))}
    owner={p:c for c,ps in reference.items() for p in ps};required=contacts(owner)
    edges=[(p,q) for p in points for q in adjacent(p) if q in footprint and p<q]
    witnesses={pair:[] for pair in required};fixed_contacts=set()
    for p,q in edges:
        for a in choices[p]:
            for b in choices[q]:
                if a==b:continue
                pair=tuple(sorted((a,b)));left=term(p,a);right=term(q,b)
                if pair not in required:add([(left,1),(right,1)],hi=1)
                elif left[1] and right[1]:fixed_contacts.add(pair)
                elif p not in fixed or q not in fixed:
                    i=len(costs);costs.append(0.);witnesses[pair].append((i,0.))
                    add([((i,0.),1),(left,-1)],hi=0)
                    add([((i,0.),1),(right,-1)],hi=0)
    for pair in required-fixed_contacts:add([(w,1) for w in witnesses[pair]],lo=1)
    # Preserve coast access, including the lack of access for inland parts.
    for c in labels:
        terms=[(term(p,c),1) for p in coast if c in choices[p]]
        if reference[c]&source_coast:add(terms,lo=1)
        else:add(terms,0,0)
    deadline=time.monotonic()+seconds;attempts=[]
    for iteration in range(40):
        remaining=deadline-time.monotonic()
        if remaining<=0:break
        rr=[];cc=[];vv=[]
        for r,values in enumerate(constraints):
            for c,v in values.items():rr.append(r);cc.append(c);vv.append(v)
        matrix=coo_matrix((vv,(rr,cc)),shape=(len(constraints),len(costs))).tocsc()
        solved=milp(costs,integrality=[1]*integer_count+[0]*(len(costs)-integer_count),bounds=Bounds(0,1),
                    constraints=LinearConstraint(matrix,lower,upper),options={'time_limit':remaining,'mip_rel_gap':.002})
        attempts.append(dict(status=int(solved.status),message=solved.message))
        if solved.x is None:break
        result={c:{p for p,k in fixed.items() if k==c} for c in labels}
        for (p,c),i in indices.items():
            if solved.x[i]>.5:result[c].add(p)
        fragments=0
        for c,ps in result.items():
            components=parts(ps)
            if len(components)==1:continue
            for fragment in components:
                # Each fragment is smaller than the exact part budget. If any
                # of it remains occupied, the part must cross its boundary.
                boundary={q for p in fragment for q in adjacent(p) if q in footprint-fragment and c in choices[q]}
                add([(term(p,c),1/len(fragment)) for p in fragment]+[(term(q,c),-1) for q in boundary],hi=0)
                fragments+=1
        if fragments:continue
        after={p:c for c,ps in result.items() for p in ps}
        assert set(after)==footprint and sum(map(len,result.values()))==len(footprint)
        assert all(len(result[c])==budgets[c] for c in labels) and contacts(after)==required
        return result,dict(attempts=attempts,variables=integer_count,radii=dict(zip(labels,radii.tolist())),complete=True)
    return None,dict(attempts=attempts,variables=integer_count,radii=dict(zip(labels,radii.tolist())),complete=False)
