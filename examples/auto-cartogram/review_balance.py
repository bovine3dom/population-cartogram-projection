#!/usr/bin/env python3
"""Compare target errors before and after sparse transport balance correction."""
import argparse
import collections
import json
import math
from pathlib import Path

from check_transport import rows
from check_transport_shift import compare
from save_review import digest


def color(error, limit):
    fraction=min(abs(error)/limit,1)
    end=(39,106,165) if error < 0 else (200,55,45)
    return "#"+"".join(f"{round(250+(v-250)*fraction):02x}" for v in end)


def run(raw, corrected, output, limit=.075, allow_appended=False, allow_coarse=False):
    if output.exists(): raise ValueError("Output already exists")
    if not math.isfinite(limit) or limit <= 0: raise ValueError("Colour limit must be positive and finite")
    comparison=compare(raw,corrected,allow_appended)
    checks=[]; quality=[]; resolutions=[]
    for directory in [raw,corrected]:
        resolutions.append(json.loads((directory/"manifest.json").read_text())["coarse_h3_resolution"])
        checks.append(json.loads((directory/"independent-checks.json").read_text()))
        quality.append({(float(r["x"]),float(r["y"])):r for r in rows(directory/"target-quality.csv")})
    resolution=resolutions[0]
    if resolutions[1] != resolution or not 0 <= resolution <= 8 or (resolution != 8 and not allow_coarse):
        raise ValueError("This figure requires equal native H3-8 inputs unless coarse review is enabled")
    pairs=comparison["mapping_pairs"]; added=comparison["appended_pairs"]
    label="Native H3-8" if resolution == 8 else f"Coarse H3-{resolution} (not native-cell validation)"
    support=f"{pairs-added:,} original ordered pairs retained; {added:,} one-step pairs added." if added else f"All {pairs:,} ordered nonzero pairs are unchanged."
    if quality[0].keys() != quality[1].keys(): raise ValueError("Target positions differ")
    for p,r in quality[0].items():
        other=quality[1][p]
        if r["group_id"] != other["group_id"] or float(r["expected_population"]) != float(other["expected_population"]):
            raise ValueError("Target capacities differ")
    xmin,xmax=min(x for x,y in quality[0]),max(x for x,y in quality[0])
    ymin,ymax=min(y for x,y in quality[0]),max(y for x,y in quality[0])
    scale=min(820/(xmax-xmin+2),700/(ymax-ymin+2))
    legend_y=math.ceil(200+(ymax-ymin+1)*scale)
    height=legend_y+100
    parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="{height}">',
        f'<rect width="1800" height="{height}" fill="#faf9f6"/><g font-family="sans-serif" fill="#242424">',
        f'<text x="35" y="38" font-size="26">{label}: target balance before and after correction</text>',
        f'<text x="35" y="70" font-size="17">Same source and target tables. {support}</text>']
    for offset,table,check,title in zip([35,935],quality,checks,["Raw CPU export","Sparse balance correction"]):
        parts.extend([f'<text x="{offset}" y="115" font-size="23">{title}</text>',
            f'<text x="{offset}" y="143" font-size="16">Maximum target error: {check["maximum_relative_target_error"]:.4%}; retained: {check["retained_share"]:.6%}.</text>'])
        paths=collections.defaultdict(list)
        for (x,y),r in sorted(table.items()):
            px=offset+20+(x-xmin)*scale; py=175+(ymax-y)*scale
            paths[color(float(r["relative_error"]),limit)].append(f'M{px:.3f},{py:.3f}h{scale:.3f}v{scale:.3f}h-{scale:.3f}z')
        for fill,path in paths.items(): parts.append(f'<path d="{" ".join(path)}" fill="{fill}"/>')
        boundary=[]
        for (x,y),r in sorted(table.items()):
            px=offset+20+(x-xmin)*scale; py=175+(ymax-y)*scale
            for dx,dy,ax,ay,bx,by in [(0,1,0,0,1,0),(1,0,1,0,1,1),(0,-1,0,1,1,1),(-1,0,0,0,0,1)]:
                if table.get((x+dx,y+dy),{}).get("group_id") != r["group_id"]:
                    boundary.append(f'M{px+ax*scale:.3f},{py+ay*scale:.3f}L{px+bx*scale:.3f},{py+by*scale:.3f}')
        parts.append(f'<path d="{" ".join(boundary)}" fill="none" stroke="#888" stroke-width=".7"/>')
    for i in range(101):
        parts.append(f'<rect x="{35+i*5}" y="{legend_y}" width="5.1" height="20" fill="{color(limit*(i/50-1),limit)}"/>')
    parts.extend([f'<text x="35" y="{legend_y+47}" font-size="17">Blue: {-limit:.1%}; white: zero; red: +{limit:.1%}. Both panels use the same scale. Colours stop at these limits.</text>',
        f'<text x="35" y="{legend_y+78}" font-size="15">Capacity varies by declared group. Groups can contain multiple islands. White does not mean mathematically exact balance.</text></g></svg>'])
    output.mkdir(parents=True)
    (output/"review.svg").write_text("\n".join(parts))
    (output/"checks.json").write_text(json.dumps(dict(ordered_support_unchanged=added == 0,mapping_pairs=pairs,
        appended_pairs=added,source_resolution=resolution,position_change=comparison["summary"],
        colour_limit=limit,inputs={str(d):c for d,c in zip([raw,corrected],checks)},script_sha256=digest(Path(__file__))),indent=2)+"\n")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ["raw","corrected","output"]: parser.add_argument(name,type=Path)
    parser.add_argument("--limit",type=float,default=.075)
    parser.add_argument("--allow-appended",action="store_true")
    parser.add_argument("--allow-coarse",action="store_true")
    args=parser.parse_args(); run(args.raw,args.corrected,args.output,args.limit,args.allow_appended,args.allow_coarse)
