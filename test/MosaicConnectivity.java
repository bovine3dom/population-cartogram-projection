// SPDX-License-Identifier: GPL-3.0-or-later
// Check local move decisions against independent grid flood fills.
import common.gridmath.AdjacencyType;
import common.gridmath.GridMath;
import common.gridmath.grids.SquareGeometry;
import common.gridmath.util.CoordinateSet;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Random;
import java.util.Set;

public class MosaicConnectivity {
    private static final int[][] OFF = {{-1,0},{1,0},{0,-1},{0,1}};
    private record Point(int x, int y) {}
    private static Set<Point> flood(Set<Point> allowed, Point start) {
        Set<Point> seen = new HashSet<>();
        ArrayDeque<Point> queue = new ArrayDeque<>();
        seen.add(start); queue.add(start);
        while (!queue.isEmpty()) {
            Point p = queue.remove();
            for (int[] d : OFF) {
                Point q = new Point(p.x+d[0],p.y+d[1]);
                if (allowed.contains(q) && seen.add(q)) queue.add(q);
            }
        }
        return seen;
    }
    private static boolean simple(Set<Point> land) {
        if (land.isEmpty()) return false;
        if (flood(land,land.iterator().next()).size() != land.size()) return false;
        Set<Point> sea = new HashSet<>();
        for (int x=-4;x<=4;x++) for (int y=-4;y<=4;y++) {
            Point p = new Point(x,y);
            if (!land.contains(p)) sea.add(p);
        }
        return flood(sea,new Point(-4,-4)).size() == sea.size();
    }
    public static void main(String[] args) {
        GridMath grid = new GridMath(new SquareGeometry());
        Random random = new Random(42);
        int checked=0, accepted=0;
        for (int trial=0;trial<10000;trial++) {
            Set<Point> land = new HashSet<>();
            for (int x=-2;x<=2;x++) for (int y=-2;y<=2;y++) {
                if (random.nextDouble()<0.55) land.add(new Point(x,y));
            }
            if (!simple(land)) continue;
            CoordinateSet cells = new CoordinateSet(grid);
            for (Point p : land) cells.add(grid.origin().plus(p.x,p.y));
            for (int x=-2;x<=2;x++) for (int y=-2;y<=2;y++) {
                checked++;
                if (!cells.contiguousNeighborhood(grid.origin().plus(x,y),AdjacencyType.ROOKS)) continue;
                accepted++;
                Set<Point> changed = new HashSet<>(land);
                Point p = new Point(x,y);
                if (!changed.remove(p)) changed.add(p);
                if (!simple(changed)) throw new AssertionError("Accepted a disconnecting or hole-forming move: "+land+" toggle="+p);
            }
        }
        if (accepted < 1000) throw new AssertionError("Insufficient accepted moves");
        System.out.println("Checked "+checked+" moves; "+accepted+" accepted moves preserve connectivity and no holes.");
    }
}
