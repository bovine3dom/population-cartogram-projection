// SPDX-License-Identifier: GPL-3.0-or-later
// Remove temporary embedding regions before population fitting.
package arrange.algorithms;

import arrange.model.MosaicCartogram;
import common.dual.Dual;
import common.dual.Vertex;
import java.util.HashMap;

public final class InitialSeaRemoval {
    public record Result(Dual dual, MosaicCartogram cartogram) {}

    public static Result remove(Dual original, MosaicCartogram cells) {
        Dual land=new Dual();
        var vertices=new HashMap<Vertex,Vertex>();
        for (Vertex v : original.getVertices()) {
            if (!v.getPartition().label.startsWith("SEA:")) vertices.put(v,land.addVertex(v.getPartition()));
        }
        if (vertices.size()==original.vertexCount()) return new Result(original,cells);
        if (vertices.isEmpty()) throw new IllegalArgumentException("No land in the initial dual");
        for (Vertex v : original.getVertices()) if (vertices.containsKey(v)) {
            for (Vertex n : v.getNeighbors()) if (vertices.containsKey(n)) land.addEdge(vertices.get(v),vertices.get(n));
        }
        // This also computes the total population weight used during placement.
        var components=land.connectedComponents();
        if (components.size()!=1) throw new IllegalArgumentException("Sea removal splits the land dual");
        land=components.getFirst();
        var byPartition=new HashMap<common.Partition,Vertex>();
        for (Vertex v : land.getVertices()) byPartition.put(v.getPartition(),v);
        MosaicCartogram result=new MosaicCartogram(cells.getGridMath(),land);
        for (var c : cells.getCoordinateArray()) {
            Vertex v=byPartition.get(cells.getVertex(c).getPartition());
            if (v!=null) result.setVertex(c,v);
        }
        if (!result.isConnectedAndCorrectAdjacencies()) throw new IllegalStateException("Sea removal changed land topology");
        System.out.println("Removed initial sea regions="+(original.vertexCount()-land.vertexCount()));
        return new Result(land,result);
    }
}
