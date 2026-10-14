from pathlib import Path
import sys,subprocess,json,time
sys.path.insert(0,'output/auto-cartogram/gap-jobs/code-a0ef7a6')
import repair_partition,place_islands,review_layout,review_gaps,review_regions
p=Path('output/auto-cartogram');i=p/'world-500000-dissolved-input';r=p/'world-500000-cached100-repair';final=p/'world-500000-cached100-islands'
started=time.monotonic()
repair_partition.run(i,p/'world-500000-shared-footprint-guide-only/partition',r,rounds=100,relocate_fragments=True,borrow_coast=True)
place_islands.run(i,r,p/'world-dissolved/polygons.geojson',final,preserve_mainland_defects=True)
review_layout.run(i,final,'500,000 tiles: approximate flow guide, bounded repair (100 swaps maximum)')
subprocess.run(['rsvg-convert',str(final/'review.svg'),'-o',str(final/'review.png')],check=True)
g=p/'gap-reviews'/'world-500000-cached100';review_gaps.run(final/'cells.csv',g,groups=i/'groups.csv');review_regions.run(i,final,g/'regions')
print('elapsed_seconds',time.monotonic()-started,flush=True)
