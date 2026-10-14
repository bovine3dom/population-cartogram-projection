"""Check topology after a complete exchange, not after its temporary states."""
import collections

from compact_regions import adjacent
from fit_counts import CountFit
from review_layout import connectivity, holes


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
        affected.discard(None);undo=[];delta=0.
        for p,target in moves:
            if not self.possible(p,target):break
            delta+=self.delta(p,target);undo.append((p,self.change(p,target)))
        else:
            if (not decrease or delta < -1e-8) and all(self.tiles[c] and connectivity(self.tiles[c])==1 and not holes(self.tiles[c]) for c in affected):
                return True
        for p,owner in reversed(undo):self.change(p,owner)
        return False

    def exchange(self,p,q):
        a,b=self.owners.get(p),self.owners.get(q)
        return a!=b and self.transaction([(p,b),(q,a)])

    def cycle(self,moves):return self.transaction(moves)

    def transfer(self,moves):return self.transaction(moves,decrease=False,balanced=False)
