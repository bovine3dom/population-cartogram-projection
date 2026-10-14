// SPDX-License-Identifier: GPL-3.0-or-later
// Compare the optional upstream flow solver with exhaustive small-graph search.
import common.mcf.FlowDigraph;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Random;
import java.util.Set;

public class MosaicMinCostFlow {
    public static void main(String[] args) {
        Random random = new Random(314159);
        int infeasible=0;
        for (int trial=0;trial<2000;trial++) {
            FlowDigraph graph = new FlowDigraph();
            for (int v=0;v<4;v++) graph.addVertex();
            int[] from=new int[8],to=new int[8],supply=new int[4];
            int[] incoming=new int[4],outgoing=new int[4],capacity=new int[4];
            double[] weights=new double[8];
            Set<String> pairs=new HashSet<>();
            for (int e=0;e<8;e++) {
                int a,b;
                do { a=random.nextInt(4); b=random.nextInt(4); }
                while (a==b || !pairs.add(a+":"+b));
                from[e]=a; to[e]=b;
                weights[e]=(random.nextInt(21)-10)*(trial%2==0 ? 1.0 : 0.0001);
                var edge=graph.addEdge(a,b); edge.setCapacity(1); edge.setWeight(weights[e]);
                if (random.nextBoolean()) { supply[a]++; supply[b]--; outgoing[a]++; incoming[b]++; }
            }
            for (int v=0;v<4;v++) {
                graph.getVertex(v).setSupply(supply[v]);
                capacity[v]=Math.min(incoming[v],outgoing[v])+random.nextInt(2);
                graph.getVertex(v).setCapacity(capacity[v]);
            }
            if (trial>=1000) {
                int extra=random.nextInt(5); supply[0]+=extra; supply[3]-=extra;
                graph.getVertex(0).setSupply(supply[0]); graph.getVertex(3).setSupply(supply[3]);
            }
            double optimum=Double.POSITIVE_INFINITY;
            for (int mask=0;mask<256;mask++) {
                int[] balance=new int[4],inflow=new int[4],outflow=new int[4]; double cost=0;
                for (int e=0;e<8;e++) if ((mask & (1<<e)) != 0) {
                    balance[from[e]]++; balance[to[e]]--; outflow[from[e]]++; inflow[to[e]]++; cost+=weights[e];
                }
                boolean valid=Arrays.equals(balance,supply);
                for (int v=0;v<4;v++) valid &= Math.min(inflow[v],outflow[v]) <= capacity[v];
                if (valid) optimum=Math.min(optimum,cost);
            }
            if (trial%25==0) System.out.println("Flow trial "+trial);
            int[] flow=graph.solve();
            if (Double.isInfinite(optimum)) {
                if (flow!=null) throw new AssertionError("Infeasible graph accepted: "+trial);
                infeasible++; continue;
            }
            if (flow==null) throw new AssertionError("Feasible graph rejected: "+trial);
            int[] balance=new int[4],inflow=new int[4],outflow=new int[4]; double cost=0;
            for (int e=0;e<8;e++) {
                if (flow[e]<0 || flow[e]>1) throw new AssertionError("Capacity violation");
                balance[from[e]]+=flow[e]; balance[to[e]]-=flow[e]; cost+=weights[e]*flow[e];
                outflow[from[e]]+=flow[e]; inflow[to[e]]+=flow[e];
            }
            for (int v=0;v<4;v++) if (Math.min(inflow[v],outflow[v]) > capacity[v]) throw new AssertionError("Vertex capacity violation");
            if (!Arrays.equals(balance,supply) || Math.abs(cost-optimum)>1e-8) {
                throw new AssertionError("Nonoptimal flow at "+trial+": cost="+cost+", optimum="+optimum);
            }
        }
        FlowDigraph impossible=new FlowDigraph();
        var source=impossible.addVertex(); var sink=impossible.addVertex();
        source.setSupply(1); sink.setSupply(-1);
        if (impossible.solve()!=null) throw new AssertionError("Artificial edges hid infeasibility");
        FlowDigraph costly=new FlowDigraph();
        source=costly.addVertex(); sink=costly.addVertex();
        source.setSupply(1); sink.setSupply(-1);
        var edge=costly.addEdge(source,sink); edge.setWeight(300000); edge.setCapacity(1);
        int[] expensive=costly.solve();
        if (expensive==null || expensive[edge.getId()]!=1) throw new AssertionError("Artificial route replaced a valid expensive edge");
        if (new FlowDigraph().solve()==null) throw new AssertionError("Empty flow problem is feasible");
        System.out.println("2000 flow problems agree with exhaustive search, including "+infeasible+" infeasible cases; high-cost and empty cases pass.");
    }
}
