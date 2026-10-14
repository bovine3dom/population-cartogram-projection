#!/usr/bin/env python3
"""Recheck saved shape bundles without the ignored generator output directory."""
import argparse
import contextlib
import gzip
import io
import json
from pathlib import Path
import shutil
import tempfile

from build_shape_gallery import verify_files
import check_shape_translation
import review_layout
from save_review import digest


def check_island_moves(inputs,parent,layout,metadata):
    for name,path in [('cells.csv',parent/'cells.csv'),('groups.csv',inputs/'groups.csv')]:
        expected=[value for key,value in metadata['inputs'].items() if Path(key).name==name]
        if expected!=[digest(path)]:raise ValueError(f'Island parent input differs: {name}')
    rows,before,old_owner=review_layout.load(inputs,parent);_,after,new_owner=review_layout.load(inputs,layout)
    records=review_layout.read_csv(inputs/'geographic-contacts.csv')
    land={r[k] for r in records for k in ['a','b']}
    threshold=metadata['max_population_fraction']*sum(float(r['group_population']) for r in rows.values())
    if threshold!=metadata['maximum_population']:raise ValueError('Island population threshold differs')
    fixed={c for c,r in rows.items() if c in land or float(r['group_population'])>=threshold}
    def normalize(points):
        x0=min(x for x,y in points);y0=min(y for x,y in points)
        return {(x-x0,y-y0) for x,y in points}
    for c,r in rows.items():
        if len(before[c])!=int(r['tiles']) or len(after[c])!=int(r['tiles']):raise ValueError('Island count changed')
        if c in fixed:
            if before[c]!=after[c]:raise ValueError(f'Protected component moved: {c}')
        elif normalize(before[c])!=normalize(after[c]):raise ValueError(f'Island shape changed: {c}')
    contacts=lambda owner:{tuple(sorted((c,owner[q]))) for (x,y),c in owner.items() for q in [(x+1,y),(x,y+1)] if q in owner and owner[q]!=c}
    if contacts(old_owner)!=contacts(new_owner):raise ValueError('Island placement changed land contacts')
    moved=sum(before[c]!=after[c] for c in rows)
    if moved!=metadata['moved_components'] or len(rows)-len(fixed)!=metadata['eligible_isolated_components']:raise ValueError('Island move counts differ')
    return dict(fixed_components=len(fixed),eligible_components=len(rows)-len(fixed),moved_components=moved,
        all_protected_components_unchanged=True,all_moved_shapes_are_translations=True,land_contacts_unchanged=True,
        parent_cells_sha256=digest(parent/'cells.csv'),final_cells_sha256=digest(layout/'cells.csv'))


def run(bundle):
    manifest=verify_files(bundle)
    with tempfile.TemporaryDirectory(prefix='shape-recheck-') as tmp:
        root=Path(tmp);inputs=root/'input';layout=root/'layout';templates=root/'templates'
        for path in [inputs,layout,templates]:path.mkdir()
        for name in ['groups.csv','manifest.json','geographic-contacts.csv']:shutil.copyfile(bundle/('input-'+name),inputs/name)
        for path,name in [(layout,'cells.csv.gz'),(templates,'template-cells.csv.gz')]:
            (path/'cells.csv').write_bytes(gzip.decompress((bundle/name).read_bytes()))
            shutil.copyfile(bundle/'complete.txt',path/'complete.txt')
        with contextlib.redirect_stdout(io.StringIO()):actual=review_layout.run(inputs,layout,'Archive recheck')
        expected=json.loads((bundle/'metrics.json').read_text())
        compared={k:v for k,v in expected.items() if k!='review_script_sha256'}
        differences=[k for k,v in compared.items() if actual.get(k)!=v]
        if differences:raise ValueError('Rechecked metrics differ: '+', '.join(differences))
        check_shape_translation.run(inputs,templates,layout,root/'translation-check')
        if (root/'translation-check/translations.csv').read_bytes()!=(bundle/'translation-check/translations.csv').read_bytes():raise ValueError('Translation records differ')
        island_check=None
        if (bundle/'island-placement.json').exists():
            parent=root/'parent';parent.mkdir()
            (parent/'cells.csv').write_bytes(gzip.decompress((bundle/'pre-island-cells.csv.gz').read_bytes()))
            shutil.copyfile(bundle/'complete.txt',parent/'complete.txt')
            island_check=check_island_moves(inputs,parent,layout,json.loads((bundle/'island-placement.json').read_text()))
            if island_check!=json.loads((bundle/'island-move-check.json').read_text()):raise ValueError('Island move check differs')
    return dict(bundle=str(bundle),verified_files=len(manifest['files']),metric_fields_checked=len(compared),
        metrics_match=True,translations_match=True,island_move_check=island_check,
        bundle_sha256=digest(bundle/'bundle.json'),script_sha256=digest(Path(__file__)),
        limit='These checks validate the saved cells and accounting. They do not approve geographic quality or native-resolution population transport.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('bundles',type=Path,nargs='+');parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():raise ValueError('Use a new report path')
    report=[run(bundle) for bundle in args.bundles];args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
