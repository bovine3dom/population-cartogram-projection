"""Shape-first experiments. Run with the geometry Python environment."""
import json
import contextlib
import io
import gzip
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from shapely.geometry import Polygon, MultiPolygon, box, mapping

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
import audit_shapes as audit
import prepare_flow as flow
import compact_regions as compact
import review_flow
from cycle_deformation import CycleDeformation
from fit_counts import CountFit
import shape_placement
import place_shapes
import review_regions
import check_shape_translation
import coast_anchors
import relax_shapes
import clean_templates
import review_template
import place_islands
import publish_shape_review
import recheck_shape_bundle
import build_shape_gallery
import review_gaps
import compare_country_contacts
import land_envelope
import partition_land
import geographic_baseline
from atomic_deformation import AtomicDeformation
from regrow_regions import Regrowth
import shape_stress
from shape_stress import Stress
from concave_stress import ConcaveStress, convex_pieces
from raster_stress import RasterStress, bilinear
from smooth_raster_stress import SmoothRasterStress
from bounded_deformation import BoundedDeformation
from geographic_order import GeographicOrder


class ShapeTests(unittest.TestCase):
    def test_gap_proxy_counts_open_channels_and_enclosed_water(self):
        solid={(x,y):'a' for x in range(11) for y in range(11)}
        report,*_=review_gaps.measure(solid,(1,2))
        self.assertEqual(report['enclosed_empty_cells'],0)
        self.assertEqual(report['closing'][1]['added_empty_cells'],0)
        ring=dict(solid);del ring[5,5]
        report,*_=review_gaps.measure(ring,(1,2))
        self.assertEqual(report['enclosed_empty_cells'],1)
        channel={p:c for p,c in solid.items() if not(p[0]==5 and p[1]>=5)}
        report,*_=review_gaps.measure(channel,(1,2))
        self.assertEqual(report['enclosed_empty_cells'],0)
        self.assertGreater(report['closing'][1]['open_empty_cells'],0)
        shifted={(x+73,y-19):c for (x,y),c in channel.items()}
        self.assertEqual(review_gaps.measure(shifted,(1,2))[0],report)
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'owid.csv';path.write_text('10,20,a\n12,20,b\n10,22,a\n')
            owners,source=review_gaps.read_cells(path,True)
            self.assertEqual(source['input_grid_step'],2);self.assertEqual(len(owners),3)
            self.assertIn((0,-1),owners)
            path.write_text('10,20,a\n10,20,b\n')
            owners,source=review_gaps.read_cells(path,True)
            self.assertEqual(source['conflicting_coordinates'],1);self.assertEqual(len(owners),1)
            report=review_gaps.run(path,Path(tmp)/'review',owid=True,radii=(1,2))
            self.assertEqual(report['tiles'],1)
            self.assertTrue((Path(tmp)/'review/layout.svg').is_file())
            self.assertTrue((Path(tmp)/'review/gaps.svg').is_file())
            path.write_text('component_id,x,y\na,10,20\nb,10,20\n')
            with self.assertRaisesRegex(ValueError,'Overlapping'):review_gaps.read_cells(path)

    def test_country_contact_comparison_excludes_unmatched_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'inputs';inputs.mkdir();layout=root/'layout';layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,country_id,group_population,west,east,south,north\na,A,20000000,0,1,0,1\nb,B,20000000,10,11,0,1\n')
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (layout/'cells.csv').write_text('component_id,x,y\na,0,0\nb,1,0\n')
            (root/'owid.csv').write_text('0,0,1\n2,0,2\n4,0,3\n')
            (root/'iso.json').write_text(json.dumps({'3166-1':[dict(numeric=str(i),alpha_3=c) for i,c in enumerate(['A','B','C'],1)]}))
            report=compare_country_contacts.run(inputs,root/'owid.csv',root/'iso.json',[layout],root/'report.json')
            self.assertEqual(report['common_country_ids'],['A','B'])
            self.assertEqual(report['excluded_owid_codes'],['3'])
            self.assertEqual([c['retained'] for c in report['cases']],[1,1])
            self.assertEqual([c['unsupported'] for c in report['cases']],[0,0])
            self.assertEqual([c['axis_order_errors'] for c in report['cases']],[0,0])
            self.assertEqual(compare_country_contacts.main_components({(0,0):'A',(1,0):'A',(9,9):'A'})['A'],{(0,0),(1,0)})
            components=root/'components.csv';components.write_text('raw_country_code,country_id\n3,A\n')
            aliased=compare_country_contacts.run(inputs,root/'owid.csv',root/'iso.json',[layout],root/'aliases.json',components)
            self.assertEqual(aliased['source_aliases'],{'3':'A'});self.assertEqual(aliased['excluded_owid_codes'],[])
            components.write_text('raw_country_code,country_id\n3,A\n3,B\n')
            ambiguous=compare_country_contacts.run(inputs,root/'owid.csv',root/'iso.json',[layout],root/'ambiguous.json',components)
            self.assertEqual(ambiguous['excluded_owid_codes'],['3'])

    def test_land_envelope_keeps_area_and_excludes_fixed_islands(self):
        tiles={'a':{(x,y) for x in range(1,6) for y in range(1,6)},'b':{(x,y) for x in range(7,12) for y in range(1,6)},'island':{(6,8)}}
        target,report=land_envelope.build(tiles,{'island'},(0,0),(20,20),2.)
        self.assertEqual(int(target.sum()),50);self.assertEqual(report['target_cells'],50)
        self.assertGreater(report['initial_empty_target_cells'],0)
        for x,y in [(6,8),(5,8),(7,8),(6,7),(6,9)]:self.assertFalse(target[y,x])
        np.testing.assert_array_equal(target,land_envelope.build(tiles,{'island'},(0,0),(20,20),2.)[0])
        with self.assertRaisesRegex(ValueError,'No movable'):land_envelope.build(tiles,set(tiles),(0,0),(20,20),2.)

    def test_simple_toggle_is_sufficient_for_local_topology(self):
        ring=[(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]
        for mask in range(256):
            for centre in [False,True]:
                points={p for i,p in enumerate(ring) if mask&(1<<i)}|({(0,0)} if centre else set())
                if not points or compact.connectivity(points)!=1 or compact.holes(points):continue
                if geographic_baseline.simple_toggle(points,(0,0)):
                    result=points^{(0,0)}
                    self.assertEqual(compact.connectivity(result),1)
                    self.assertEqual(compact.holes(result),0)

    def test_regrowth_cache_matches_uncached_moves_and_energy(self):
        tiles={'a':{(x,y) for x in range(2,5) for y in range(2,5)},'b':{(x,y) for x in range(5,8) for y in range(2,5)},'c':{(5,6)}}
        for kind in [Regrowth,BoundedDeformation]:
            for seed in range(5):
                rng=np.random.default_rng(seed);costs={c:rng.random((12,12))*10 for c in tiles}
                options={'allowed_masks':{c:np.ones((12,12),dtype=bool) for c in tiles}} if kind is BoundedDeformation else {}
                mask=rng.random((12,12))>.5
                slow=kind(tiles,{('a','b')},costs,(0,0),sea_perimeter=3,sea_mask=mask,**options);slow.full_topology_checks=True
                fast=kind(tiles,{('a','b')},costs,(0,0),sea_perimeter=3,sea_mask=mask,**options);fast.cache_regrowth=True
                for _ in range(8):
                    self.assertEqual(slow.step(),fast.step())
                    self.assertEqual(slow.tiles,fast.tiles)
                    self.assertAlmostEqual(slow.energy(),fast.energy())

    def test_guide_position_fit_keeps_axes_and_budget_weighting(self):
        guides={'a':{(0,0)},'b':{(2,0)},'c':{(0,2)}}
        tiles={c:{(2*x+5,2*y+7) for x,y in points} for c,points in guides.items()}
        centres,fit=compact.fit_guide_centres(tiles,guides,{'a':1,'b':2,'c':3})
        self.assertAlmostEqual(fit['scale'],2.)
        np.testing.assert_allclose(fit['translation'],[5,7])
        for c,points in tiles.items():np.testing.assert_allclose(centres[c],list(points)[0])
        with self.assertRaisesRegex(ValueError,'labels'):compact.fit_guide_centres(tiles,{'a':{(0,0)}},{'a':1,'b':2,'c':3})

    def test_requested_guide_area_and_fixed_regrowth(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'validated.wkt').write_text('header\nheader\nregion\ta\n0 0\t1 0\t1 1\t0 1\nend\n')
            small,origin=compact.guide_costs(root,{'a':{(0,0)}},anchor=0,margin=4)
            large,other=compact.guide_costs(root,{'a':{(0,0)}},anchor=0,margin=4,budgets={'a':9})
            self.assertEqual(origin,other)
            self.assertGreater(small['a'][-origin[1],1-origin[0]],large['a'][-origin[1],1-origin[0]])
        points={(2,2),(2,3),(3,3)}
        state=Regrowth({'a':points},set(),{'a':np.zeros((8,8))},(0,0),sea_perimeter=8.)
        state.fixed=frozenset(['a'])
        self.assertFalse(state.possible((2,2),None));self.assertFalse(state.possible((3,2),'a'))
        self.assertEqual(state.step(),0);self.assertEqual(state.tiles['a'],points)

    def test_count_fit_tries_alternatives_after_a_topology_rejection(self):
        costs=np.zeros((8,8));costs[2,3]=10.
        state=AtomicDeformation({'a':{(2,2),(3,2),(4,2)}},set(),{'a':costs},(0,0))
        self.assertEqual(state.fit_step({'a':2},choices=4,attempts=1),0)
        self.assertEqual(state.fit_step({'a':2},choices=4,attempts=4),1)
        self.assertEqual(len(state.tiles['a']),2)
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        state=AtomicDeformation({'a':{(2,2),(3,2),(4,2)}},set(),{'a':costs},(0,0))
        self.assertEqual(state.fit_step({'a':2},choices=1,strict=True),1)

    def test_sea_perimeter_delta_matches_complete_energy(self):
        tiles={'a':{(2,2),(2,3)},'b':{(3,2),(3,3)}}
        for mask in [None,np.indices((8,8))[0]<3]:
            state=Regrowth(tiles,{('a','b')},{c:np.zeros((8,8)) for c in tiles},(0,0),sea_perimeter=8.,sea_mask=mask)
            self.assertEqual(state.edge('a','b'),2.)
            self.assertEqual(state.edge_at((2,3),(2,2),'a',None),9.)
            self.assertEqual(state.edge_at((2,3),(2,4),'a',None),9. if mask is None else 1.)
            for p,target in [((2,2),None),((1,3),'a'),((3,2),'a')]:
                before=state.energy();delta=state.delta(p,target);old=state.change(p,target)
                self.assertAlmostEqual(state.energy()-before,delta)
                state.change(p,old)
            current=state.tiles['a'];candidate={(1,3),(2,3)}
            before=state.energy();delta=state.region_energy('a',candidate)-state.region_energy('a',current)
            state.change((2,2),None);state.change((1,3),'a')
            self.assertAlmostEqual(state.energy()-before,delta)

    def test_opening_detects_a_thin_tail_not_a_solid_square(self):
        square={(x,y) for x in range(5) for y in range(5)}
        self.assertEqual(audit.thin_shape(square)['opening_loss'],0)
        extended=square|{(x,2) for x in range(5,12)}
        result=audit.thin_shape(extended)
        self.assertEqual(result['opening_loss'],7)
        self.assertEqual(result['cells_outside_two_by_two'],7)
        self.assertEqual(result['connected_parts'],1)
        self.assertEqual(result['holes'],0)

    def test_exchange_energy_and_counts(self):
        points={(x,y) for x in range(5) for y in range(5)}|{(x,2) for x in range(5,12)}
        state=compact.Deformation({'a':points},set(),{'a':np.zeros((30,30))},(-5,-5))
        state.costs['a'][7,16]=5.
        before=state.energy()
        self.assertTrue(state.exchange((11,2),(2,5)))
        self.assertLess(state.energy(),before)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        saved=set(state.tiles['a'])
        self.assertFalse(state.exchange((2,2),(20,20)))
        self.assertEqual(state.tiles['a'],saved)
        for p in sorted(state.owners):
            if not state.possible(p,None):continue
            energy=state.energy();delta=state.delta(p,None)
            owner=state.change(p,None)
            self.assertAlmostEqual(state.energy()-energy,delta)
            state.change(p,owner)

    def test_rounds_keep_all_regions_connected(self):
        tiles={'a':{(x,y) for x in range(4) for y in range(5)},'b':{(x,y) for x in range(4,8) for y in range(5)}}
        rng=np.random.default_rng(17)
        state=compact.Deformation(tiles,{('a','b')},{c:rng.random((20,20))*10 for c in tiles},(-5,-5))
        for _ in range(10):
            before=state.energy();state.step()
            self.assertLessEqual(state.energy(),before+1e-8)
            for c,points in state.tiles.items():
                self.assertEqual(len(points),len(tiles[c]))
                self.assertEqual(compact.connectivity(points),1)
                self.assertEqual(compact.holes(points),0)

    def test_cycle_and_budget_fit(self):
        tiles={'a':{(x,y) for x in range(4) for y in range(5)},'b':{(x,y) for x in range(4,8) for y in range(5)}}
        rng=np.random.default_rng(19)
        costs={c:rng.random((20,20))*10 for c in tiles}
        state=CycleDeformation(tiles,{('a','b')},costs,(-5,-5))
        for _ in range(5):
            energy=state.energy();state.step()
            self.assertLessEqual(state.energy(),energy+1e-8)
            self.assertEqual({c:len(p) for c,p in state.tiles.items()},{'a':20,'b':20})
        state=CountFit(tiles,{('a','b')},costs,(-5,-5))
        targets={'a':16,'b':26}
        for _ in range(20):
            old=sum(abs(len(state.tiles[c])-targets[c]) for c in targets)
            if not state.fit_step(targets):break
            self.assertLess(sum(abs(len(state.tiles[c])-targets[c]) for c in targets),old)
        self.assertEqual({c:len(p) for c,p in state.tiles.items()},targets)
        for points in state.tiles.values():
            self.assertEqual(compact.connectivity(points),1)
            self.assertEqual(compact.holes(points),0)
        saved={c:set(p) for c,p in state.tiles.items()}
        self.assertFalse(state.transfer([(next(iter(state.tiles['a'])),None),((18,18),'b')]))
        self.assertEqual(state.tiles,saved)

    def test_fast_placement_matches_exhaustive_search(self):
        rng=np.random.default_rng(31)
        for _ in range(100):
            cells={(int(x),int(y)) for x,y in rng.integers(-3,4,size=(8,2))}
            blocked={(int(x),int(y)) for x,y in rng.integers(-8,9,size=(100,2))}
            desired=tuple(rng.random(2)*10-5)
            self.assertEqual(shape_placement.place(cells,desired,blocked),geographic_baseline.place(cells,desired,blocked))

    def test_atomic_exchange_can_remove_a_long_detour(self):
        points={(x,y) for x in range(6) for y in [0,2]}|{(0,1)}
        costs={'a':np.zeros((20,20))};costs['a'][6,5]=10.
        sequential=compact.Deformation({'a':points},set(),costs,(-5,-5))
        self.assertFalse(sequential.exchange((0,1),(5,1)))
        self.assertFalse(sequential.exchange((5,1),(0,1)))
        state=AtomicDeformation({'a':points},set(),costs,(-5,-5))
        before=state.energy()
        self.assertTrue(state.exchange((0,1),(5,1)))
        self.assertLess(state.energy(),before)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        saved=set(state.tiles['a'])
        self.assertFalse(state.exchange((2,0),(10,10)))
        self.assertEqual(state.tiles['a'],saved)

    @unittest.skipUnless(shutil.which('rsvg-convert'),'Install rsvg-convert for the headless bundle test')
    def test_deformation_and_placement_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'input';layout=root/'layout';inputs.mkdir();layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles,west,east,south,north,country_id,group_population,name\na,5,0,1,40,41,A,20000000,A\nb,3,10,11,50,51,B,20000000,B\n')
            (inputs/'manifest.json').write_text(json.dumps(dict(tile_budget=8,population_total=40000000,represented_population=40000000,grouped_population=0,omitted_population=0,holes_not_encoded_in_wkt=0,policy='group')))
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (inputs/'validated.wkt').write_text('STAGE 1\nOUTLINES 2\nOUT 0\ta\n0 0\t2 0\t2 2\t0 2\nSITECOUNT 0\nOUT 1\tb\n2 0\t4 0\t4 2\t2 2\nSITECOUNT 0\n')
            (layout/'cells.csv').write_text('component_id,x,y\na,0,0\na,1,0\na,0,1\na,1,1\nb,2,0\nb,3,0\nb,2,1\nb,3,1\n')
            (layout/'complete.txt').write_text('mode=test\n')
            with contextlib.redirect_stdout(io.StringIO()):
                metadata=compact.run(inputs,layout,root/'deformed',rounds=5,fit_rounds=10,atomic=True)
                self.assertEqual(metadata['absolute_tile_error'],0)
                joint=compact.run(inputs,layout,root/'joint',rounds=5,fit_rounds=10,strict_fit=True,regrow=True,land_only=True,sea_perimeter=8,interior_sea_radius=2,guide_layout=root/'deformed')
                self.assertGreater(joint['guide_alignment']['scale'],0)
                self.assertEqual(joint['absolute_tile_error'],0)
                self.assertEqual(joint['guide_area'],'requested budget')
                compact.run(inputs,layout,root/'joint-uncached',rounds=5,fit_rounds=10,strict_fit=True,regrow=True,land_only=True,sea_perimeter=8,interior_sea_radius=2,guide_layout=root/'deformed',cache_regrowth=False,full_topology_checks=True)
                self.assertEqual((root/'joint/cells.csv').read_bytes(),(root/'joint-uncached/cells.csv').read_bytes())
                envelope=compact.run(inputs,root/'deformed',root/'envelope',rounds=3,regrow=True,land_only=True,envelope_weight=2,envelope_sigma=1)
                self.assertEqual(envelope['envelope']['target_cells'],8)
                self.assertLessEqual(envelope['final_energy'],envelope['initial_energy']+1e-8)
                self.assertEqual(envelope['envelope']['cells_sha256'],compact.digest(root/'envelope/envelope.csv'))
                partition=partition_land.run(inputs,root/'deformed',root/'partition',sigma=1,iterations=20)
                self.assertEqual(partition['cells_sha256'],compact.digest(root/'partition/cells.csv'))
                _,partition_tiles,_=compact.load(inputs,root/'partition')
                self.assertEqual({c:len(p) for c,p in partition_tiles.items()},{'a':5,'b':3})
                power=partition_land.run(inputs,root/'deformed',root/'power',sigma=1,iterations=20,guide_layout=root/'deformed',power=True)
                self.assertEqual(power['guide_alignment']['rotation_degrees'],0)
                self.assertEqual(power['cost'],'uniform squared centre distance')
                self.assertIsNone(power['guide'])
                with self.assertRaisesRegex(ValueError,'Exact starting'):partition_land.run(inputs,layout,root/'bad-partition')
                with self.assertRaisesRegex(ValueError,'exact starting'):compact.run(inputs,layout,root/'partial-envelope',regrow=True,land_only=True,envelope_weight=2)
                place_shapes.run(inputs,root/'deformed',root/'placed',anchors=root/'deformed')
                stress=shape_stress.run(inputs,root/'deformed',root/'stress',iterations=30,raster=True,no_false_contacts=True,start_from_templates=True,order_weight=1,local_order=35,mass_weighted=True)
                self.assertEqual(stress['collision_geometry'],'signed-distance raster')
                self.assertEqual(stress['order_constraints'],2)
                subprocess.run([sys.executable,shape_stress.__file__,str(inputs),str(root/'deformed'),str(root/'stress-cli'),'--iterations','30','--raster','--no-false-contacts','--start-from-templates','--order-weight','1','--local-order','35','--mass-weighted'],check=True,stdout=subprocess.DEVNULL)
                self.assertEqual((root/'stress/cells.csv').read_bytes(),(root/'stress-cli/cells.csv').read_bytes())
                seeded=shape_stress.run(inputs,root/'deformed',root/'seeded',iterations=5,raster=True,no_false_contacts=True,start_layout=root/'stress')
                self.assertEqual(seeded['seed']['target_tile_coverage'],1.)
                check_shape_translation.run(inputs,root/'deformed',root/'seeded',root/'seeded-check')
                (root/'source.json').write_text(json.dumps(dict(type='FeatureCollection',features=[])))
                relaxed=relax_shapes.run(inputs,root/'stress',root/'relaxed',root/'source.json',rounds=3)
                self.assertLessEqual(relaxed['final_energy'],relaxed['initial_energy']+1e-8)
                check_shape_translation.run(inputs,root/'deformed',root/'relaxed',root/'relaxed-check')
                bounded=compact.run(inputs,root/'stress',root/'bounded',rounds=5,bounded=True,guide=8,template_penalty=2,land_only=True)
                self.assertEqual(bounded['absolute_tile_error'],0)
                self.assertTrue(bounded['bounded'])
                self.assertIn(str(inputs/'validated.wkt'),bounded['inputs'])
                geographic_baseline.run(inputs,root/'slow-baseline')
                geographic_baseline.run(inputs,root/'fast-baseline',fast_placement=True)
                self.assertEqual((root/'slow-baseline/cells.csv').read_bytes(),(root/'fast-baseline/cells.csv').read_bytes())
                clean_templates.run(inputs,root/'fast-baseline',root/'clean-baseline')
                _,cleaned,_=compact.load(inputs,root/'clean-baseline')
                self.assertEqual({c:len(p) for c,p in cleaned.items()},{'a':5,'b':3})
                source=root/'template-source.json'
                source.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(box(i,0,i+1,1))) for i,c in enumerate(['a','b'])])))
                comparison=review_template.run(inputs,root/'fast-baseline',root/'clean-baseline',source,'A',root/'template-review')
                self.assertEqual(comparison['after_tiles'],5)
                with self.assertRaisesRegex(ValueError,'partial'):place_islands.run(inputs,layout,source,root/'partial-rejected')
                partial=place_islands.run(inputs,layout,source,root/'partial-islands',allow_partial_counts=True)
                self.assertEqual(partial['absolute_tile_error'],2)
                self.assertIn('counts=partial',(root/'partial-islands/complete.txt').read_text())
                islands=place_islands.run(inputs,root/'relaxed',source,root/'island-baseline')
                self.assertEqual(islands['moved_components'],0)
                self.assertIn('initial-stress.json',islands['parent_layout_records'])
                deformed_islands=place_islands.run(inputs,root/'bounded',source,root/'bounded-islands')
                self.assertIn('compact.json',deformed_islands['parent_layout_records'])
                clean_bundle=publish_shape_review.run(inputs,root/'clean-baseline',root/'clean-baseline',root/'clean-bundle',regions=False)
                self.assertIn('template-cleanup.json',clean_bundle['files'])
            _,tiles,owners=compact.load(inputs,root/'placed')
            self.assertEqual(len(owners),8)
            self.assertEqual({c:len(p) for c,p in tiles.items()},{'a':5,'b':3})
            proof=check_shape_translation.run(inputs,root/'deformed',root/'placed',root/'translation-check')
            self.assertTrue(proof['all_shapes_are_integer_translations'])
            broken=root/'broken';broken.mkdir();(broken/'complete.txt').write_text('mode=test\n')
            lines=(root/'placed/cells.csv').read_text().splitlines();row=lines[1].split(',');row[1]=str(int(row[1])+100);lines[1]=','.join(row)
            (broken/'cells.csv').write_text('\n'.join(lines)+'\n')
            with self.assertRaisesRegex(ValueError,'Changed template'):check_shape_translation.run(inputs,root/'deformed',broken,root/'bad-check')
            with self.assertRaisesRegex(ValueError,'Protected component moved'):recheck_shape_bundle.check_island_moves(inputs,root/'relaxed',broken,islands)
            with contextlib.redirect_stdout(io.StringIO()):
                bundle=publish_shape_review.run(inputs,root/'deformed',root/'placed',root/'bundle',regions=False)
            self.assertEqual(gzip.decompress((root/'bundle/cells.csv.gz').read_bytes()),(root/'placed/cells.csv').read_bytes())
            self.assertIn('translation-check/translation-check.json',bundle['files'])
            self.assertTrue(recheck_shape_bundle.run(root/'bundle')['metrics_match'])
            with contextlib.redirect_stdout(io.StringIO()):
                island_bundle=publish_shape_review.run(inputs,root/'deformed',root/'island-baseline',root/'island-bundle',regions=False)
            self.assertIn('pre-island-cells.csv.gz',island_bundle['files'])
            self.assertTrue(recheck_shape_bundle.run(root/'island-bundle')['island_move_check']['all_protected_components_unchanged'])
            build_shape_gallery.run(root/'index.html',[root/'bundle'])
            self.assertIn('40,000,000 matched people',(root/'index.html').read_text())
            with self.assertRaisesRegex(ValueError,'already exists'):build_shape_gallery.run(root/'index.html',[root/'bundle'])
            (root/'bundle/complete.txt').write_text('tampered')
            with self.assertRaisesRegex(ValueError,'checksum differs'):build_shape_gallery.verify_files(root/'bundle')
            crops=review_regions.run(inputs,root/'placed',root/'crops',render=False)
            self.assertEqual([r['name'] for r in crops['regions']],['europe'])
            self.assertIn('Positions are unchanged',(root/'crops/europe.svg').read_text())
            with self.assertRaisesRegex(ValueError,'already exists'):compact.run(inputs,layout,root/'deformed')
            with self.assertRaisesRegex(ValueError,'Invalid'):compact.run(inputs,layout,root/'bad',rounds=0)

    def test_regrowth_removes_detours_without_changing_counts(self):
        points={(x,y) for x in range(8) for y in [0,4]}|{(0,y) for y in range(1,4)}
        state=Regrowth({'a':points,'b':{(4,2)}},set(),{c:np.zeros((30,30)) for c in ['a','b']},(-10,-10))
        energy=state.energy();local=state.region_energy('a',points)
        self.assertTrue(state.regrow('a'))
        self.assertAlmostEqual(state.energy()-energy,state.region_energy('a',state.tiles['a'])-local)
        self.assertLess(state.energy(),energy)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(state.tiles['b'],{(4,2)})
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        self.assertFalse(state.tiles['a'] & state.tiles['b'])

    def test_region_energy_includes_the_other_regions_coast(self):
        costs={c:np.zeros((20,20)) for c in ['a','b']}
        state=Regrowth({'a':{(0,0),(1,0)},'b':{(2,0),(2,1)}},set(),costs,(-5,-5))
        old=state.energy();local=state.region_energy('a',state.tiles['a'])
        state.change((1,0),None);state.change((0,1),'a')
        self.assertAlmostEqual(state.energy()-old,state.region_energy('a',state.tiles['a'])-local)
        rng=np.random.default_rng(43)
        for _ in range(30):
            tiles={str(i):{(x,y) for x in range(3*i,3*i+3) for y in range(4)} for i in range(3)}
            state=Regrowth(tiles,set(),{c:rng.random((25,25)) for c in tiles},(-5,-5))
            for c in tiles:
                old=state.energy();local=state.region_energy(c,state.tiles[c]);state.regrow(c)
                self.assertAlmostEqual(state.energy()-old,state.region_energy(c,state.tiles[c])-local)
                self.assertLessEqual(state.energy(),old+1e-8)

    def test_stress_gradient_and_collision_separation(self):
        from scipy.optimize import minimize
        tiles={c:{(x,y) for x in range(3) for y in range(4)} for c in ['a','b']}
        state=Stress(tiles,{'a':(0.,0.),'b':(1.3,.7)},{('a','b')})
        x=state.initial.ravel().copy()+np.array([.03,.01,-.02,.04])
        value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)
        fit=minimize(state.objective,x,jac=True,method='L-BFGS-B')
        self.assertLess(fit.fun,value)
        self.assertLess(state.penetration(0,1,fit.x.reshape(-1,2))[0],.01)

    def test_concave_collision_keeps_space_in_a_bay(self):
        from shapely import union_all
        points={(x,y) for x in range(7) for y in range(7) if x<2 or y<2 or y>4}
        pieces=convex_pieces(points,tolerance=0)
        centre=np.mean(list(points),axis=0)
        geometry=union_all([Polygon(v+centre) for v,n in pieces])
        self.assertAlmostEqual(geometry.area,len(points))
        self.assertLess(geometry.area,geometry.convex_hull.area)
        tiles={'a':points,'b':{(0,0)}}
        positions={'a':centre,'b':np.array([4.,3.])}
        state=ConcaveStress(tiles,positions,set(),gap=0)
        self.assertEqual(state.pair_energy_gradient(0,1,state.initial)[0],0)
        self.assertGreater(state.penetration(0,1,state.initial)[0],0)
        x=state.initial.ravel()+np.array([.03,.02,-2.1,.07])
        value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)

    def test_border_targets_use_a_shared_source_point(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'source.json'
            source={'a':box(0,0,1,1),'b':box(1,0,2,1)}
            path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(p)) for c,p in source.items()])))
            tiles={'a':{(0,0)},'b':{(x,y) for x in range(2) for y in range(2)}}
            state=ConcaveStress(tiles,{'a':(0.,0.),'b':(2.,0.)},{('a','b')},gap=0)
            state.border_targets(path,tiles,{('a','b')})
            self.assertTrue(np.isfinite(state.targets).all())
            self.assertGreater(state.targets[0,0],1)
            self.assertLess(abs(state.targets[0,1]),.01)
            source['b']=box(3,0,4,1)
            path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(p)) for c,p in source.items()])))
            with self.assertRaisesRegex(ValueError,'No source border'):state.border_targets(path,tiles,{('a','b')})

    def test_conditional_translation_cost_and_hard_collisions(self):
        tiles={'a':{(0,0),(1,0)},'b':{(8,0),(9,0)},'c':{(4,6)}}
        centres={'a':(0.,0.),'b':(3.,0.),'c':(1.,4.)}
        rows={c:dict(country_id=c,group_population=20_000_000,west=i*10,east=i*10+1,south=i*8,north=i*8+1) for i,c in enumerate(tiles)}
        state=shape_stress.Stress(tiles,centres,set(),anchor=.1)
        state.order=GeographicOrder(state.labels,rows);state.order_weight=2.;state.pairs=np.empty((0,2),dtype=int)
        positions=np.array([np.mean(list(tiles[c]),axis=0) for c in state.labels])
        for i in range(3):
            optimum,cost=relax_shapes.conditional(state,i,positions)
            changed=positions.copy();changed[i]=optimum
            delta=state.objective(changed.ravel())[0]-state.objective(positions.ravel())[0]
            self.assertAlmostEqual(delta,cost(optimum)-cost(positions[i]))
            self.assertLessEqual(delta,1e-8)
        with contextlib.redirect_stdout(io.StringIO()):result,history=relax_shapes.relax(state,tiles,set(),10)
        self.assertLess(history[-1]['energy'],state.objective(positions.ravel())[0])
        for c,points in result.items():
            old=min(tiles[c]);new=min(points);dx=new[0]-old[0];dy=new[1]-old[1]
            self.assertEqual(points,{(x+dx,y+dy) for x,y in tiles[c]})
            for other in result:
                if other!=c:self.assertFalse(points & (result[other]|{q for p in result[other] for q in compact.adjacent(p)}))

    def test_coast_anchors_keep_an_island_beyond_the_scaled_coast(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'source.json'
            source={'a':box(-1,1,1,3),'b':box(-.1,-.2,.1,0)}
            path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(p)) for c,p in source.items()])))
            tiles={'a':{(x,y) for x in range(20) for y in range(20)},'b':{(0,0)}}
            state=shape_stress.Stress(tiles,{'a':(0.,2.),'b':(0.,-.1)},set(),gap=0)
            self.assertEqual(coast_anchors.apply(state,path,tiles,set(),.00001,1.),1)
            self.assertLess(state.targets[0,1],-10.)
            saved=state.targets.copy()
            self.assertEqual(coast_anchors.apply(state,path,tiles,{('a','b')},.00001,1.),0)
            np.testing.assert_array_equal(state.targets,saved)
            coast_anchors.apply(state,path,tiles,set(),0.)
            touching=state.targets.copy()
            coast_anchors.apply(state,path,tiles,set(),100.)
            gap=np.linalg.norm(state.targets-touching)
            self.assertGreater(gap,1.)
            self.assertLess(gap,3.)
            np.testing.assert_array_equal(coast_anchors.template_point(np.zeros((1,2)),np.array([100.,0.])),[.5,0.])

    def test_placement_can_forbid_false_contacts_without_adding_paths(self):
        tiles={'a':{(0,0),(1,0)},'b':{(0,0),(1,0)}};desired={'a':(.5,0),'b':(.5,1)}
        separate=shape_placement.place_all(tiles,desired,required=set())
        self.assertFalse(any(q in separate['b'] for p in separate['a'] for q in compact.adjacent(p)))
        touching=shape_placement.place_all(tiles,desired,required={('a','b')})
        self.assertTrue(any(q in touching['b'] for p in touching['a'] for q in compact.adjacent(p)))
        for result in [separate,touching]:
            self.assertEqual({c:len(p) for c,p in result.items()},{'a':2,'b':2})
            self.assertFalse(result['a'] & result['b'])

    def test_raster_collision_matches_direct_distance_samples(self):
        tiles={'a':{(x,y) for x in range(3) for y in range(4)},'b':{(0,0),(1,0),(0,1)}}
        state=RasterStress(tiles,{'a':(0.,0.),'b':(1.37,.22)},set(),gap=.3)
        value,gradient=state.pair_energy_gradient(0,1,state.initial);direct=0.
        for a,b in [(0,1),(1,0)]:
            points=np.array(sorted(tiles[state.labels[a]]),dtype=float);points-=points.mean(axis=0)
            _,penalty,origin=state.fields[b]
            for point in points:
                direct+=bilinear(penalty,*(point+state.initial[a]-state.initial[b]-origin))[0]
        self.assertAlmostEqual(value,.5*state.collision*direct)
        x=state.initial.ravel();numeric=[]
        for i in range(2):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.pair_energy_gradient(0,1,(x+shift).reshape(-1,2))[0]-state.pair_energy_gradient(0,1,(x-shift).reshape(-1,2))[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)
        bay={(x,y) for x in range(7) for y in range(7) if x<2 or y<2 or y>4}
        state=RasterStress({'a':bay,'b':{(0,0)}},{'a':np.mean(list(bay),axis=0),'b':(4.,3.)},set(),gap=0)
        self.assertAlmostEqual(state.pair_energy_gradient(0,1,state.initial)[0],0)
        state.initial[1]=[0.,3.]
        self.assertGreater(state.pair_energy_gradient(0,1,state.initial)[0],0)

    def test_smooth_raster_gradient(self):
        tiles={'a':{(x,y) for x in range(3) for y in range(4)},'b':{(0,0),(1,0),(0,1)}}
        state=SmoothRasterStress(tiles,{'a':(0.,0.),'b':(1.37,.22)},set(),gap=.3)
        x=state.initial.ravel();value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        self.assertGreater(value,0)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)

    def test_bounded_deformation_forbids_false_contacts_and_distant_cells(self):
        tiles={'a':{(0,0),(0,1)},'b':{(2,0),(2,1)}}
        costs={c:np.zeros((15,15)) for c in tiles};masks={c:np.ones((15,15),dtype=bool) for c in tiles}
        state=BoundedDeformation(tiles,set(),costs,(-5,-5),allowed_masks=masks)
        self.assertFalse(state.possible((1,0),'a'))
        self.assertFalse(state.allowed_growth('a',(1,0)))
        state=BoundedDeformation(tiles,{('a','b')},costs,(-5,-5),allowed_masks=masks)
        self.assertTrue(state.possible((1,0),'a'))
        masks['a'][5,6]=False
        self.assertFalse(state.possible((1,0),'a'))
        self.assertAlmostEqual(state.edge('a','b'),1.5)
        with self.assertRaisesRegex(ValueError,'False contact'):
            BoundedDeformation({'a':{(0,0)},'b':{(1,0)}},set(),costs,(-5,-5),allowed_masks=masks)

    def test_bounded_deformation_keeps_fixed_shapes_and_charges_for_new_cells(self):
        tiles={'a':{(0,0),(0,1),(1,0)},'b':{(5,0),(5,1),(6,0)}}
        costs={c:np.zeros((15,15)) for c in tiles};masks={c:np.ones((15,15),dtype=bool) for c in tiles}
        state=BoundedDeformation(tiles,set(),costs,(-5,-5),allowed_masks=masks,template_penalty=4,fixed={'a'})
        self.assertEqual(state.cost('b',(5,0)),0)
        self.assertEqual(state.cost('b',(5,2)),4)
        self.assertFalse(state.possible((0,0),None))
        self.assertFalse(state.allowed_growth('a',(1,1)))
        self.assertFalse(state.regrow('a'))
        self.assertFalse(state.exchange((0,0),(2,0)))
        self.assertEqual(state.tiles['a'],tiles['a'])

    def test_geographic_order_gradient_and_longitude_seam(self):
        rows={'a':dict(country_id='A',group_population=20e6,west=0,east=2,south=0,north=2),
              'b':dict(country_id='B',group_population=20e6,west=10,east=12,south=10,north=12)}
        state=GeographicOrder(['a','b'],rows)
        self.assertEqual(state.count,2)
        positions=np.array([[4.,5.],[0.,0.]]);value,gradient=state.objective(positions)
        self.assertGreater(value,0)
        numeric=[]
        for i in range(4):
            shift=np.zeros(4);shift[i]=1e-6;shift=shift.reshape(2,2)
            numeric.append((state.objective(positions+shift)[0]-state.objective(positions-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient.ravel(),numeric,atol=1e-6)
        self.assertEqual(state.objective(positions[::-1])[0],0)
        rows['a'].update(west=-179,east=-177);rows['b'].update(west=177,east=179)
        self.assertEqual(GeographicOrder(['a','b'],rows).count,1)

    def test_islands_follow_nearby_larger_coasts_not_country_membership(self):
        tiles={'m':{(x,y) for x in range(20) for y in range(20)},'far':{(x+50,y+50) for x in range(4) for y in range(4)},'island':{(30,30)}}
        rows={'m':dict(country_id='B',group_population=1e6),'far':dict(country_id='A',group_population=2e6),'island':dict(country_id='A',group_population=1000)}
        source={'m':box(0,1,2,3),'far':box(20,20,22,22),'island':box(.8,0,1.2,.4)}
        result,records=place_islands.place_islands(tiles,rows,source,{'m','far'},1.,10.)
        self.assertEqual(records[0]['anchor'],'m')
        self.assertEqual(result['m'],tiles['m']);self.assertEqual(result['far'],tiles['far'])
        self.assertEqual(len(result['island']),1)
        self.assertLess(next(iter(result['island']))[1],0)
        self.assertFalse(any(q in result['m'] for p in result['island'] for q in compact.adjacent(p)))
        fixed,records=place_islands.place_islands(tiles,rows,source,{'m','far'},1.,10.,maximum_population=500)
        self.assertEqual(fixed,tiles)
        self.assertEqual(records,[])

    def test_cross_resolution_seed_scales_centres_and_checks_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);(path/'complete.txt').write_text('mode=test\n')
            (path/'cells.csv').write_text('component_id,x,y\na,0,0\nb,10,0\n')
            tiles={c:{(x,y) for x in range(10) for y in range(10)} for c in ['a','b']};tiles['c']={(0,0)}
            state=shape_stress.Stress(tiles,{'a':(0.,0.),'b':(2.,0.),'c':(1.,1.)},set())
            start,report=shape_stress.seed_positions(state,tiles,path)
            self.assertEqual(report['new_components'],1)
            np.testing.assert_allclose(start[1],[10*np.sqrt(201/2),0])
            self.assertTrue(np.isfinite(start).all())
            self.assertGreater(start[2,0],state.initial[2,0])
            (path/'cells.csv').write_text('component_id,x,y\na,0,0\nb,0,0\n')
            with self.assertRaisesRegex(ValueError,'overlap'):shape_stress.seed_positions(state,tiles,path)
            (path/'cells.csv').write_text('component_id,x,y\nz,0,0\n')
            with self.assertRaisesRegex(ValueError,'95%'):shape_stress.seed_positions(state,tiles,path)

    def test_population_weights_reduce_tiny_island_forces(self):
        tiles={c:{(i,0)} for i,c in enumerate(['a','b','c'])};centres={'a':(0.,0.),'b':(2.,0.),'c':(1.,1.)}
        rows={c:dict(country_id='A' if c in ['a','c'] else 'B',group_population=mass,west=i*10,east=i*10+1,south=0,north=1) for i,(c,mass) in enumerate([('a',100_000_000),('b',100_000_000),('c',1000)])}
        state=shape_stress.Stress(tiles,centres,set());shape_stress.weight_springs(state,rows)
        weights={tuple(state.labels[i] for i in pair):w for pair,w in zip(state.edges,state.weights)}
        self.assertLess(weights[('a','c')],weights[('a','b')]/10)
        scaled={c:dict(r,group_population=r['group_population']*10) for c,r in rows.items()}
        second=shape_stress.Stress(tiles,centres,set());shape_stress.weight_springs(second,scaled)
        np.testing.assert_allclose(state.weights,second.weights)
        plain=GeographicOrder(['a','c'],rows);weighted=GeographicOrder(['a','c'],rows,mass_weighted=True)
        self.assertTrue(np.all(weighted.weight<plain.weight))

    def test_local_order_includes_small_neighbours_but_not_distant_countries(self):
        rows={'a':dict(country_id='A',group_population=1e6,west=0,east=2,south=0,north=2),
              'b':dict(country_id='B',group_population=20e6,west=10,east=12,south=10,north=12),
              'c':dict(country_id='C',group_population=20e6,west=130,east=132,south=40,north=42)}
        state=GeographicOrder(['a','b','c'],rows,local_degrees=35)
        self.assertEqual(state.count,2)
        self.assertTrue(np.all(state.weight<1))
        positions=np.array([[4.,5.],[0.,0.],[100.,100.]])
        _,gradient=state.objective(positions)
        numeric=[]
        for i in range(6):
            shift=np.zeros(6);shift[i]=1e-6;shift=shift.reshape(3,2)
            numeric.append((state.objective(positions+shift)[0]-state.objective(positions-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient.ravel(),numeric,atol=1e-6)
        np.testing.assert_array_equal(gradient[2],[0.,0.])

    def test_template_cleanup_closes_an_interior_cut_without_count_error(self):
        cells={(x,y) for x in range(7) for y in range(7)}-{(3,y) for y in range(3,7)}|{(7,y) for y in range(4)}
        result,report=clean_templates.clean(cells,box(-.5,-.5,6.5,6.5))
        self.assertTrue(report['accepted'])
        self.assertGreater(report['intersection_gain'],0)
        self.assertGreater(report['perimeter_reduction'],0)
        self.assertEqual(len(result),len(cells))
        self.assertEqual(compact.connectivity(result),1)
        self.assertEqual(compact.holes(result),0)
        single,report=clean_templates.clean({(0,0)},box(-.5,-.5,.5,.5))
        self.assertEqual(single,{(0,0)})
        self.assertFalse(report['accepted'])

    def test_single_cell_is_not_removed(self):
        state=compact.Deformation({'a':{(0,0)}},set(),{'a':np.zeros((10,10))},(-5,-5))
        self.assertFalse(state.exchange((0,0),(1,0)))
        self.assertEqual(state.tiles['a'],{(0,0)})

    def test_outline_score_is_translation_and_scale_invariant(self):
        cells={(x,y) for x in range(4) for y in range(4)}
        self.assertAlmostEqual(audit.outline_similarity(cells,box(-10,-10,10,10)),1)
        self.assertAlmostEqual(audit.outline_similarity({(x+100,y-60) for x,y in cells},box(0,0,1,1)),1)
        self.assertLess(audit.outline_similarity(cells,box(0,0,1,10)),.3)

    def test_regional_label_uses_the_wide_part_of_a_shape(self):
        points={(x,y) for x in range(5) for y in range(5)}|{(x,2) for x in range(5,20)}
        self.assertEqual(review_regions.label_point(points),(2,2))

    def test_equal_earth_symmetry_and_origin(self):
        points=flow.equal_earth(np.array([[0.,0.],[30.,50.],[-30.,50.],[30.,-50.]]))
        np.testing.assert_allclose(points[0],[0,0])
        np.testing.assert_allclose(points[1],points[2]*[-1,1])
        np.testing.assert_allclose(points[1],points[3]*[1,-1])
        self.assertTrue(np.all(np.isfinite(points)))

    def test_flow_reader_rejects_split_or_duplicate_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'shapes.json'
            def write(geometry,duplicate=False):
                feature=dict(type='Feature',properties=dict(component_id='a'),geometry=mapping(geometry))
                path.write_text(json.dumps(dict(type='FeatureCollection',features=[feature]*(2 if duplicate else 1))))
            write(MultiPolygon([box(0,0,1,1)]))
            self.assertEqual(review_flow.read_shapes(path)['a'].geom_type,'Polygon')
            write(MultiPolygon([box(0,0,1,1),box(2,0,3,1)]))
            with self.assertRaisesRegex(ValueError,'disconnected'):review_flow.read_shapes(path)
            write(box(0,0,1,1),duplicate=True)
            with self.assertRaisesRegex(ValueError,'Duplicate'):review_flow.read_shapes(path)

    def test_flow_keeps_islands_and_holes_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'inputs';inputs.mkdir()
            (inputs/'groups.csv').write_text('component_id,country_id,name,tiles\na,X,Main,10\nb,X,Island,2\nc,X,Grouped,0\n')
            (inputs/'manifest.json').write_text('{}')
            geometry=[Polygon([(0,0),(3,0),(3,3),(0,3)],holes=[[(1,1),(2,1),(2,2),(1,2)]]),box(8,0,9,1),box(10,0,11,1)]
            source=root/'polygons.geojson'
            source.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in zip('abc',geometry)])))
            result=flow.run(inputs,source,root/'out')
            self.assertEqual((result['components'],result['tiles'],result['holes']),(2,12,1))
            features=json.loads((root/'out/geometry.geojson').read_text())['features']
            self.assertEqual([f['properties']['component_id'] for f in features],['a','b'])
            self.assertEqual(len(features[0]['geometry']['coordinates']),2)
            with self.assertRaisesRegex(ValueError,'already exists'):flow.run(inputs,source,root/'out')
            source.write_text(json.dumps(dict(type='FeatureCollection',features=[])))
            with self.assertRaisesRegex(ValueError,'Missing'):flow.run(inputs,source,root/'bad')
            self.assertFalse((root/'bad').exists())


if __name__=='__main__':unittest.main()
