#!/usr/bin/env python3
"""Build a static image gallery that a plain file server can display."""
import argparse
import html
import json
import os
from pathlib import Path

from save_review import digest


def verify_files(bundle):
    manifest=json.loads((bundle/'bundle.json').read_text())
    for name,expected in manifest['files'].items():
        path=bundle/name
        if not path.resolve().is_relative_to(bundle.resolve()):raise ValueError('Bundle path leaves its directory')
        if digest(path)!=expected:raise ValueError(f'Bundle checksum differs: {path}')
    return manifest


def run(output,bundles,replace=False):
    if output.exists() and not replace:raise ValueError('Gallery already exists')
    cases=[]
    for bundle in bundles:
        verify_files(bundle);metrics=json.loads((bundle/'metrics.json').read_text())
        proof=json.loads((bundle/'translation-check/translation-check.json').read_text())
        if not proof['all_shapes_are_integer_translations']:raise ValueError('Unverified shape changes')
        cases.append((metrics['tile_budget'],bundle,metrics,proof))
    if not cases or len({n for n,b,m,p in cases})!=len(cases):raise ValueError('Use one bundle per resolution')
    if len({m['population_total'] for n,b,m,p in cases})!=1:raise ValueError('Bundle population scopes differ')
    scope=cases[0][2];unmatched=scope.get('unmatched_source_population')
    unmatched_label=f'{unmatched:,.0f}' if unmatched is not None else 'not assessed'
    parts=['<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
        '<title>Automatic world cartograms: image review</title>',
        '<style>body{font:17px/1.5 system-ui,sans-serif;max-width:1500px;margin:2rem auto;padding:0 1rem;background:#faf9f6;color:#242424}img{width:100%;height:auto}nav a{margin-right:1rem}table{border-collapse:collapse}th,td{text-align:left;padding:.3rem 1rem .3rem 0}article{margin:3rem 0;border-top:1px solid #bbb}a{color:#21577c}.warning{border-left:4px solid #973b28;padding:1rem}small{display:block}</style>',
        '<h1>Automatic world cartograms</h1>',
        '<p class="warning">Review candidates, not production maps. Each represented component keeps its tile shape. There are no added connector paths. Many real land borders remain separated.</p>',
        '<p>The production map has not changed. Requested tile budgets are exact; population ratios are approximate. Small islands with no tile budget remain grouped with a represented component of the same country.</p>',
        '<p>These are separate trials. Position settings can differ between resolutions. The run name identifies each saved candidate.</p>',
        '<nav>'+''.join(f'<a href="#tiles-{n}">{n:,} tiles</a>' for n,b,m,p in sorted(cases))+'</nav>']
    for n,bundle,m,proof in sorted(cases):
        relative=os.path.relpath(bundle,output.parent)
        url=lambda name:html.escape(relative+'/'+name,quote=True)
        large='review-large.png' if (bundle/'review-large.png').exists() else 'review.png'
        rows=[('Run',bundle.name),('Represented components',proof['components']),
              ('Requested / actual tiles',f'{n:,} / {m["tiles"]:,}'),('Component count error',m['absolute_tile_error']),
              ('Retained source borders',f'{m["required_contacts"]-m["missing_contacts"]} / {m["required_contacts"]}'),
              ('False borders',m['false_contacts']),('Grouped island population',f'{m["grouped_population"]:,.0f}'),
              ('Country direction errors',f'{m["country_axis_order_errors"]} / {m["country_axis_comparisons"]}'),
              ('Island direction errors',f'{m["island_axis_order_errors"]} / {m["island_axis_comparisons"]}'),
              ('Source holes omitted',m['holes_not_encoded_in_wkt'])]
        parts.extend([f'<article id="tiles-{n}"><h2>{n:,} tiles</h2>',f'<a href="{url(large)}"><img src="{url("review.png")}" alt="World cartogram with {n:,} tiles" loading="lazy"></a>',
            '<small>Open the image to inspect it at full size.</small>',
            '<table>'+''.join(f'<tr><th>{html.escape(label)}</th><td>{html.escape(str(value))}</td></tr>' for label,value in rows)+'</table>'])
        if (bundle/'regions/regions.json').exists():
            regions=json.loads((bundle/'regions/regions.json').read_text())['regions']
            parts.append('<p>Regional details: '+ ' · '.join(f'<a href="{url("regions/"+r["name"]+".png")}">{html.escape(r["name"].replace("-"," "))}</a>' for r in regions)+'</p>')
        parts.append(f'<p>Data and checks: <a href="{url("cells.csv.gz")}">generated cells</a> · <a href="{url("metrics.json")}">metrics</a> · <a href="{url("translation-check/translation-check.json")}">unchanged-shape proof</a> · <a href="{url("bundle.json")}">file checksums</a>.</p></article>')
    parts.extend(['<h2>Limits</h2>',
        f'<p>The source contains {scope["population_total"]:,.0f} matched people. Unmatched population: {unmatched_label}. Its year is unknown. No new native-resolution population transport is approved for these layouts.</p>',
        '<p>Country direction checks use main components of countries with at least 10 million people and a five-degree source separation. Island checks use a one-degree separation. These checks do not prove correct geographic positions.</p>',
        '<p>See <a href="../../shape-first.md">the research notes</a> and <a href="../../shape_work_log.md">the work log</a>. Compare <a href="../world-55000-tutte-partial-200/review.png">the earlier Tutte fit</a>.</p></html>'])
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text('\n'.join(parts)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);parser.add_argument('bundles',type=Path,nargs='+')
    parser.add_argument('--replace',action='store_true');args=parser.parse_args();run(args.output,args.bundles,args.replace)
