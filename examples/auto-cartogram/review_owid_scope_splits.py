#!/usr/bin/env python3
"""Review explicit population-scope splits without changing the land mask."""
import argparse
import gzip
import html
import json
from pathlib import Path
import shutil
import subprocess

from fit_owid_landmass import load
from owid_landmass_world import reference_parts
from relax_owid_islands import owners
from review_gaps import draw_layout
from review_owid_landmasses import comparison


def run(owid,parent,layout,output):
    record=json.loads((layout/'scope-splits.json').read_text())
    if not record['complete']:raise ValueError('Do not publish an incomplete split')
    if output.exists():raise ValueError('Use a new review directory')
    previous=load(parent);current=load(layout);original,_,_=reference_parts(owid,previous)
    output.mkdir(parents=True);pages=[]
    for entry in record['splits']:
        pool=entry['pool'];labels=entry['movable']
        comparison(output/f'{pool}.svg',labels,[original,previous,current],pool+' scope split and neighbours')
        allocation=', '.join(f'{c}: {n}' for c,n in entry['budgets'].items())
        added=', '.join(' / '.join(p) for p in entry['added_contacts']) or 'none'
        removed=', '.join(' / '.join(p) for p in entry['removed_contacts']) or 'none'
        pages.append(f'<h2>{pool}: {html.escape(allocation)}</h2><a href="{pool}.png"><img src="{pool}.png" alt="Scope split comparison"></a><p>Added contacts: {html.escape(added)}.</p><p>Removed contacts: {html.escape(removed)}.</p>')
    draw_layout(output/'world.svg',{p:c.split(':')[0] for p,c in owners(current).items()},'OWID: population-scope splits',{}, {},borders=True)
    subprocess.run(['rsvg-convert',str(output/'world.svg'),'-o',str(output/'world.png')],check=True)
    for name in ('scope-splits.json','scope-crosswalk.csv','matches.csv','source-assignments.csv','source-scopes-without-tiles.csv'):shutil.copyfile(layout/name,output/name)
    (output/'cells.csv.gz').write_bytes(gzip.compress((layout/'cells.csv').read_bytes(),mtime=0))
    (output/'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OWID population-scope splits</title><style>body{font:18px system-ui;max-width:1600px;margin:2em auto;padding:0 1em}img{max-width:100%}</style><h1>OWID population-scope splits</h1><p>Research trial. The default map and H3-MON exports are unchanged. These display scopes do not assert sovereignty.</p>'
        f'<p>The same {record["total_tiles"]:,} land cells are retained. All sea and lake positions are unchanged. Existing combined budgets are divided, not increased. Neighbouring countries keep their tile counts; some internal borders move.</p>'
        f'<p>The source assignment now includes {record["recovered_population"]:,.0f} previously unassigned people from the existing source data. This is not an increase in the source population or world tile budget.</p>'
        '<p>The Cyprus residual group includes CYP, CNM, ESB, and WSB source scopes. This is an explicit statistical bucket for the remaining six tiles, not a sovereignty assignment. Northern Cyprus receives two tiles. Buffer and base areas do not get separate visible tiles in this trial.</p>'
        '<p>KOS, SOL, and CYN are source-scope IDs, not ISO numeric country codes. The downloadable cells use these IDs. No misleading numeric OWID-format export is provided.</p>'
        '<p><a href="scope-crosswalk.csv">Scope policy</a> · <a href="scope-splits.json">Budgets, border edits, and checks</a> · <a href="source-assignments.csv">Every source assignment</a> · <a href="source-scopes-without-tiles.csv">Remaining unrepresented scopes</a> · <a href="cells.csv.gz">Land tiles</a></p>'
        +''.join(pages)+'<h2>World</h2><a href="world.png"><img src="world.png" alt="World after the scope splits"></a></html>\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','parent','layout','output'):parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
