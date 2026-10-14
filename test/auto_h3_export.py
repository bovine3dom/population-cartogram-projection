"""Check shared H3 parents, island labels, and Arrow output."""
import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

import pyarrow as pa
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from export_h3_groups import export, csv_file
from balance_transport import expand_neighbours
import numpy as np


class IslandExportTests(unittest.TestCase):
    def test_shared_parent_keeps_island_labels_and_population(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'labels').mkdir()
            (root/'balance-complete.json').write_text('{}')
            groups=[];sources=[];targets=[];features=[];cities=[]
            for i,(component,value) in enumerate([('AAA:island',30),('BBB:island',70)]):
                source=dict(id=component+':123',component_id=component,group_id=component,value=value)
                target=dict(x=i,y=2,group_id=component)
                sources.append(source);targets.append(target)
                groups.append(dict(component_id=component,country_id=component[:3],group_id=component,population=value,grouped=False))
                shard=root/'balanced'/component;shard.mkdir(parents=True)
                csv_file(shard/'sources.csv',[source]);csv_file(shard/'targets.csv',[target])
                csv_file(shard/'mapping.csv',[dict(id=source['id'],x=i,y=2,weight=1,weight_mean=1)])
                csv_file(shard/'target-quality.csv',[dict(target,population=value,expected_population=value,relative_error=0)])
                (shard/'manifest.json').write_text(json.dumps(dict(pooled=False,source_population=value,retained_population=value,retained_share=1,cross_group_population=0,minimum_source_retained_share=1,maximum_source_retained_share=1,maximum_relative_target_error=0,coarse_sources=1,targets=1,groups=1)))
                x=i*2
                features.append(dict(type='Feature',properties=dict(component_id=component),geometry=dict(type='Polygon',coordinates=[[[x,0],[x+1,0],[x+1,1],[x,1],[x,0]]])))
                cities.append(dict(name=f'City {i}',longitude=x+.5,latitude=.5,h3=123,population=100000))
            cities.append(dict(name='No fallback',longitude=10,latitude=10,h3=123,population=200000))
            for name,records in [('groups',groups),('sources',sources),('targets',targets),('labels/cities',cities),('labels/areas',[dict(h3=123,area_km2=10)])]:csv_file(root/(name+'.csv'),records)
            polygon=root/'polygons.json';polygon.write_text(json.dumps(dict(type='FeatureCollection',features=features)))
            iso=root/'iso.json';iso.write_text(json.dumps({'3166-1':[dict(alpha_3='AAA',numeric='001')]}))
            result=export(root,polygon,iso,root/'export')
            self.assertEqual(result['placed_cities'],2)
            self.assertEqual(result['cross_group_population'],0)
            with pa.memory_map(str(root/'export/cartogram_weights_auto_55000_h3_5_hilo.arrow'),'r') as stream:table=pa.ipc.open_file(stream).read_all()
            data=table.to_pydict()
            self.assertEqual(data['weight'],[.3,.7]);self.assertEqual(data['weight_mean'],[1,1])
            self.assertEqual(data['population'],[100,100]);self.assertEqual(data['y'],[-2,-2])
            self.assertEqual(data['label'],['City 0','City 1']);self.assertEqual(data['code'],[1,1000])
            self.assertTrue(pa.types.is_string(table.schema.field('label').type))
            with pa.memory_map(str(root/'export/population_density_hilo.arrow'),'r') as stream:self.assertEqual(pa.ipc.open_file(stream).read_all()['value'].to_pylist(),[10])
            with self.assertRaisesRegex(ValueError,'already exists'):export(root,polygon,iso,root/'export')
            (root/'balanced/BBB:island/sources.csv').write_text('id,component_id,group_id,value\nBBB:island:123,BBB:island,BBB:island,71\n')
            with self.assertRaises(ValueError):export(root,polygon,iso,root/'bad')
            self.assertFalse((root/'bad').exists())

    def test_repeated_expansion_stays_in_group(self):
        sources=[dict(group_id='A')]
        targets=[dict(x=i,y=0,group_id='A' if i<3 else 'B') for i in range(4)]
        row=np.array([0]);column=np.array([0]);mass=np.array([10.]);supply=np.array([10.])
        for _ in range(4):row,column,mass,_=expand_neighbours(row,column,mass,supply,sources,targets,['A'])
        self.assertEqual(set(column),{0,1,2});self.assertAlmostEqual(sum(mass),10)


if __name__=='__main__':unittest.main()
