"""Allow small outline changes, but no false borders or distant connector cells."""
from compact_regions import adjacent
from regrow_regions import Regrowth


class BoundedDeformation(Regrowth):
    def __init__(self,*args,allowed_masks,contact_reward=.5,template_penalty=0.,fixed=(),**kwargs):
        super().__init__(*args,**kwargs)
        self.allowed_masks=allowed_masks;self.contact_reward=contact_reward
        self.templates={c:frozenset(points) for c,points in self.tiles.items()}
        self.template_penalty=template_penalty;self.fixed=frozenset(fixed)
        if not self.fixed<=self.tiles.keys():raise ValueError('Unknown fixed component')
        self.check_contacts()

    def check_contacts(self):
        for p,c in self.owners.items():
            if not self.contacts_allowed(c,p):raise ValueError('False contact in bounded layout')

    def contacts_allowed(self,c,p):
        return all(other in (None,c) or tuple(sorted((c,other))) in self.required for other in (self.owner_at(q) for q in adjacent(p)))

    def within_guide(self,c,p):
        return self.inside(p) and self.allowed_masks[c][p[1]-self.origin[1],p[0]-self.origin[0]]

    def cost(self,c,p):
        return super().cost(c,p)+(self.template_penalty if c is not None and p not in self.templates[c] else 0.)

    def possible(self,p,target):
        if target in self.fixed or self.owners.get(p) in self.fixed:return False
        return super().possible(p,target) and (target is None or (self.within_guide(target,p) and self.contacts_allowed(target,p)))

    def allowed_growth(self,c,p):
        return c not in self.fixed and super().allowed_growth(c,p) and self.within_guide(c,p) and self.contacts_allowed(c,p)

    def regrow(self,c):
        return False if c in self.fixed else super().regrow(c)

    def edge(self,a,b):
        value=super().edge(a,b)
        if a is not None and b is not None and a!=b and tuple(sorted((a,b))) in self.required:
            value-=self.contact_reward*self.perimeter
        return value
