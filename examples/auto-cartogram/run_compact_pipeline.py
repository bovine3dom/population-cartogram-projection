#!/usr/bin/env python3
"""Run and record the experimental flow-footprint pipeline. No production export."""
import argparse
import contextlib
import datetime
import json
import math
from pathlib import Path
import subprocess
import sys
import time

import partition_land
import place_islands
import prepare_flow
import repair_partition
import review_flow
import review_gaps
import review_layout
import review_regions
from save_review import digest


def run(inputs,templates,polygons,output,flow_binary=None,flow_geometry=None,stretch=1.5,flow_guide_weight=0.,sigma=None,iterations=300,flow_grid=256,flow_area_error=.01,sites=None,float_islands=False,dock_landmasses=False,borrow_coast=False):
    if output.exists():raise ValueError('Output already exists')
    if flow_geometry is None and (flow_binary is None or not flow_binary.is_file()):raise ValueError('Supply an existing flow geometry or the optional flow binary')
    shapes,_,_=review_layout.load(inputs,templates);budget=sum(int(r['tiles']) for r in shapes.values())
    if sigma is None:sigma=4*math.sqrt(budget/55000)
    if any(not math.isfinite(v) for v in [stretch,flow_guide_weight,sigma]) or min(stretch,sigma)<=0 or flow_guide_weight<0 or iterations<1:raise ValueError('Invalid pipeline settings')
    if not isinstance(flow_grid,int) or flow_grid<16 or flow_grid&(flow_grid-1):raise ValueError('Flow grid must be a power of two, at least 16')
    if not math.isfinite(flow_area_error) or not 0<flow_area_error<1:raise ValueError('Invalid flow area tolerance')
    files=[inputs/'groups.csv',inputs/'manifest.json',inputs/'validated.wkt',inputs/'geographic-contacts.csv',templates/'cells.csv',polygons,flow_geometry if flow_geometry else flow_binary]+([sites] if sites else [])
    def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
    record=dict(started_at_utc=now(),complete=False,approved_for_production=False,tile_budget=budget,stretch=stretch,flow_guide_weight=flow_guide_weight,sigma=sigma,iterations=iterations,flow_grid=flow_grid,flow_area_error=flow_area_error,sites=str(sites) if sites else None,float_islands=float_islands,dock_landmasses=dock_landmasses,borrow_coast=borrow_coast,
        inputs={str(p):digest(p) for p in files},scripts={p.name:digest(p) for p in sorted(Path(__file__).parent.glob('*.py'))},steps=[],limit='Experimental layouts only. Exact counts do not prove geographic or border accuracy. Review images and failures before selection. The optional external flow binary has an AGPL-3.0 licence and remains outside production dependencies.')
    output.mkdir(parents=True)
    def save():(output/'pipeline.json').write_text(json.dumps(record,indent=2)+'\n')
    save()
    def stage(name,call):
        started=time.monotonic();entry=dict(name=name,started_at_utc=now(),complete=False,log=name+'.log');record['steps'].append(entry);save()
        try:
            with (output/entry['log']).open('w') as stream,contextlib.redirect_stdout(stream),contextlib.redirect_stderr(stream):value=call()
            entry['complete']=True
            return value
        except Exception as error:
            entry['error']=str(error);raise
        finally:
            entry['elapsed_seconds']=time.monotonic()-started;entry['log_sha256']=digest(output/entry['log']);save()
    try:
        if flow_geometry is None:
            stage('prepare-flow',lambda:prepare_flow.run(inputs,polygons,output/'flow-input'))
            flow_dir=output/'flow';flow_dir.mkdir()
            command=[str(flow_binary.resolve()),str((output/'flow-input/geometry.geojson').resolve()),str((output/'flow-input/areas.csv').resolve()),'--skip_projection','--id','component_id','--area','tiles','--n_grid_rows_or_cols',str(flow_grid),'--max_permitted_area_error',str(flow_area_error),'--timeout','600','--export_preprocessed','--export_time_report']
            record['flow_command']=command;save()
            stage('flow',lambda:subprocess.run(command,cwd=flow_dir,stdout=sys.stdout,stderr=sys.stderr,check=True,timeout=660))
            flow_geometry=flow_dir/'areas_cartogram.geojson'
        raw=stage('check-flow',lambda:review_flow.run(inputs,flow_geometry,output/'flow-review'))
        if raw['overlap_pairs']:raise ValueError('Continuous flow has overlaps')
        record['flow_geometry_sha256']=digest(flow_geometry)
        stage('partition',lambda:partition_land.run(inputs,templates,output/'partition',sigma=sigma,iterations=iterations,power=True,by_landmass=True,flow_geometry=flow_geometry,flow_stretch=stretch,flow_guide_weight=flow_guide_weight,sites=sites,float_islands=float_islands,dock_landmasses=dock_landmasses))
        stage('repair',lambda:repair_partition.run(inputs,output/'partition',output/'repaired',relocate_fragments=True,borrow_coast=borrow_coast))
        stage('islands',lambda:place_islands.run(inputs,output/'repaired',polygons,output/'layout',preserve_mainland_defects=True))
        title=f'Automatic shared-footprint experiment: {budget:,} tiles'
        metrics=stage('metrics',lambda:review_layout.run(inputs,output/'layout',title))
        gaps=stage('gaps',lambda:review_gaps.run(output/'layout/cells.csv',output/'review',groups=inputs/'groups.csv',title=title))
        def render():
            for source,target in [(output/'layout/review.svg',output/'layout/review.png'),(output/'review/gaps.svg',output/'review/gaps.png')]:
                subprocess.run(['rsvg-convert',str(source),'-o',str(target)],check=True,stdout=sys.stdout,stderr=sys.stderr)
            review_regions.run(inputs,output/'layout',output/'review/regions')
        stage('render',render)
        record.update(complete=True,finished_at_utc=now(),cells_sha256=digest(output/'layout/cells.csv'),metrics=metrics,gaps=gaps)
    except Exception as error:
        record.update(failed_at_utc=now(),error=str(error));raise
    finally:save()
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','templates','polygons','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--flow-binary',type=Path);parser.add_argument('--flow-geometry',type=Path)
    parser.add_argument('--stretch',type=float,default=1.5);parser.add_argument('--flow-guide-weight',type=float,default=0.)
    parser.add_argument('--sigma',type=float);parser.add_argument('--iterations',type=int,default=300)
    parser.add_argument('--sites',type=Path)
    for flag in ['float-islands','dock-landmasses','borrow-coast']:parser.add_argument('--'+flag,action='store_true')
    parser.add_argument('--flow-grid',type=int,default=256)
    parser.add_argument('--flow-area-error',type=float,default=.01,help='External guide-area tolerance; final tile budgets remain exact')
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
