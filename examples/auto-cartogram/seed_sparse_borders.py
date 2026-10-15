"""Try bounded uphill border openings before ordinary downhill refinement."""
from compact_regions import adjacent
from relax_sparse_borders import gap_distance


def try_transfer(state, p, q, key):
    """Move one tile to empty space; retain every other existing true contact."""
    c = state.owners.get(p)
    if key not in state.soft or c not in key or q in state.owners or not state.possible(p, None):
        return None
    before_contacts = {k for k, n in state.contacts.items() if n > 0}
    before_count = state.contacts[key]
    delta = state.delta(p, None)
    state.change(p, None)
    if not state.possible(q, c):
        state.change(p, c)
        return None
    delta += state.delta(q, c)
    state.change(q, c)
    after_contacts = {k for k, n in state.contacts.items() if n > 0}
    valid = (state.contacts[key] < before_count and
             ((before_contacts & state.required)-{key}) <= after_contacts and
             (after_contacts-state.required) <= (before_contacts-state.required) and
             len(state.gaps) <= state.gap_budget)
    if valid:
        valid = all(gap_distance(state.tiles[a], state.tiles[b]) <= limit
                    for (a, b), limit in state.gap_limits.items() if c in (a, b))
    if not valid:
        state.change(q, None)
        state.change(p, c)
        return None
    return dict(component=c, removed=p, added=q, energy_change=delta)


def undo(state, action):
    state.change(action['added'], None)
    state.change(action['removed'], action['component'])


def seed(state, maximum_borders=1, maximum_steps=64, choices=32, maximum_increase=500., minimum_tiles=0):
    ranked = []
    for key in sorted(state.soft):
        if state.contacts[key] <= 0 or max(len(state.tiles[c]) for c in key) < minimum_tiles:
            continue
        strain = [state.cost(c, p) for c in key for p in state.tiles[c]
                  if any(state.owners.get(q) in key and state.owners.get(q) != c for q in adjacent(p))]
        ranked.append((-max(strain), key))
    reports = []
    opened = 0
    for _, key in sorted(ranked):
        if opened == maximum_borders:
            break
        actions, increase = [], 0.
        before_energy = state.energy()
        for _ in range(maximum_steps):
            if state.contacts[key] <= 0:
                break
            options = []
            for c in key:
                if c in state.fixed or len(state.tiles[c]) < minimum_tiles:
                    continue
                boundary = [p for p in sorted(state.tiles[c]) if state.possible(p, None) and
                            any(state.owners.get(q) in key and state.owners.get(q) != c for q in adjacent(p))]
                empty = {q for p in state.tiles[c] for q in adjacent(p) if q not in state.owners and state.possible(q, c)}
                additions = sorted((state.delta(q, c), q) for q in empty)[:choices]
                options.extend((state.delta(p, None)+cost, p, q) for p in boundary for cost, q in additions)
            for _, p, q in sorted(options)[:choices*2]:
                action = try_transfer(state, p, q, key)
                if action is None:
                    continue
                if increase+action['energy_change'] > maximum_increase:
                    undo(state, action)
                    continue
                actions.append(action)
                increase += action['energy_change']
                break
            else:
                break
        accepted = state.contacts[key] == 0
        if not accepted:
            for action in reversed(actions):
                undo(state, action)
        else:
            opened += 1
        expected = before_energy+(increase if accepted else 0)
        if abs(state.energy()-expected) > 1e-5:
            raise AssertionError('Seed energy or rollback differs')
        reports.append(dict(a=key[0], b=key[1], opened=accepted, moved_tiles=len(actions),
                            energy_change=increase if accepted else 0,
                            actions=actions if accepted else []))
    return reports
