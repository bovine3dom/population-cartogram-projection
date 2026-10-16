#!/usr/bin/env python3
"""Check known defects in each saved coarse Kontur stage."""
import argparse
import json
from pathlib import Path

import numpy as np

from place_islands import tile_contacts
from review_geography import exterior_water, water_edges
from review_layout import load
from run_margin1_projection import INPUTS
from save_review import digest

MANHATTAN = 'USA:cc58c4c14d03150e'
LONG_ISLAND = 'USA:c78710e5bfb7f314'
STAGES = ['fit/partition', 'fit/repaired', 'fit/border', 'fit/shared',
          'fit/islands', 'fit/coast-islands', 'fit/layout', 'docked',
          'coast-islands', 'islands', 'layout']


def audit(layout):
    rows, tiles, owner = load(INPUTS, layout)
    contacts = {tuple(sorted((rows[a]['country_id'], rows[b]['country_id'])))
                for a, b in tile_contacts(owner)}
    coasts = water_edges(tiles, owner, exterior_water(owner))
    return dict(cells_sha256=digest(layout/'cells.csv'),
                long_island_minus_manhattan=(np.mean(list(tiles[LONG_ISLAND]), axis=0)
                    - np.mean(list(tiles[MANHATTAN]), axis=0)).tolist(),
                sweden_germany_contact=('DEU', 'SWE') in contacts,
                malaysia_thailand_contact=('MYS', 'THA') in contacts,
                coasts={c: v for c, v in coasts.items()
                        if rows[c]['country_id'] in ('LTU', 'PRY')})


def plot_new_york(layout, output):
    import subprocess
    _, tiles, _ = load(INPUTS, layout)
    colours = {MANHATTAN: '#e69f00', LONG_ISLAND: '#0072b2'}
    focus = np.array(list(tiles[MANHATTAN] | tiles[LONG_ISLAND]))
    low, high = focus.min(axis=0)-8, focus.max(axis=0)+8
    size = (high-low+1)*20
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{size[0]}" height="{size[1]}">',
           '<rect width="100%" height="100%" fill="white"/>']
    for c, points in tiles.items():
        visible = [(x, y) for x, y in points if low[0] <= x <= high[0] and low[1] <= y <= high[1]]
        if not visible:
            continue
        for x, y in visible:
            svg.append(f'<rect x="{(x-low[0])*20}" y="{(high[1]-y)*20}" width="20" height="20" fill="{colours.get(c, "#cccccc")}" stroke="white"/>')
    for c, label in [(MANHATTAN, 'Manhattan'), (LONG_ISLAND, 'Long Island')]:
        centre = np.mean(list(tiles[c]), axis=0)
        svg.append(f'<text x="{(centre[0]-low[0]+.5)*20}" y="{(high[1]-centre[1]+.5)*20}" text-anchor="middle" font-family="sans-serif" font-size="16" stroke="white" stroke-width="4" paint-order="stroke">{label}</text>')
    svg.append('</svg>')
    source = output.with_suffix('.svg')
    source.write_text('\n'.join(svg))
    subprocess.run(['rsvg-convert', str(source), '-o', str(output)], check=True)


def run(parent, output):
    output.mkdir(parents=True, exist_ok=True)
    records = {stage: audit(parent/stage) for stage in STAGES if (parent/stage/'cells.csv').exists()}
    (output/'stages.json').write_text(json.dumps(records, indent=2)+'\n')
    plot_new_york(parent/'layout', output/'new-york.png')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('parent', type=Path)
    parser.add_argument('output', type=Path)
    run(**vars(parser.parse_args()))
