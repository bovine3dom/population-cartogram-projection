// SPDX-License-Identifier: GPL-3.0-or-later
// Force a non-improving move to check polishing rollback and assertion status.
import arrange.algorithms.sub.Polisher;
import arrange.model.MosaicCartogram;
import common.dual.Dual;
import common.gridmath.GridMath;
import common.gridmath.grids.SquareGeometry;
import common.mcf.FlowDigraph;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import nl.tue.geometrycore.geometry.Vector;

public class MosaicPolishTransaction {
    private static void set(Object target, String name, Object value) throws Exception {
        Field field=target.getClass().getDeclaredField(name);
        field.setAccessible(true); field.set(target,value);
    }
    public static void main(String[] args) throws Exception {
        GridMath math=new GridMath(new SquareGeometry());
        Dual dual=new Dual();
        var a=dual.addVertex(new Vector(0,0));
        var b=dual.addVertex(new Vector(1,0));
        dual.addEdge(a,b);
        MosaicCartogram grid=new MosaicCartogram(math,dual);
        var source=math.origin(); var target=source.plus(1,0); var other=source.plus(0,1);
        grid.setVertex(source,a); grid.setVertex(other,a); grid.setVertex(target,b);
        int error=grid.totalTileError();
        FlowDigraph flow=new FlowDigraph() {
            @Override public int[] solve() { return new int[]{1}; }
        };
        var from=flow.addVertex(); var to=flow.addVertex();
        var edge=flow.addEdge(from,to);
        Polisher polisher=new Polisher(dual,grid);
        set(polisher,"flowDigraph",flow);
        set(polisher,"watchEdges",new ArrayList<>(List.of(edge)));
        set(polisher,"vertexToCoordinate",new GridMath.Coordinate[]{source,target});
        var execute=Polisher.class.getDeclaredMethod("execute",boolean.class);
        execute.setAccessible(true);
        if (!(Boolean)execute.invoke(polisher,false) || grid.getVertex(source) != b) {
            throw new AssertionError("The test flow must make a move before rollback is tested");
        }
        grid.setVertex(source,a);
        var guarded=Polisher.class.getDeclaredMethod("executeImproving",boolean.class);
        guarded.setAccessible(true);
        if ((Boolean)guarded.invoke(polisher,false)) throw new AssertionError("Non-improving pass accepted");
        if (grid.numberOfCells()!=3 || grid.getVertex(source)!=a || grid.getVertex(other)!=a || grid.getVertex(target)!=b
                || grid.totalTileError()!=error || !grid.isConnectedAndCorrectAdjacencies()) {
            throw new AssertionError("Polishing did not restore cells, counts, and contacts");
        }
        Class<?> region=Class.forName("arrange.model.MosaicCartogram$MosaicRegion");
        Field disabled=region.getDeclaredField("$assertionsDisabled"); disabled.setAccessible(true);
        boolean effective=!disabled.getBoolean(null);
        if (effective != MosaicCartogram.class.desiredAssertionStatus()) throw new AssertionError("Unexpected assertion status");
        System.out.println("Effective region assertions="+effective+"; nested class request="+region.desiredAssertionStatus());
    }
}
