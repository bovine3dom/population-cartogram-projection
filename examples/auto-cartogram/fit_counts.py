#!/usr/bin/env python3
"""Correct tile budgets by boundary transfers, not border-connecting paths."""
import heapq

import networkx as nx

from cycle_deformation import CycleDeformation


class CountFit(CycleDeformation):
    def transfer(self, moves):
        if len({p for p,target in moves})!=len(moves):return False
        undo=[]
        for p,target in moves:
            if not self.possible(p,target):break
            undo.append((p,self.change(p,target)))
        else:return True
        for p,owner in reversed(undo):self.change(p,owner)
        return False

    def fit_step(self,requested,choices=4,attempts=1,strict=False):
        labels=[None]+sorted(self.tiles);ids={c:i for i,c in enumerate(labels)}
        need={c:requested[c]-len(self.tiles[c]) for c in self.tiles};need[None]=-sum(need.values())
        candidates=self.candidates(choices,strict=strict)
        graph=nx.DiGraph();source=len(labels);sink=source+1
        graph.add_nodes_from(range(sink+1))
        # A common offset makes all arc costs positive. This favours short
        # region-to-region transfers and rules out unrelated negative cycles.
        offset=1+max([0.]+[-moves[0][0] for moves in candidates.values()])
        for (a,b),moves in sorted(candidates.items(),key=lambda item:(ids[item[0][0]],ids[item[0][1]])):
            graph.add_edge(ids[a],ids[b],capacity=1,weight=max(1,round((offset+moves[0][0])*1_000_000)))
        for c,value in need.items():
            if value<0:graph.add_edge(source,ids[c],capacity=-value,weight=0)
            elif value>0:graph.add_edge(ids[c],sink,capacity=value,weight=0)
        flow=nx.max_flow_min_cost(graph,source,sink)
        selected={a:{b:value for b,value in edges.items() if value} for a,edges in flow.items()}
        changed=0
        while selected[source]:
            node=source;path=[]
            while node!=sink:
                following=min(selected[node]);path.append((node,following));node=following
            for a,b in path:
                selected[a][b]-=1
                if not selected[a][b]:del selected[a][b]
            edges=path[1:-1]
            if not edges:continue
            donor,receiver=labels[edges[0][0]],labels[edges[-1][1]]
            if need[donor]>=0 or need[receiver]<=0:continue
            options=[candidates[labels[a],labels[b]] for a,b in edges]
            initial=(0,)*len(edges);queue=[(sum(o[0][0] for o in options),initial)];seen={initial}
            for _ in range(attempts):
                if not queue:break
                score,indices=heapq.heappop(queue)
                moves=[(options[i][index][1],labels[b]) for i,((a,b),index) in enumerate(zip(edges,indices))]
                if all(self.owners.get(p)==labels[a] for (p,target),(a,b) in zip(moves,edges)) and self.transfer(moves):
                    need[donor]+=1;need[receiver]-=1;changed+=1;break
                for i,index in enumerate(indices):
                    if index+1>=len(options[i]):continue
                    next_indices=indices[:i]+(index+1,)+indices[i+1:]
                    if next_indices not in seen:
                        seen.add(next_indices)
                        heapq.heappush(queue,(score-options[i][index][0]+options[i][index+1][0],next_indices))
        return changed
