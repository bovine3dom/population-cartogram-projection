// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental composition of disconnected mosaics. This is not the published
// GridMapPipeline placement method; it changes placement, never tile ownership.
import common.Partition;
import common.SiteMap;
import common.dual.Dual;
import common.gridmath.GridMath.Coordinate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import nl.tue.geometrycore.geometry.Vector;

public final class DirectionalPlacement {
    private static long key(int x, int y) {
        return ((long)x << 32) | (y & 0xffffffffL);
    }

    private static List<Coordinate> cells(Dual dual) {
        List<Coordinate> result = new ArrayList<>();
        for (Partition part : dual.primalPartitions()) for (Coordinate c : part.cells) result.add(c);
        return result;
    }

    private static boolean free(List<Coordinate> cells, Set<Long> blocked, int dx, int dy) {
        for (Coordinate c : cells) if (blocked.contains(key(c.x + dx, c.y + dy))) return false;
        return true;
    }

    private static void occupy(List<Coordinate> cells, Set<Long> blocked) {
        for (Coordinate c : cells) {
            blocked.add(key(c.x, c.y));
            blocked.add(key(c.x-1, c.y)); blocked.add(key(c.x+1, c.y));
            blocked.add(key(c.x, c.y-1)); blocked.add(key(c.x, c.y+1));
        }
    }

    public static void run(SiteMap map) {
        List<Dual> pending = new ArrayList<>(map.duals);
        pending.sort(Comparator.comparingInt(Dual::getTotalWeight).reversed());
        List<Dual> placed = new ArrayList<>();
        Set<Long> blocked = new HashSet<>();
        for (Dual current : pending) {
            if (!placed.isEmpty()) {
                // Anchor at the geographically closest pair of region centroids.
                Partition from = null, to = null;
                double best = Double.POSITIVE_INFINITY;
                for (Dual previous : placed) for (Partition a : previous.primalPartitions()) {
                    for (Partition b : current.primalPartitions()) {
                        if (a.label.startsWith("SEA:") || b.label.startsWith("SEA:")) continue;
                        double distance = a.centroid().squaredDistanceTo(b.centroid());
                        if (distance < best) { best = distance; from = a; to = b; }
                    }
                }
                Vector direction = Vector.subtract(to.centroid(), from.centroid());
                double ux = direction.getX(), uy = direction.getY();
                double norm = Math.hypot(ux, uy);
                if (norm == 0) throw new IllegalStateException("Coincident component anchors");
                ux /= norm; uy /= norm;
                Coordinate base = from.cells.barycenter().minus(to.cells.barycenter());
                List<Coordinate> incoming = cells(current);
                Coordinate offset = null;
                for (int radius = 1; radius <= 10000 && offset == null; radius++) {
                    List<int[]> candidates = new ArrayList<>();
                    for (int x = -radius; x <= radius; x++) {
                        for (int y : new int[]{-radius, radius}) candidates.add(new int[]{x,y});
                    }
                    for (int y = -radius+1; y < radius; y++) {
                        for (int x : new int[]{-radius, radius}) candidates.add(new int[]{x,y});
                    }
                    final double vx = ux, vy = uy;
                    candidates.sort(Comparator.<int[]>comparingDouble(p -> -(p[0]*vx+p[1]*vy)/Math.hypot(p[0],p[1]))
                        .thenComparingInt(p -> p[0]*p[0]+p[1]*p[1]).thenComparingInt(p -> p[0]).thenComparingInt(p -> p[1]));
                    for (int[] p : candidates) {
                        // A 35-degree cone plus cardinal-order constraints is
                        // stricter than the upstream half-plane restriction.
                        double dot = p[0]*ux + p[1]*uy;
                        if (dot < Math.cos(Math.toRadians(35))*Math.hypot(p[0],p[1])) continue;
                        if (p[0]*ux < -1e-9 || p[1]*uy < -1e-9) continue;
                        int dx = base.x+p[0], dy = base.y+p[1];
                        if (free(incoming, blocked, dx, dy)) { offset = base.plus(p[0],p[1]); break; }
                    }
                }
                if (offset == null) throw new IllegalStateException("No collision-free directional placement");
                for (Partition p : current.primalPartitions()) {
                    p.cells.translate(offset);
                    if (p.guide != null) p.guide.translate(offset);
                }
            }
            occupy(cells(current), blocked);
            placed.add(current);
        }
    }
}
