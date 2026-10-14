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
    private static void checkPlannedDestinations() throws Exception {
        GridMath math=new GridMath(new SquareGeometry());
        Dual dual=new Dual();
        var a=dual.addVertex(new Vector(0,0)); var b=dual.addVertex(new Vector(1,0)); var c=dual.addVertex(new Vector(2,0));
        dual.addEdge(a,b); dual.addEdge(b,c);
        MosaicCartogram grid=new MosaicCartogram(math,dual);
        var origin=math.origin(); var middle=origin.plus(1,0); var right=origin.plus(2,0);
        grid.setVertex(origin,a); grid.setVertex(origin.plus(-1,0),a);
        grid.setVertex(middle,b); grid.setVertex(origin.plus(0,1),b); grid.setVertex(origin.plus(1,1),b);
        grid.setVertex(right,c); grid.setVertex(origin.plus(2,1),c);
        FlowDigraph flow=new FlowDigraph() {
            @Override public int[] solve() { return new int[]{1,1}; }
        };
        var first=flow.addVertex(); var second=flow.addVertex(); var third=flow.addVertex();
        var bc=flow.addEdge(first,second); var ab=flow.addEdge(third,first);
        Polisher polisher=new Polisher(dual,grid);
        set(polisher,"flowDigraph",flow); set(polisher,"watchEdges",new ArrayList<>(List.of(bc,ab)));
        set(polisher,"vertexToCoordinate",new GridMath.Coordinate[]{middle,right,origin});
        var execute=Polisher.class.getDeclaredMethod("execute",boolean.class); execute.setAccessible(true);
        if (!(Boolean)execute.invoke(polisher,true) || grid.getVertex(origin)!=b || grid.getVertex(middle)!=c
                || !grid.isConnectedAndCorrectAdjacencies()) {
            throw new AssertionError("An earlier move changed the planned destination owner");
        }
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
        checkPlannedDestinations();
        // Empty guides make both regions surplus. Exact mode must still send
        // only one unit, not one unit from each region.
        for (var v : dual.getVertices()) {
            var part=new common.Partition(); part.label="test:"+v.getGraphIndex(); v.setPartition(part);
        }
        var supplyFlow=new FlowDigraph(); set(polisher,"flowDigraph",supplyFlow);
        var regionVertices=Polisher.class.getDeclaredMethod("getRegionVertices"); regionVertices.setAccessible(true);
        var initialize=Polisher.class.getDeclaredMethod("initializeRegionSupply",arrange.util.ElementList.class,boolean.class);
        initialize.setAccessible(true);
        int seaSupply=(Integer)initialize.invoke(polisher,regionVertices.invoke(polisher),true);
        int supply=0; for (var v : supplyFlow.vertices()) supply+=Math.abs(v.getSupply());
        if (supply!=1 || seaSupply!=-1) throw new AssertionError("Exact polishing supplied more than one unit");
        Class<?> region=Class.forName("arrange.model.MosaicCartogram$MosaicRegion");
        Field disabled=region.getDeclaredField("$assertionsDisabled"); disabled.setAccessible(true);
        boolean effective=!disabled.getBoolean(null);
        if (effective != MosaicCartogram.class.desiredAssertionStatus()) throw new AssertionError("Unexpected assertion status");
        System.out.println("Effective region assertions="+effective+"; nested class request="+region.desiredAssertionStatus());
    }
}
