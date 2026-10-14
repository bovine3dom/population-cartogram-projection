"""Check topology after a complete exchange, not after its temporary states."""
import collections

from compact_regions import adjacent
from fit_counts import CountFit
from review_layout import connectivity, holes
from geographic_baseline import simple_toggle


class AtomicDeformation(CountFit):
    def possible(self,p,target):
        owner=self.owners.get(p)
        return self.inside(p) and owner!=target and owner not in getattr(self,'fixed',()) and target not in getattr(self,'fixed',()) and (target is None or any(self.owners.get(q)==target for q in adjacent(p)))

    def transaction(self,moves,decrease=True,balanced=True):
        if len({p for p,target in moves})!=len(moves):return False
        balance=collections.Counter();affected=set()
        for p,target in moves:
            owner=self.owners.get(p);balance[owner]-=1;balance[target]+=1
            affected.update([owner,target])
        if balanced and any(balance.values()):raise ValueError('Unbalanced atomic exchange')
        affected.discard(None);undo=[];delta=0.;unsafe=set()
        for p,target in moves:
            if not self.possible(p,target):break
            owner=self.owners.get(p)
            # Simple toggles preserve connectivity and hole count. Only regions
            # with a non-simple intermediate change need a full final flood fill.
            for c in (owner,target):
                if c is not None and not simple_toggle(self.tiles[c],p):unsafe.add(c)
            delta+=self.delta(p,target);undo.append((p,self.change(p,target)))
        else:
            if (not decrease or delta < -1e-8) and all(self.tiles[c] and connectivity(self.tiles[c])==1 and not holes(self.tiles[c]) for c in (affected if getattr(self,'full_topology_checks',False) else unsafe)):
                return True
        for p,owner in reversed(undo):self.change(p,owner)
        return False

    def exchange(self,p,q):
        a,b=self.owners.get(p),self.owners.get(q)
        return a!=b and self.transaction([(p,b),(q,a)])

    def cycle(self,moves):return self.transaction(moves)

    def transfer(self,moves):return self.transaction(moves,decrease=False,balanced=False)
