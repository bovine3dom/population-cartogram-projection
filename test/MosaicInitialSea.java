// SPDX-License-Identifier: GPL-3.0-or-later
import arrange.algorithms.InitialSeaRemoval;
import arrange.model.MosaicCartogram;
import common.Partition;
import common.dual.Dual;
import common.gridmath.GridMath;
import common.gridmath.grids.SquareGeometry;
import nl.tue.geometrycore.geometry.Vector;

public class MosaicInitialSea {
    private static Partition part(String label, int weight) {
        Partition p=new Partition();
        p.label=label; p.customWeight=weight; p.labelPoint=new Vector(0,0);
        return p;
    }
    public static void main(String[] args) {
        Dual dual=new Dual();
        var a=dual.addVertex(part("a",1)); var b=dual.addVertex(part("b",1));
        var c=dual.addVertex(part("c",1)); var sea=dual.addVertex(part("SEA:test",1));
        dual.addEdge(a,b); dual.addEdge(b,c); dual.addEdge(c,sea); dual.addEdge(sea,a);
        var math=new GridMath(new SquareGeometry()); var origin=math.origin();
        MosaicCartogram cells=new MosaicCartogram(math,dual);
        cells.setVertex(origin,a); cells.setVertex(origin.plus(1,0),b);
        cells.setVertex(origin.plus(1,1),c); cells.setVertex(origin.plus(0,1),sea);
        var result=InitialSeaRemoval.remove(dual,cells);
        if (result.dual().vertexCount()!=3 || result.dual().getTotalWeight()!=3
                || result.cartogram().numberOfCells()!=3 || !result.cartogram().isConnectedAndCorrectAdjacencies()
                || result.cartogram().getVertex(origin.plus(0,1))!=null) throw new AssertionError("Land changed");
        for (var point : result.cartogram().getCoordinateArray()) {
            if (result.cartogram().getVertex(point).getPartition()!=cells.getVertex(point).getPartition()) {
                throw new AssertionError("Land owner changed");
            }
        }
        if (InitialSeaRemoval.remove(result.dual(),result.cartogram()).cartogram()!=result.cartogram()) {
            throw new AssertionError("Unnecessary copy without sea regions");
        }
        if (dual.vertexCount()!=4 || cells.numberOfCells()!=4) throw new AssertionError("Input changed");
        System.out.println("Initial sea removal preserves all land cells and contacts");
    }
}
