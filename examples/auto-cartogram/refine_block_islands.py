#!/usr/bin/env python3
"""Repair island separation after large block moves, then restore empty lakes."""
import argparse
import json
from pathlib import Path
import subprocess

import place_lake_regions
import restore_archipelagos
import review_geography
import review_layout
import review_regions
from run_margin1_projection import ROOT, POLYGONS, LAKES
from save_review import digest


def run(parent,inputs,output):
    if output.exists():
        raise ValueError('Use a new output directory')
    saved = json.loads((parent/'run.json').read_text())
    if not saved['complete'] or digest(parent/'layout/cells.csv')!=saved['cells_sha256']:
        raise ValueError('Parent planet run is incomplete or differs')
    if saved['inputs'].get(str(inputs/'geographic-contacts.csv'))!=digest(inputs/'geographic-contacts.csv'):
        raise ValueError('Cut policy differs from the parent')
    output.mkdir(parents=True)
    record = dict(complete=False,approved=False,cuts=saved['cuts'],parent=str(parent),
                  inputs={str(p):digest(p) for p in [parent/'run.json',parent/'layout/cells.csv',parent/'coast-islands/cells.csv',inputs/'geographic-contacts.csv',LAKES,POLYGONS]},
                  script_sha256=digest(Path(__file__)),limits=['Reuse the parent tile fit. The island stage leaves mainland cells unchanged; the lake stage can move boundary cells.',
                  'The island movement limit applies beyond the minimum correction needed to satisfy source-axis separation.',
                  'No country-specific placement rule. All tile counts and retained contacts remain checked.',
                  'Lakes remain empty cells. No production export.'])
    def save():
        (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
    save()
    try:
        restore_archipelagos.run(inputs,parent/'coast-islands',POLYGONS,output/'islands',bridge_groups=True,repair_separation=True)
        lakes = json.loads(LAKES.read_text())
        settings = {k:lakes[k] for k in ['maximum_lakes','search_radius','placement_attempts','maximum_path_cost','path_attempts','bay_radius']}
        place_lake_regions.run(inputs,output/'islands',POLYGONS,ROOT/'geography-lake-guides-final',ROOT/'geography-source-coasts-55000/source-coasts.csv',output/'layout',**settings)
        record['metrics'] = review_layout.run(inputs,output/'layout',f'Planet: {len(saved["cuts"])} early cuts; island separation repaired')
        subprocess.run(['rsvg-convert',str(output/'layout/review.svg'),'-o',str(output/'layout/review.png')],check=True)
        review_regions.run(inputs,output/'layout',output/'regions')
        review_geography.run(inputs,output/'layout',POLYGONS,output/'geography')
        record.update(complete=True,cells_sha256=digest(output/'layout/cells.csv'))
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        save()
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['parent','inputs','output']:
        parser.add_argument(name,type=Path)
    run(**vars(parser.parse_args()))
