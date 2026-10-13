// SPDX-License-Identifier: GPL-3.0-or-later
// This optional adapter links GPL GridMapPipeline and GeometryCore. It is not
// part of the Julia package. See generator.md for source and license details.
import arrange.DeformAlgorithm;
import arrange.MosaicConstants;
import arrange.util.Random;
import combine.CombineAlgorithm;
import combine.combinations.AgnosticCombination;
import common.Outline;
import common.Partition;
import common.SiteMap;
import common.dual.Dual;
import common.dual.Vertex;
import nl.tue.geometrycore.geometry.Vector;
import common.gridmath.GridGeometrySpawner;
import common.gridmath.GridMath.Coordinate;
import io.IO;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import partition.PartitionAlgorithm;

/** Headless weighted mosaics with an explicit failure exit and direct tile export. */
public class MosaicAdapter {
    public static void main(String[] args) throws Exception {
        if (args.length < 4 || args.length > 6 || !(args[3].equals("topology") || args[3].equals("exact"))) {
            throw new IllegalArgumentException("MosaicAdapter INPUT.wkt WEIGHTS.tsv NEW_OUTPUT_DIR topology|exact [agnostic|directional] [EMBEDDING_DIR]");
        }
        String placement = args.length >= 5 ? args[4] : "agnostic";
        if (!placement.equals("agnostic") && !placement.equals("directional")) {
            throw new IllegalArgumentException("Unknown placement: " + placement);
        }
        Locale.setDefault(Locale.ROOT);
        Path output = Path.of(args[2]);
        if (Files.exists(output)) throw new IllegalArgumentException("Output exists: " + output);
        Map<String, Integer> weights = new HashMap<>();
        for (String line : Files.readAllLines(Path.of(args[1]))) {
            String[] fields = line.split("\t", -1);
            if (fields.length != 2) throw new IllegalArgumentException("Expected label and integer weight");
            int weight = Integer.parseInt(fields[1]);
            if (weight < 1 || weights.put(fields[0], weight) != null) {
                throw new IllegalArgumentException("Nonpositive or duplicate weight: " + line);
            }
        }
        SiteMap map = IO.read(Path.of(args[0]).toFile());
        if (map == null || map.outlines.isEmpty()) throw new IllegalArgumentException("Empty input map");
        var labels = new HashSet<String>();
        for (Outline outline : map.outlines) {
            if (!labels.add(outline.label) || !weights.containsKey(outline.label)) {
                throw new IllegalArgumentException("Missing or duplicate outline: " + outline.label);
            }
            outline.customWeight = weights.get(outline.label);
        }
        if (!labels.equals(weights.keySet())) throw new IllegalArgumentException("Unused weight labels");
        Random.restart();
        MosaicConstants.configureMosaicCartograms();
        MosaicConstants.EXACT_TILES = args[3].equals("exact");
        MosaicConstants.FORCE_TOTAL_ITERATIONS = setting("mosaic.forceIterations", MosaicConstants.FORCE_TOTAL_ITERATIONS);
        MosaicConstants.MAX_NO_IMPROVE_SCALED = setting("mosaic.scaledPatience", MosaicConstants.MAX_NO_IMPROVE_SCALED);
        MosaicConstants.MAX_NO_IMPROVE_FINAL = setting("mosaic.finalPatience", MosaicConstants.MAX_NO_IMPROVE_FINAL);
        int maxRounds = setting("mosaic.maxRounds", Integer.MAX_VALUE);
        MosaicConstants.POLISHER_MAX_ITERATIONS = setting("mosaic.polishIterations", MosaicConstants.POLISHER_MAX_ITERATIONS, 0);
        PartitionAlgorithm.trivialPartition(map);
        if (args.length == 6) setEmbedding(map, Path.of(args[5]));
        new DeformAlgorithm(GridGeometrySpawner.inferFromString("SQUARE")).run(map);
        if (placement.equals("directional")) DirectionalPlacement.run(map);
        else new CombineAlgorithm(new AgnosticCombination()).run(map);

        // Do not use the upstream site exporter: a population mosaic has many
        // cells per outline, not one assigned cell per site.
        var coordinates = new HashSet<String>();
        StringBuilder cells = new StringBuilder("component_id,x,y\n");
        StringBuilder sea = new StringBuilder("component_id,x,y\n");
        StringBuilder counts = new StringBuilder("component_id,requested,actual\n");
        for (Partition part : map.partitions()) {
            int count = 0;
            if (part.cells == null) throw new IllegalStateException("Missing cells: " + part.label);
            for (Coordinate cell : part.cells) {
                String xy = cell.x + "," + cell.y;
                if (!coordinates.add(xy)) throw new IllegalStateException("Overlapping target: " + xy);
                (part.label.startsWith("SEA:") ? sea : cells).append(part.label).append(',').append(xy).append('\n');
                count++;
            }
            if (count == 0) throw new IllegalStateException("Empty region: " + part.label);
            counts.append(part.label).append(',').append(weights.get(part.label)).append(',').append(count).append('\n');
        }
        // Exceptions before this point leave no output directory. A completion
        // marker distinguishes successful writes from an interrupted publication.
        Files.createDirectories(output);
        Files.writeString(output.resolve("cells.csv"), cells);
        Files.writeString(output.resolve("sea.csv"), sea);
        Files.writeString(output.resolve("counts.csv"), counts);
        IO.write(output.resolve("layout.wkt").toFile(), map);
        Files.writeString(output.resolve("complete.txt"), "mode=" + args[3] + "\nseed=" + Random.getSeed() + "\nplacement=" + placement + "\nembedding=" + (args.length == 6 ? "planar" : "native") + "\n"
            + "forceIterations=" + MosaicConstants.FORCE_TOTAL_ITERATIONS + "\n"
            + "scaledPatience=" + MosaicConstants.MAX_NO_IMPROVE_SCALED + "\n"
            + "finalPatience=" + MosaicConstants.MAX_NO_IMPROVE_FINAL + "\n"
            + "maxRounds=" + maxRounds + "\n"
            + "polishIterations=" + MosaicConstants.POLISHER_MAX_ITERATIONS + "\n"
            + "regionAssertions=" + Class.forName("arrange.model.MosaicCartogram$MosaicRegion").desiredAssertionStatus() + "\n");
    }

    private static int setting(String name, int fallback) {
        return setting(name, fallback, 1);
    }

    private static int setting(String name, int fallback, int minimum) {
        int value = Integer.parseInt(System.getProperty(name, Integer.toString(fallback)));
        if (value < minimum) throw new IllegalArgumentException("Setting below minimum: " + name);
        return value;
    }

    private static void setEmbedding(SiteMap map, Path directory) throws Exception {
        Map<String, Vector> positions = new HashMap<>();
        for (String line : Files.readAllLines(directory.resolve("embedding.tsv"))) {
            String[] fields = line.split("\t");
            if (fields.length != 3) throw new IllegalArgumentException("Invalid embedding row");
            double x = Double.parseDouble(fields[1]), y = Double.parseDouble(fields[2]);
            if (!Double.isFinite(x) || !Double.isFinite(y) || positions.put(fields[0],new Vector(x,y)) != null) {
                throw new IllegalArgumentException("Invalid or duplicate embedding position");
            }
        }
        Dual dual = new Dual();
        Map<String, Vertex> vertices = new HashMap<>();
        for (Partition part : map.partitions()) {
            if (!positions.containsKey(part.label)) throw new IllegalArgumentException("Missing embedding vertex");
            // Only the dual's initial coordinates change. The polygon coordinates
            // and centroids used for guiding shapes and placement are unchanged.
            part.labelPoint = positions.get(part.label);
            vertices.put(part.label,dual.addVertex(part));
        }
        if (!vertices.keySet().equals(positions.keySet())) throw new IllegalArgumentException("Extra embedding vertices");
        for (String line : Files.readAllLines(directory.resolve("embedding-edges.tsv"))) {
            String[] fields = line.split("\t");
            if (fields.length != 2 || !vertices.containsKey(fields[0]) || !vertices.containsKey(fields[1]) || fields[0].equals(fields[1])) {
                throw new IllegalArgumentException("Invalid embedding edge");
            }
            dual.addEdge(vertices.get(fields[0]),vertices.get(fields[1]));
        }
        map.duals = dual.connectedComponents();
    }
}
