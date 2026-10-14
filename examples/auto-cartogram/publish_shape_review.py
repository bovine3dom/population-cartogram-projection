#!/usr/bin/env python3
"""Publish a checked, self-contained review bundle for intact-shape placement."""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import check_shape_translation
import review_layout
import review_regions
import save_review


def run(inputs,templates,layout,output,title='World: automatic shape-first population layout',regions=True):
    if output.exists():raise ValueError('Output already exists')
    metrics=review_layout.run(inputs,layout,title)
    if any(metrics[name] for name in ['absolute_tile_error','disconnected_regions','regions_with_holes','false_contacts']):
        raise ValueError('Review bundle requires exact counts, connected regions, no tile holes, and no false contacts')
    subprocess.run(['rsvg-convert',str(layout/'review.svg'),'-o',str(layout/'review.png')],check=True)
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='shape-review-',dir=output.parent))
    try:
        bundle=temp/'bundle'
        save_review.run(inputs,layout,bundle)
        correction=layout/'source-hash-correction.json'
        if correction.exists():shutil.copyfile(correction,bundle/correction.name)
        if metrics['tiles']>=110000:
            subprocess.run(['rsvg-convert',str(layout/'review.svg'),'-w','3600','-o',str(bundle/'review-large.png')],check=True)
        check_shape_translation.run(inputs,templates,layout,bundle/'translation-check')
        shutil.copyfile(inputs/'geographic-contacts.csv',bundle/'input-geographic-contacts.csv')
        for source,name in [(layout/'cells.csv','cells.csv.gz'),(templates/'cells.csv','template-cells.csv.gz')]:
            (bundle/name).write_bytes(gzip.compress(source.read_bytes(),mtime=0))
        if (bundle/'history.csv').exists():
            (bundle/'history.csv.gz').write_bytes(gzip.compress((bundle/'history.csv').read_bytes(),mtime=0));(bundle/'history.csv').unlink()
        if regions:
            review_regions.run(inputs,layout,bundle/'regions')
            for path in (bundle/'regions').glob('*.svg'):path.unlink()
        report=dict(method='Independent tile review, unchanged-template check, and headless rendering',
            limit='Requested counts are exact, not exact population ratios. Missing source contacts and omitted source holes remain in metrics.json. This bundle is not production approval.',
            files={str(p.relative_to(bundle)):save_review.digest(p) for p in sorted(bundle.rglob('*')) if p.is_file()},
            script_sha256=save_review.digest(Path(__file__)))
        (bundle/'bundle.json').write_text(json.dumps(report,indent=2)+'\n')
        bundle.rename(output)
    finally:
        shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','templates','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--title',default='World: automatic shape-first population layout')
    parser.add_argument('--no-regions',action='store_true')
    args=parser.parse_args();run(args.inputs,args.templates,args.layout,args.output,args.title,not args.no_regions)
