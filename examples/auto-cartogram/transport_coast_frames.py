"""Estimate local coast positions from an existing island-group transport map."""
import csv
from collections import defaultdict

import numpy as np
from scipy.spatial import cKDTree

from review_layout import NEIGHBOURS
from save_review import digest


class TransportCoastFrames:
    def __init__(self, root, tiles, reference_tiles=None):
        reference_tiles = tiles if reference_tiles is None else reference_tiles
        if set(reference_tiles) != set(tiles) or any(len(reference_tiles[c]) != len(tiles[c]) for c in tiles):
            raise ValueError('Reference transport component budgets differ')
        sources = defaultdict(dict)
        source_file = root/'sources.csv'
        self.hashes = {str(source_file): digest(source_file)}
        with source_file.open(newline='') as stream:
            for r in csv.DictReader(stream):
                c = r['component_id']
                if c in tiles and r['group_id'] == c:
                    sources[c][r['id']] = (float(r['x']), float(r['y']))
        self.frames = {}
        for c, cells in sorted(tiles.items()):
            ids = sorted(sources[c])
            if not ids:
                raise ValueError('No local transport sources: '+c)
            indices = {identifier: i for i, identifier in enumerate(ids)}
            mapped = np.zeros((len(ids), 2))
            weights = np.zeros(len(ids))
            path = root/'balanced'/c/'mapping.csv'
            self.hashes[str(path)] = digest(path)
            targets = set()
            with path.open(newline='') as stream:
                for r in csv.DictReader(stream):
                    x, y, w = int(r['x']), int(r['y']), float(r['weight'])
                    if not np.isfinite(w) or w < 0:
                        raise ValueError('Invalid transport weight')
                    targets.add((x, y))
                    i = indices.get(r['id'])
                    if i is not None:
                        weights[i] += w
                        mapped[i] += np.array([x, y])*w
            if targets != reference_tiles[c] or not np.allclose(weights, 1., atol=1e-8, rtol=0):
                raise ValueError('Transport layout or local source weights differ: '+c)
            mapped /= weights[:, None]
            # Translate the old local frame, then snap queries to the current
            # coast. This is a placement guide, not a new population mapping.
            mapped += np.mean(sorted(cells), axis=0)-np.mean(sorted(reference_tiles[c]), axis=0)
            boundary = sorted({(x+dx*.5, y+dy*.5) for x, y in cells for dx, dy in NEIGHBOURS
                               if (x+dx, y+dy) not in cells})
            self.frames[c] = (cKDTree([sources[c][identifier] for identifier in ids]),
                              mapped, cKDTree(boundary))

    def point(self, component, position):
        tree, mapped, boundary = self.frames[component]
        distance, indices = tree.query(position, k=min(4, len(mapped)))
        weight = 1/np.maximum(np.atleast_1d(distance), 1e-10)**2
        estimate = np.average(mapped[np.atleast_1d(indices)], axis=0, weights=weight)
        _, index = boundary.query(estimate)
        return boundary.data[index]
