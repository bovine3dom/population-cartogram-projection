import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from move_interior_lake import move
from review_geography import exterior_water


class InteriorLakeTests(unittest.TestCase):
    def test_exchange_preserves_budget_and_exterior_water(self):
        waters = {'lake': {(1, 1)}}
        tiles = {'a': {(x, y) for x in range(5) for y in range(5)}-{(1, 1)}}
        result, lakes = move(tiles, waters, 'lake', (2, 2))
        self.assertEqual(lakes, {'lake': {(3, 3)}})
        self.assertEqual(len(result['a']), len(tiles['a']))
        self.assertIn((1, 1), result['a'])
        self.assertNotIn((3, 3), result['a'])
        self.assertEqual(exterior_water({p: 'a' for p in tiles['a']}),
                         exterior_water({p: 'a' for p in result['a']}))
        self.assertEqual(waters, {'lake': {(1, 1)}})
        self.assertNotIn((1, 1), tiles['a'])

    def test_multi_cell_shape_and_overlap_are_preserved(self):
        waters = {'lake': {(1, 1), (2, 1)}}
        tiles = {'a': {(x, y) for x in range(5) for y in range(4)}-waters['lake']}
        result, lakes = move(tiles, waters, 'lake', (1, 0))
        self.assertEqual(lakes['lake'], {(2, 1), (3, 1)})
        self.assertEqual(len(result['a']), len(tiles['a']))

    def test_destination_cannot_open_to_sea_or_another_lake(self):
        waters = {'lake': {(1, 1)}, 'other': {(3, 3)}}
        tiles = {'a': {(x, y) for x in range(5) for y in range(5)}-{(1, 1), (3, 3)}}
        for shift in [(-1, 0), (2, 2), (1, 2)]:
            with self.subTest(shift=shift), self.assertRaises(ValueError):
                move(tiles, waters, 'lake', shift)

    def test_shared_shore_cannot_move(self):
        tiles = {'a': {(0, 1), (1, 0), (1, 2)}, 'b': {(2, 1)}}
        with self.assertRaises(ValueError):
            move(tiles, {'lake': {(1, 1)}}, 'lake', (1, 0))

    def test_destination_cannot_disconnect_country(self):
        a = {(x, y) for x in range(5) for y in range(5)}-{(1, 1)}
        a |= {(5, 2), (6, 2), (7, 2), (6, 1), (6, 3)}
        with self.assertRaises(ValueError):
            move({'a': a}, {'lake': {(1, 1)}}, 'lake', (5, 1))

    def test_invalid_starting_water_is_rejected(self):
        for lakes in [{'lake': {(0, 0)}}, {'lake': {(1, 1)}, 'other': {(1, 1)}}]:
            with self.subTest(lakes=lakes), self.assertRaises(ValueError):
                move({'a': {(0, 0)}}, lakes, 'lake', (1, 0))


if __name__ == '__main__':
    unittest.main()
