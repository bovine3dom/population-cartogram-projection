"""Replace a region with a connected source-guided shape in available space."""
import heapq

from atomic_deformation import AtomicDeformation
from compact_regions import adjacent
from geographic_baseline import simple_toggle
from review_layout import connectivity, holes


class Regrowth(AtomicDeformation):
    def region_energy(self,c,points):
        value=sum(self.cost(c,p) for p in points)
        for p in points:
            for q in adjacent(p):
                if q in points:continue
                other=self.owners.get(q)
                if other==c:other=None
                value+=self.edge_at(p,q,c,other)-self.edge_at(p,q,None,other)
        return value

    def allowed_growth(self,c,p):
        return self.inside(p) and self.owners.get(p) in (None,c)

    def regrow(self,c):
        if c in getattr(self,'fixed',()):return False
        current=self.tiles[c];count=len(current)
        if count<3:return False
        start=min(current,key=lambda p:(self.cost(c,p),p))
        grown={start};frontier=[];versions={}
        def offer(p):
            if p in grown or not self.allowed_growth(c,p):return
            version=versions.get(p,0)+1;versions[p]=version
            delta=self.cost(c,p)
            for q in adjacent(p):
                other=c if q in grown else self.owners.get(q)
                if other==c and q not in grown:other=None
                delta+=self.edge_at(p,q,c,other)-self.edge_at(p,q,None,other)
            heapq.heappush(frontier,(delta,p,version))
        def neighbours_changed(p):
            for dx in [-1,0,1]:
                for dy in [-1,0,1]:
                    q=(p[0]+dx,p[1]+dy)
                    if any(r in grown for r in adjacent(q)):offer(q)
        neighbours_changed(start)
        while len(grown)<count:
            while frontier:
                score,p,version=heapq.heappop(frontier)
                if p in grown or versions.get(p)!=version:continue
                if not simple_toggle(grown,p):continue
                grown.add(p);neighbours_changed(p);break
            else:return False
        before=self.region_energy(c,current);after=self.region_energy(c,grown)
        if after>=before-1e-8:return False
        if connectivity(grown)!=1 or holes(grown):raise AssertionError('Invalid regrown shape')
        for p in current:del self.owners[p]
        self.tiles[c]=grown
        for p in grown:
            if p in self.owners:raise AssertionError('Regrowth overlap')
            self.owners[p]=c
        return True

    def step(self,choices=4):
        changed=super().step(choices)
        for c in sorted(self.tiles,key=lambda c:(-len(self.tiles[c]),c)):
            changed+=self.regrow(c)
        return changed
