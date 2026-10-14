#!/usr/bin/env python3
"""Exchange cells around region cycles; do not construct contact paths."""
import collections

import networkx as nx

from compact_regions import Deformation


class CycleDeformation(Deformation):
    def cycle(self, moves):
        """Apply a balanced set of cell transfers, or restore the original map."""
        if len({p for p,target in moves})!=len(moves):return False
        balance=collections.Counter()
        for p,target in moves:
            balance[self.owners.get(p)]-=1;balance[target]+=1
        if any(balance.values()):raise ValueError('Unbalanced transfer cycle')
        undo=[];delta=0.
        for p,target in moves:
            if not self.possible(p,target):break
            delta+=self.delta(p,target);undo.append((p,self.change(p,target)))
        else:
            if delta < -1e-8:return True
        for p,owner in reversed(undo):self.change(p,owner)
        return False

    def step(self,choices=4):
        candidates=self.candidates(choices)
        labels=sorted(self.tiles);labels.insert(0,None)
        ids={c:i for i,c in enumerate(labels)}
        graph=nx.DiGraph();graph.add_nodes_from(range(len(labels)),demand=0)
        for (a,b),moves in sorted(candidates.items(),key=lambda item:(ids[item[0][0]],ids[item[0][1]])):
            graph.add_edge(ids[a],ids[b],capacity=1,weight=round(moves[0][0]*1_000_000))
        _,flow=nx.network_simplex(graph)
        selected={a:{b for b,value in edges.items() if value} for a,edges in flow.items()}
        changed=0
        while any(selected.values()):
            node=min(a for a,edges in selected.items() if edges);walk=[];seen={}
            while node not in seen:
                seen[node]=len(walk);walk.append(node);node=min(selected[node])
            nodes=walk[seen[node]:];edges=list(zip(nodes,nodes[1:]+nodes[:1]))
            for a,b in edges:selected[a].remove(b)
            # Try each order. Adjacent transfers can invalidate a cached move.
            moves=[(candidates[labels[a],labels[b]][0][1],labels[b]) for a,b in edges]
            if any(self.owners.get(p)!=labels[a] for (p,target),(a,b) in zip(moves,edges)):continue
            for start in range(len(moves)):
                if self.cycle(moves[start:]+moves[:start]):changed+=len(moves);break
        return changed+super().step(choices)
