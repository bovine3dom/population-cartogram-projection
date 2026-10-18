#!/usr/bin/env python3
"""Compare original, previous, and landmass-first OWID layouts."""
import argparse
import gzip
import html
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np

from dock_true_borders import contacts
from fit_owid_landmass import load
from owid_landmass_world import reference_parts
from relax_owid_islands import owners
from review_gaps import draw_layout
from review_layout import country_color


def comparison(path,labels,layouts,title):
    cells=[{p:c for c in labels for p in layout[c]} for layout in layouts]
    points=set().union(*(set(c) for c in cells));west=min(x for x,y in points);east=max(x for x,y in points)
    south=min(y for x,y in points);north=max(y for x,y in points)
    scale=min(640/(east-west+2),620/(north-south+2))
    svg=['<svg xmlns="http://www.w3.org/2000/svg" width="2100" height="780"><rect width="100%" height="100%" fill="#faf9f6"/>',
         f'<text x="20" y="28" font-family="sans-serif" font-size="22">{html.escape(title)}</text>']
    for side,owner in enumerate(cells):
        tx=lambda x:30+700*side+(x-west+.5)*scale
        ty=lambda y:130+(north-y+.5)*scale
        svg.append(f'<text x="{30+700*side}" y="80" font-family="sans-serif" font-size="18">{["Original OWID","Previous trial","Landmass-first trial"][side]}: {len(owner)} tiles</text>')
        for c in labels:
            commands=[f'M{tx(x-.5):.2f},{ty(y+.5):.2f}h{scale:.2f}v{scale:.2f}h-{scale:.2f}z' for x,y in sorted(layouts[side][c])]
            svg.append(f'<path fill="{country_color(c.split(":")[0])}" d="{" ".join(commands)}"/>')
        edges=[]
        for (x,y),c in sorted(owner.items()):
            for dx,dy in ((1,0),(0,1)):
                other=owner.get((x+dx,y+dy))
                if other is None or other==c:continue
                a=(x+.5,y-.5) if dx else (x-.5,y+.5)
                edges.append(f'M{tx(a[0]):.2f},{ty(a[1]):.2f}L{tx(x+.5):.2f},{ty(y+.5):.2f}')
        svg.append(f'<path fill="none" stroke="#555" stroke-width="1" d="{" ".join(edges)}"/>')
        for c in labels:
            ps=layouts[side][c];centre=np.mean(sorted(ps),axis=0)
            x,y=min(ps,key=lambda p:sum((np.array(p)-centre)**2))
            svg.append(f'<text x="{tx(x):.2f}" y="{ty(y):.2f}" font-family="sans-serif" font-size="12" paint-order="stroke" stroke="white" stroke-width="2">{html.escape(c)}</text>')
    path.write_text(''.join(svg)+'</svg>\n')
    subprocess.run(['rsvg-convert',str(path),'-o',str(path.with_suffix('.png'))],check=True)


def run(owid,parent,layout,output):
    record=json.loads((layout/'landmass-world.json').read_text())
    if not record['complete']:raise ValueError('Do not publish an incomplete world')
    if output.exists():raise ValueError('Use a new review directory')
    output.mkdir(parents=True)
    previous=load(parent);current=load(layout);original,_,_=reference_parts(owid,current)
    layouts=[original,previous,current];pages=[]
    # Every shared landmass gets a comparison, without an island allow-list.
    for i,entry in enumerate(record['landmasses']):
        labels=entry['parts']
        if len(labels)<2:continue
        stem=f'landmass-{i+1}';title=', '.join(labels) if len(labels)<=4 else f'{len(labels)} parts; {entry["after"]} tiles'
        comparison(output/f'{stem}.svg',labels,layouts,title)
        pages.append(f'<h2>{html.escape(title)}</h2><a href="{stem}.png"><img src="{stem}.png" alt="Landmass comparison"></a>')
    required=contacts(owners(original))
    for c in sorted(current):
        neighbours={b if a==c else a for a,b in required if c in (a,b)}
        if not neighbours or len(current[c])==len(original[c]):continue
        stem='border-'+c.replace(':','-')
        comparison(output/f'{stem}.svg',sorted(neighbours|{c}),layouts,c+' and neighbours')
        pages.append(f'<h2>{c} and neighbours</h2><a href="{stem}.png"><img src="{stem}.png" alt="Border context"></a>')
    # Also show each multipart country, including the spaces between its islands.
    for country in sorted({c.split(':')[0] for c in current}):
        labels=sorted(c for c in current if c.startswith(country+':'))
        if len(labels)<2:continue
        comparison(output/f'{country}.svg',labels,layouts,country)
        pages.append(f'<h2>{country}</h2><a href="{country}.png"><img src="{country}.png" alt="{country} island positions"></a>')
    for name,cells in zip(('original','previous','after'),layouts):
        draw_layout(output/f'world-{name}.svg',{p:c.split(':')[0] for p,c in owners(cells).items()},f'World: {name}',{}, {},borders=True)
        subprocess.run(['rsvg-convert',str(output/f'world-{name}.svg'),'-o',str(output/f'world-{name}.png')],check=True)
    for name in ('landmass-world.json','report.json','matches.csv','source-assignments.csv','source-scopes-without-tiles.csv'):shutil.copyfile(layout/name,output/name)
    for name in ('cells.csv','owid-cartogram.csv'):(output/(name+'.gz')).write_bytes(gzip.compress((layout/name).read_bytes(),mtime=0))
    relaxed=[r for r in record['landmasses'] if 'relaxed_solver' in r]
    summary='<h2>Outline checks</h2><p>'+str(len(record['landmasses']))+' landmasses; '+str(len(relaxed))+' used a bounded outline adjustment.</p>'
    summary+=f'<p>{record["total_tiles"]:,} unique land tiles. All part budgets and existing land contacts pass the checks. The {record["enclosed_water_cells"]} internal water cells remain empty. This does not add lakes missing from the original artwork.</p>'
    for r in relaxed:
        fit=r['relaxed_solver']
        summary+=f'<p>{len(r["parts"])} parts: {fit["outline_difference"]} cells differ from the scaled guide ({100*fit["outline_difference_fraction"]:.2f}% of land area). Country counts, contacts, and internal water remain fixed.</p>'
        if fit.get('method')=='validated parent seed':summary+='<p>The previous layout passed these checks and was retained for this landmass. It was not refitted.</p>'
    (output/'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OWID landmass-first world trial</title><style>body{font:18px system-ui;max-width:1600px;margin:2em auto;padding:0 1em}img{max-width:100%}</style><h1>OWID landmass-first world trial</h1><p>Research only. The default map and H3-MON export are unchanged. All shape guides come from the original OWID artwork. Population budgets and desired positions come from the previous trial. Automatic source identities still need review.</p><p>Each connected landmass is resized as one shape. Its internal borders must meet exact part budgets, connectivity, and existing contacts. A valid previous layout can be retained if it is within the outline bound. This avoids needless border changes. If the fixed-outline search fails, a bounded coastline adjustment can also be fitted. All such cases are reported below. The completed landmasses then move as whole pieces to keep sea gaps. Internal water in the artwork stays empty. Gaps between separate landmasses can open to the sea; they are not classified as geographic lakes.</p><p><a href="landmass-world.json">Every landmass and its solver result</a> · <a href="report.json">Report</a> · <a href="matches.csv">Population budgets</a> · <a href="cells.csv.gz">Tiles</a> · <a href="owid-cartogram.csv.gz">OWID-format layout</a></p>'+summary+'<h2>World after</h2><a href="world-after.png"><img src="world-after.png" alt="Whole-world trial"></a><p>Each three-panel comparison uses the same scale. Border lines separate countries with similar colours.</p>'+''.join(pages)+'</html>\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','parent','layout','output'):parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
