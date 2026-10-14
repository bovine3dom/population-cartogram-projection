#!/usr/bin/env python3
"""Validate direct tile exports and draw headless SVG review images (stdlib only)."""
import argparse
import collections
import csv
import hashlib
import html
import json
import math
from pathlib import Path

NEIGHBOURS = ((-1, 0), (1, 0), (0, -1), (0, 1))


def read_csv(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def connectivity(cells):
    remaining = set(cells)
    pieces = 0
    while remaining:
        pieces += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for dx, dy in NEIGHBOURS:
                p = x + dx, y + dy
                if p in remaining:
                    remaining.remove(p)
                    stack.append(p)
    return pieces


def holes(cells):
    xmin, xmax = min(x for x,y in cells)-1, max(x for x,y in cells)+1
    ymin, ymax = min(y for x,y in cells)-1, max(y for x,y in cells)+1
    sea = {(x,y) for x in range(xmin,xmax+1) for y in range(ymin,ymax+1)} - cells
    return connectivity(sea)-1


def quality(cells):
    perimeter = sum((x + dx, y + dy) not in cells
                    for x, y in cells for dx, dy in NEIGHBOURS)
    return {"connected_parts": connectivity(cells), "holes": holes(cells), "perimeter": perimeter,
            "compactness": 4 * math.pi * len(cells) / perimeter**2}


def load(inputs, layout):
    if not (layout / "complete.txt").is_file():
        raise ValueError("Layout has no completion marker")
    groups = read_csv(inputs / "groups.csv")
    shapes = {r["component_id"]: r for r in groups if int(r["tiles"]) > 0}
    tiles = collections.defaultdict(set)
    owners = {}
    for row in read_csv(layout / "cells.csv"):
        owner = row["component_id"]
        if owner not in shapes:
            raise ValueError(f"Unknown component {owner}")
        point = int(row["x"]), int(row["y"])
        if point in owners:
            raise ValueError(f"Duplicate coordinate {point}")
        owners[point] = owner
        tiles[owner].add(point)
    if set(shapes) != set(tiles):
        raise ValueError("Missing component tiles")
    return shapes, tiles, owners


def axis_order(shapes, tiles, *, same_country=True, threshold=1):
    centres = {c:(sum(x for x,y in cells)/len(cells),sum(y for x,y in cells)/len(cells)) for c,cells in tiles.items()}
    errors, tested = [], 0
    labels = sorted(shapes)
    for i,a in enumerate(labels):
        for b in labels[i+1:]:
            ra,rb = shapes[a],shapes[b]
            if same_country and ra["country_id"] != rb["country_id"]:
                continue
            for axis,(lo,hi) in enumerate((("west","east"),("south","north"))):
                delta = (float(rb[lo])+float(rb[hi])-float(ra[lo])-float(ra[hi]))/2
                if abs(delta) < threshold or (axis == 0 and abs(delta) > 180):
                    continue  # Near ties and seam-spanning pairs have no stable sign.
                tested += 1
                if delta*(centres[b][axis]-centres[a][axis]) <= 0:
                    scope=ra["country_id"] if same_country else ra["country_id"]+"|"+rb["country_id"]
                    errors.append((scope,a,b,"east" if axis == 0 else "north"))
    return tested,errors


def country_color(country):
    digest = hashlib.sha256(country.encode()).digest()
    return f"hsl({int.from_bytes(digest[:2], 'big') % 360},48%,70%)"


def draw(path, shapes, tiles, owners, metrics, title):
    xmin = min(x for x, y in owners) - 1
    xmax = max(x for x, y in owners) + 1
    ymin = min(y for x, y in owners) - 1
    ymax = max(y for x, y in owners) + 1
    width, height = 1800, 1120
    scale = min((width - 80) / (xmax - xmin), (height - 185) / (ymax - ymin))
    left = (width - scale * (xmax - xmin)) / 2
    top = 140 + ((height - 185) - scale * (ymax - ymin)) / 2
    tx = lambda x: left + (x - xmin) * scale
    ty = lambda y: top + (ymax - y) * scale
    fmt = lambda n: f"{n:.3f}"
    unmatched=metrics.get("unmatched_source_population")
    unmatched_label=f"{unmatched:,.0f}" if unmatched is not None else "not assessed"
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             f'<rect width="{width}" height="{height}" fill="#faf9f6"/>',
             '<g font-family="sans-serif" fill="#242424">',
             f'<text x="40" y="40" font-size="27">{html.escape(title)}</text>',
             f'<text x="40" y="68" font-size="16">{metrics["tiles"]:,} square tiles | '
             f'{len(shapes)} shapes | {metrics["countries"]} Natural Earth country IDs | '
             f'{metrics["population_total"]/1e9:.3f} billion people in scope</text>',
             f'<text x="40" y="91" font-size="15">Grouped population: {metrics["grouped_population"]:,.0f}; '
             f'omitted from shapes: {metrics["omitted_population"]:,.0f}; '
             f'unmatched source: {unmatched_label}; '
             f'count error: {metrics["absolute_tile_error"]:,} tiles.</text>',
             f'<text x="40" y="114" font-size="15" fill="#973b28">EXPERIMENT: '
             f'{metrics["missing_contacts"]} missing and {metrics["false_contacts"]} false represented contacts; '
             f'{metrics["holes_not_encoded_in_wkt"]} input holes not encoded. Not a production map.</text>']
    # One path per component is smaller and faster than one SVG element per tile.
    for component in sorted(tiles):
        row = shapes[component]
        commands = []
        for x, y in sorted(tiles[component]):
            commands.append(f'M{fmt(tx(x-.5))},{fmt(ty(y+.5))}h{fmt(scale)}v{fmt(scale)}h-{fmt(scale)}z')
        tip = f'{row["name"]} ({component}): {len(tiles[component])} tiles; {float(row["group_population"]):,.0f} people'
        parts.append(f'<path d="{" ".join(commands)}" fill="{country_color(row["country_id"])}">'
                     f'<title>{html.escape(tip)}</title></path>')
    # Draw only exposed edges or country borders, not all interior tile edges.
    edges = []
    for (x, y), owner in sorted(owners.items()):
        for dx, dy in NEIGHBOURS:
            other = owners.get((x + dx, y + dy))
            if other == owner or (other and shapes[other]["country_id"] == shapes[owner]["country_id"]):
                continue
            if other and owner > other:
                continue
            if dx:
                ax, ay, bx, by = x + dx/2, y-.5, x + dx/2, y+.5
            else:
                ax, ay, bx, by = x-.5, y + dy/2, x+.5, y + dy/2
            edges.append(f'M{fmt(tx(ax))},{fmt(ty(ay))}L{fmt(tx(bx))},{fmt(ty(by))}')
    parts.append(f'<path d="{" ".join(edges)}" fill="none" stroke="#444" stroke-width="0.55"/>')
    # Label the largest piece of each sufficiently visible country. Suppress
    # overlapping text boxes rather than making small countries unreadable.
    biggest = {}
    for component, cells in tiles.items():
        country = shapes[component]["country_id"]
        if country not in biggest or len(cells) > len(tiles[biggest[country]]):
            biggest[country] = component
    boxes = []
    for component in sorted(biggest.values(), key=lambda c: (-len(tiles[c]), c)):
        cells = tiles[component]
        if len(cells) * scale**2 < 700:
            continue
        x = sum(x for x, y in cells) / len(cells)
        y = sum(y for x, y in cells) / len(cells)
        # Keep the label on land even when the region has a bent outline.
        x, y = min(cells, key=lambda p: ((p[0]-x)**2 + (p[1]-y)**2, p))
        label = shapes[component]["country_id"]
        px, py = tx(x), ty(y)
        box = (px-17, py-9, px+17, py+6)
        if any(not (box[2] < b[0] or b[2] < box[0] or box[3] < b[1] or b[3] < box[1]) for b in boxes):
            continue
        boxes.append(box)
        parts.append(f'<text x="{fmt(px)}" y="{fmt(py)}" text-anchor="middle" font-size="12" '
                     f'paint-order="stroke" stroke="#faf9f6" stroke-width="2" stroke-linejoin="round">{html.escape(label)}</text>')
    methods={"mode=geographic-baseline":"Separate geographic baseline",
             "mode=geographic-reposition":"Geographic placement of existing island shapes",
             "mode=geographic-border-repair":"Geographic baseline with border repair",
             "mode=relaxed-geographic":"Whole-shape geographic relaxation",
             "mode=compact-deformation":"Local shape deformation; borders are not required"}
    method = methods.get(metrics["generation"][0],"GridMapPipeline")
    parts.append('<text x="40" y="1094" font-size="13">Sources: Kontur population; Natural Earth map units. '
                 f'Layout: {method}. Population year is not declared by the input file.</text></g></svg>')
    path.write_text("\n".join(parts))


def run(inputs, layout, title):
    shapes, tiles, owners = load(inputs, layout)
    metadata = json.loads((inputs / "manifest.json").read_text())
    actual = set()
    for (x, y), owner in owners.items():
        for dx, dy in ((1, 0), (0, 1)):
            other = owners.get((x + dx, y + dy))
            if other and owner != other:
                actual.add(tuple(sorted((owner, other))))
    geographic = read_csv(inputs / "geographic-contacts.csv")
    required = {tuple(sorted((r["a"], r["b"]))) for r in geographic if r["both_represented"] == "true"}
    missing, false = required - actual, actual - required
    regions = []
    for component in sorted(shapes):
        row = shapes[component]
        regions.append({"component_id": component, "country_id": row["country_id"],
                        "requested": int(row["tiles"]), "actual": len(tiles[component]),
                        **quality(tiles[component])})
    metrics = {k: metadata[k] for k in ("tile_budget", "population_total", "represented_population",
               "grouped_population", "omitted_population", "holes_not_encoded_in_wkt", "policy")}
    metrics.update(review_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   tiles=len(owners), countries=len({r["country_id"] for r in shapes.values()}),
                   absolute_tile_error=sum(abs(r["requested"] - r["actual"]) for r in regions),
                   disconnected_regions=sum(r["connected_parts"] != 1 for r in regions),
                   regions_with_holes=sum(r["holes"] > 0 for r in regions),
                   unmatched_source_population=metadata.get("unmatched_source_population"),
                   required_contacts=len(required), missing_contacts=len(missing), false_contacts=len(false),
                   contacts_with_unrepresented_components=len(geographic)-len(required),
                   actual_contacts=len(actual),
                   generation=(layout / "complete.txt").read_text().splitlines(),
                   occupied_fraction=len(owners)/((max(x for x,y in owners)-min(x for x,y in owners)+1)*
                                                  (max(y for x,y in owners)-min(y for x,y in owners)+1)))
    country_rows, capacity_rows, anchors = [], [], {}
    for country in sorted({r["country_id"] for r in shapes.values()}):
        labels = [c for c,r in shapes.items() if r["country_id"] == country]
        population = sum(float(shapes[c]["group_population"]) for c in labels)
        actual_tiles = sum(len(tiles[c]) for c in labels)
        if population >= 10_000_000:
            anchor=max(labels,key=lambda c:(float(shapes[c]["group_population"]),c))
            anchors[anchor]=shapes[anchor]
        for c in labels:
            source_mass = float(shapes[c]["group_population"])
            capacity = population*len(tiles[c])/actual_tiles
            capacity_rows.append({"country_id":country,"component_id":c,"group_population":source_mass,
                                  "country_uniform_tile_capacity":capacity,"capacity_excess":capacity-source_mass})
        ideal_tiles = population/metadata["population_total"]*metadata["tile_budget"]
        country_rows.append({"country_id":country,"population":population,"actual_tiles":actual_tiles,
                             "ideal_tiles":ideal_tiles,"relative_area_error":actual_tiles/ideal_tiles-1})
    metrics["country_uniform_tile_cross_group_lower_bound"] = sum(abs(r["capacity_excess"]) for r in capacity_rows)/2
    with (layout / "group-capacities.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream,fieldnames=list(capacity_rows[0]))
        writer.writeheader(); writer.writerows(capacity_rows)
    metrics["country_absolute_area_error_tiles"] = sum(abs(r["actual_tiles"]-r["ideal_tiles"]) for r in country_rows)
    metrics["maximum_country_relative_area_error"] = max(abs(r["relative_area_error"]) for r in country_rows)
    with (layout / "country-counts.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream,fieldnames=list(country_rows[0]))
        writer.writeheader(); writer.writerows(country_rows)
    country_tested,country_errors=axis_order(anchors,{c:tiles[c] for c in anchors},same_country=False,threshold=5)
    metrics.update(country_axis_comparisons=country_tested,country_axis_order_errors=len(country_errors),
                   country_axis_population_threshold=10_000_000,country_axis_degree_threshold=5,
                   population_weighted_compactness=sum(float(shapes[r["component_id"]]["group_population"])*r["compactness"] for r in regions)/metadata["represented_population"])
    with (layout / "country-order-errors.csv").open("w",newline="") as stream:
        writer=csv.writer(stream); writer.writerow(["countries","a","b","axis"]); writer.writerows(country_errors)
    tested, order_errors = axis_order(shapes, tiles)
    metrics.update(island_axis_comparisons=tested, island_axis_order_errors=len(order_errors))
    with (layout / "island-order-errors.csv").open("w", newline="") as stream:
        writer = csv.writer(stream); writer.writerow(["country_id", "a", "b", "axis"])
        writer.writerows(order_errors)
    metrics["passes_represented_constraints"] = (metrics["absolute_tile_error"] == 0 and
        metrics["disconnected_regions"] == 0 and metrics["regions_with_holes"] == 0 and not missing and not false)
    (layout / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    with (layout / "region-quality.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(regions[0]))
        writer.writeheader(); writer.writerows(regions)
    with (layout / "contact-errors.csv").open("w", newline="") as stream:
        writer = csv.writer(stream); writer.writerow(["kind", "a", "b"])
        writer.writerows((kind, a, b) for kind, pairs in [("missing", missing), ("false", false)] for a,b in sorted(pairs))
    draw(layout / "review.svg", shapes, tiles, owners, metrics, title)
    print(json.dumps(metrics, indent=2))
    return metrics


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path)
    parser.add_argument("layout", type=Path)
    parser.add_argument("--title", default="Automatic population mosaic — review layout")
    args = parser.parse_args()
    run(args.inputs, args.layout, args.title)
