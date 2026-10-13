#!/usr/bin/env python3
"""Draw declared target groups beside dominant source groups in a transport run."""
import argparse
import collections
import csv
import html
import json
from pathlib import Path

from review_layout import read_csv

LABELS = {
    "fecb2bac3d81ef76": ("Java group", "#db6e50"),
    "829c07ff03d97c10": ("Sumatra group", "#4c9fbd"),
    "51a10640dee7162b": ("Kalimantan group", "#79ab68"),
    "7c3797a36dd1a69b": ("Sulawesi group", "#ba89bf"),
    "91fa24efd9a13b2f": ("Papua group", "#e2bb4e"),
}


def color(group):
    return LABELS.get(group.split(":")[-1],("Other groups","#b5b5b5"))[1]


def run(directory, output):
    if output.exists():
        raise ValueError("Output already exists")
    metadata=json.loads((directory/"manifest.json").read_text())
    sources={r["id"]:r for r in read_csv(directory/"sources.csv")}
    targets={(float(r["x"]),float(r["y"])):r["group_id"] for r in read_csv(directory/"targets.csv")}
    contributions=collections.defaultdict(lambda:collections.defaultdict(float))
    flows=collections.defaultdict(float)
    for r in read_csv(directory/"mapping.csv"):
        p=float(r["x"]),float(r["y"])
        source=sources[r["id"]]
        mass=float(source["value"])*float(r["weight"])
        contributions[p][source["group_id"]]+=mass
        flows[source["group_id"],targets[p]]+=mass
    if set(contributions) != set(targets):
        raise ValueError("Transport has missing or unknown targets")
    dominant={p:max(sorted(masses),key=masses.get) for p,masses in contributions.items()}
    xmin,xmax=min(x for x,y in targets),max(x for x,y in targets)
    ymin,ymax=min(y for x,y in targets),max(y for x,y in targets)
    scale=min(820/(xmax-xmin+2),720/(ymax-ymin+2))
    parts=['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1000">',
           '<rect width="1800" height="1000" fill="#faf9f6"/><g font-family="sans-serif" fill="#242424">',
           f'<text x="35" y="38" font-size="25">Indonesia transport: H3-{metadata["coarse_h3_resolution"]}, '
           f'{metadata["coarse_sources"]:,} source rows, {metadata["targets"]:,} tiles</text>',
           f'<text x="35" y="65" font-size="17">Cross-group population: {metadata["cross_group_population"]:,.0f}; '
           f'retained: {metadata["retained_share"]:.3%}; pooled solve: {str(metadata["pooled"]).lower()}.</text>',
           '<text x="35" y="90" font-size="15">Diagnostic only. Grey combines many groups. Colour shows the largest source contribution, not all contributions.</text>']
    for offset,owners,title in [(35,targets,"Declared target groups"),(935,dominant,"Dominant source group after transport")]:
        parts.append(f'<text x="{offset}" y="132" font-size="22">{title}</text>')
        by_group=collections.defaultdict(list)
        for (x,y),group in sorted(owners.items()):
            px=offset+20+(x-xmin)*scale
            py=160+(ymax-y)*scale
            by_group[group].append(f'M{px:.3f},{py:.3f}h{scale:.3f}v{scale:.3f}h-{scale:.3f}z')
        for group,paths in sorted(by_group.items()):
            parts.append(f'<path d="{" ".join(paths)}" fill="{color(group)}"><title>{html.escape(group)}</title></path>')
    for i,(label,fill) in enumerate([*LABELS.values(),("Other groups","#b5b5b5")]):
        x=35+i*280
        parts.append(f'<rect x="{x}" y="924" width="18" height="18" fill="{fill}"/>'
                     f'<text x="{x+25}" y="939" font-size="16">{label}</text>')
    parts.append('<text x="35" y="978" font-size="14">The layout is automatic. Coarse runs are not native-cell validation. Grouping permits movement within each declared group.</text></g></svg>')
    output.mkdir(parents=True)
    (output/"review.svg").write_text("\n".join(parts))
    with (output/"flows.csv").open("w") as stream:
        writer=csv.writer(stream); writer.writerow(["source_group","target_group","population"])
        writer.writerows((a,b,v) for (a,b),v in sorted(flows.items()))
    (output/"manifest.json").write_text(json.dumps(metadata,indent=2)+"\n")
    return flows


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory",type=Path)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    run(args.directory,args.output)
