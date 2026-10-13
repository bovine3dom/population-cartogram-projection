// SPDX-License-Identifier: GPL-3.0-or-later
// Optional rigid orientation of a square-grid initializer, before guide fitting.
package arrange.algorithms;

import arrange.model.MosaicCartogram;
import common.dual.Dual;
import common.gridmath.GridMath.Coordinate;
import java.util.ArrayList;
import java.util.List;
import nl.tue.geometrycore.geometry.Vector;

public final class GeographicOrientation {
    private static final int[][] MATRICES = {
        {1,0,0,1},{0,-1,1,0},{-1,0,0,-1},{0,1,-1,0},
        {-1,0,0,1},{1,0,0,-1},{0,1,1,0},{0,-1,-1,0}
    };

    public static MosaicCartogram orient(MosaicCartogram original, Dual dual) {
        List<double[]> points = new ArrayList<>();
        double mass=0, gx=0, gy=0, sx=0, sy=0;
        for (var region : original.regions()) {
            var part=region.getPartition();
            if (part.label.startsWith("SEA:")) continue;
            Vector grid=region.getAllocated().continuousBarycenter();
            Vector source=part.centroid();
            double weight=Math.sqrt(part.getWeight());
            points.add(new double[]{grid.getX(),grid.getY(),source.getX(),source.getY(),weight});
            mass+=weight; gx+=weight*grid.getX(); gy+=weight*grid.getY();
            sx+=weight*source.getX(); sy+=weight*source.getY();
        }
        if (!(mass>0)) throw new IllegalArgumentException("No population regions to orient");
        gx/=mass; gy/=mass; sx/=mass; sy/=mass;
        int best=0; double bestScore=Double.NEGATIVE_INFINITY;
        for (int i=0;i<MATRICES.length;i++) {
            int[] m=MATRICES[i]; double score=0;
            for (double[] p : points) {
                double x=p[0]-gx, y=p[1]-gy;
                score+=p[4]*((m[0]*x+m[1]*y)*(p[2]-sx)+(m[2]*x+m[3]*y)*(p[3]-sy));
            }
            if (score>bestScore) { best=i; bestScore=score; }
        }
        System.out.println("Initial geographic orientation="+best+", score="+bestScore);
        if (best==0) return original;
        int[] m=MATRICES[best];
        MosaicCartogram result=new MosaicCartogram(original.getGridMath(),dual);
        for (Coordinate c : original.getCoordinateArray()) {
            if (c.variant()!=0) throw new IllegalArgumentException("Orientation requires a square grid");
            Coordinate point=original.getGridMath().origin().plus(m[0]*c.x+m[1]*c.y,m[2]*c.x+m[3]*c.y);
            result.setVertex(point,original.getVertex(c));
        }
        assert result.numberOfCells()==original.numberOfCells();
        assert result.isConnectedAndCorrectAdjacencies();
        return result;
    }
}
