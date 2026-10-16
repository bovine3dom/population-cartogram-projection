"""Move a water vacancy through land without changing component tile counts."""
from collections import Counter
import heapq

from compact_regions import adjacent
from geographic_baseline import simple_toggle
from review_geography import exterior_water
from review_layout import connectivity


def pair(a, b):
    return tuple(sorted((a, b))) if a is not None and b is not None and a != b else None


class VacancyLayout:
    def __init__(self, tiles, required=(), landlocked=(), protected_sea=(), fixed=()):
        self.tiles = {c: set(points) for c, points in tiles.items()}
        self.owners = {p: c for c, points in tiles.items() for p in points}
        if len(self.owners) != sum(map(len, tiles.values())) or any(connectivity(p) != 1 for p in tiles.values()):
            raise ValueError('Use non-overlapping, connected components')
        self.required = set(required)
        self.fixed = set(fixed)
        self.landlocked = set(landlocked)
        self.protected_sea = set(protected_sea)
        self.exterior = exterior_water(self.owners)
        self.contacts = Counter()
        for p, c in self.owners.items():
            for q in adjacent(p):
                key = pair(c, self.owners.get(q))
                if key and p < q:
                    self.contacts[key] += 1
        self.protected_contacts = self.required & set(self.contacts)
        self.rejections = Counter()

    def update(self, changes):
        edges = {tuple(sorted((p, q))) for p in changes for q in adjacent(p)}
        before = {p: self.owners.get(p) for p in changes}
        for p, q in edges:
            key = pair(self.owners.get(p), self.owners.get(q))
            if key:
                self.contacts[key] -= 1
        for p, target in changes.items():
            owner = self.owners.pop(p, None)
            if owner is not None:
                self.tiles[owner].remove(p)
            if target is not None:
                self.owners[p] = target
                self.tiles[target].add(p)
        for p, q in edges:
            key = pair(self.owners.get(p), self.owners.get(q))
            if key:
                self.contacts[key] += 1
        return before

    def false_contacts(self):
        return sum(count > 0 and key not in self.required for key, count in self.contacts.items())

    def ocean_edges(self, c):
        return sum(q in self.exterior for p in self.tiles[c] for q in adjacent(p))

    def attempt(self, path, coastal=False):
        """Slide labels outward; leave only the first path cell empty."""
        if len(path) < 2 or len(set(path)) != len(path) or any(b not in adjacent(a) for a, b in zip(path, path[1:])):
            raise ValueError('Use a simple side-adjacent path')
        start, end = path[0], path[-1]
        if any(p not in self.owners for p in path[:-1]) or end not in self.exterior or end in self.protected_sea:
            return None
        beside_sea=any(q in self.exterior for q in adjacent(start))
        if beside_sea != coastal or not simple_toggle(self.owners, end):
            return None
        labels = [self.owners[p] for p in path[:-1]]
        changes = {p: c for p, c in zip(path[1:], labels) if self.owners.get(p) != c}
        changes[start] = None
        affected = set(labels)
        if coastal:
            affected.update(self.owners[q] for p in (start,end) for q in adjacent(p) if q in self.owners)
        if affected & self.fixed:
            return None
        counts = {c: len(self.tiles[c]) for c in affected}
        ocean = {c: self.ocean_edges(c) for c in affected & self.landlocked}
        false_before = self.false_contacts()
        false_pairs={key for key,count in self.contacts.items() if count>0 and key not in self.required} if coastal else set()
        coastal_access={c for c in affected-self.landlocked if self.ocean_edges(c)>0} if coastal else set()
        before = self.update(changes)
        self.exterior.remove(end)
        if coastal:self.exterior.add(start)
        reason = None
        if any(len(self.tiles[c]) != counts[c] for c in affected):
            raise AssertionError('Unbalanced vacancy path')
        if any(connectivity(self.tiles[c]) != 1 for c in affected):
            reason = 'component-split'
        elif any(self.contacts[key] <= 0 for key in self.protected_contacts):
            reason = 'lost-land-border'
        elif self.false_contacts() > false_before or (coastal and any(count>0 and key not in self.required|false_pairs for key,count in self.contacts.items())):
            reason = 'new-false-border'
        elif any(self.ocean_edges(c)==0 for c in coastal_access):
            reason = 'lost-coastal-access'
        elif any(self.ocean_edges(c) > n for c, n in ocean.items()):
            reason = 'new-landlocked-ocean-edge'
        if reason:
            self.update(before)
            self.exterior.add(end)
            if coastal:self.exterior.remove(start)
            self.rejections[reason] += 1
            return None
        return dict(before=before, end=end, coastal_start=start if coastal else None,
                    length=len(path)-1, changed_cells=len(changes))

    def undo(self, action):
        self.update(action['before'])
        self.exterior.add(action['end'])
        if action.get('coastal_start') is not None:self.exterior.remove(action['coastal_start'])

    def paths(self, target, maximum_cost=96, limit=64):
        """Offer short routes to exterior water, preferring fewer border shifts."""
        queue = [(0., target)]
        distance, previous = {target: 0.}, {target: None}
        offered = 0
        while queue and offered < limit:
            cost, p = heapq.heappop(queue)
            if cost != distance[p] or cost > maximum_cost:
                continue
            if p not in self.owners:
                path, q = [], p
                while q is not None:
                    path.append(q)
                    q = previous[q]
                offered += 1
                yield list(reversed(path))
                continue
            for q in adjacent(p):
                owner = self.owners.get(q)
                if owner is None:
                    if q not in self.exterior or q in self.protected_sea or not simple_toggle(self.owners, q):
                        continue
                    extra = 2*(4-sum(r in self.owners for r in adjacent(q)))
                else:
                    if owner in self.fixed:
                        continue
                    # Prefer filling a boundary corner over extending a one-cell finger.
                    incoming = self.owners[p]
                    extra = 0 if owner == incoming else 2+4*max(0, 2-sum(self.owners.get(r) == incoming for r in adjacent(q)))
                candidate = cost+1+extra
                if candidate < distance.get(q, float('inf')) and candidate <= maximum_cost:
                    distance[q], previous[q] = candidate, p
                    heapq.heappush(queue, (candidate, q))
