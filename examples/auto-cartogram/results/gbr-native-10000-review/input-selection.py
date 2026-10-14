from pathlib import Path
import csv,hashlib,json
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.ipc as ipc
base=Path('output/auto-cartogram'); out=base/'gbr-world-10000-native';out.mkdir()
def digest(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
group_path=base/'world-10000-dissolved-input/groups.csv';cell_path=base/'world-10000-dissolved-geographic/cells.csv';source_path=base/'world-transport-sources/sources.arrow'
with group_path.open() as f: groups=[r for r in csv.DictReader(f) if r['country_id']=='GBR']
components={r['component_id'] for r in groups}; represented={r['component_id'] for r in groups if int(r['tiles'])>0}
(out/'inputs').mkdir();(out/'layout').mkdir()
with (out/'inputs/groups.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(groups[0]));w.writeheader();w.writerows(groups)
with cell_path.open() as f:cells=[r for r in csv.DictReader(f) if r['component_id'] in represented]
assert len(cells)==sum(int(r['tiles']) for r in groups)
with (out/'layout/cells.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(cells[0]));w.writeheader();w.writerows(cells)
(out/'layout/complete.txt').write_text('mode=country-subset\nparent=world-10000-dissolved-geographic\n')
reader=ipc.open_file(str(source_path)); batches=[]
for i in range(reader.num_record_batches):
 batch=reader.get_batch(i);mask=pc.is_in(batch.column('component_id'),value_set=pa.array(sorted(components)))
 selected=batch.filter(mask)
 if selected.num_rows:batches.append(selected)
table=pa.Table.from_batches(batches,schema=reader.schema)
with ipc.new_file(str(out/'sources.arrow'),table.schema) as writer:writer.write_table(table)
population=pc.sum(table['value']).as_py();assert population==sum(float(r['population']) for r in groups)
metadata=dict(entity_id='GBR',source_rows=table.num_rows,source_population=population,target_tiles=len(cells),groups=len(represented),grouped_population=sum(float(r['population']) for r in groups if int(r['tiles'])==0),
 limit='This is the GBR entity subset of the 10000-tile world layout. Dependencies with other entity IDs are excluded. Country-specific unmatched coverage is unknown. It is not the handmade OWID map.',
 inputs={str(p):digest(p) for p in [source_path,group_path,cell_path,Path(__file__)]},outputs={str(p.relative_to(out)):digest(p) for p in [out/'sources.arrow',out/'inputs/groups.csv',out/'layout/cells.csv']})
(out/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n');print(json.dumps(metadata,indent=2))
