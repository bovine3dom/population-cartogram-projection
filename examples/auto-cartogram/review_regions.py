#!/usr/bin/env python3
"""Draw regional details without changing the world layout."""
import argparse
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import numpy as np
from scipy.ndimage import distance_transform_edt

from review_layout import load, viewport
from save_review import digest


REGIONS={
    'north-america':('North America and the Caribbean',(-170,-50,5,85)),
    'south-america':('South America',(-85,-30,-60,15)),
    'europe':('Europe',(-15,45,35,72)),
    'africa':('Africa and nearby coasts',(-25,55,-38,38)),
    'south-asia':('South Asia',(60,105,5,40)),
    'japan-korea':('Japan and Korea',(125,150,30,46)),
    'indonesia':('Indonesia and nearby islands',(90,145,-12,10)),
}
NS='http://www.w3.org/2000/svg'
ET.register_namespace('',NS)


def label_point(points):
    x0=min(x for x,y in points)-1;y0=min(y for x,y in points)-1
    grid=np.zeros((max(y for x,y in points)-y0+2,max(x for x,y in points)-x0+2),dtype=bool)
    for x,y in points:grid[y-y0,x-x0]=True
    distance=distance_transform_edt(grid)
    cx=sum(x for x,y in points)/len(points);cy=sum(y for x,y in points)/len(points)
    return min(points,key=lambda p:(-distance[p[1]-y0,p[0]-x0],(p[0]-cx)**2+(p[1]-cy)**2,p))


def run(inputs,layout,output,render=True):
    if output.exists():raise ValueError('Output already exists')
    shapes,tiles,owners=load(inputs,layout);metrics=json.loads((layout/'metrics.json').read_text())
    source_header=int(ET.parse(layout/'review.svg').getroot().get('data-map-header','140'))
    xmin,xmax,ymin,ymax,scale,left,top,header=viewport(owners,metrics,source_header)
    output.mkdir(parents=True);regions=[]
    for name,(title,(west,east,south,north)) in REGIONS.items():
        selected=[c for c,r in shapes.items() if west<=(float(r['west'])+float(r['east']))/2<=east and south<=(float(r['south'])+float(r['north']))/2<=north]
        if not selected:continue
        cells=set().union(*(tiles[c] for c in selected));margin=6
        x0=max(40,left+(min(x for x,y in cells)-margin-xmin)*scale)
        x1=min(1760,left+(max(x for x,y in cells)+margin-xmin)*scale)
        y0=max(header,top+(ymax-max(y for x,y in cells)-margin)*scale)
        y1=min(1075,top+(ymax-min(y for x,y in cells)+margin)*scale)
        root=ET.Element(f'{{{NS}}}svg',dict(width='1800',height='1120',viewBox='0 0 1800 1120'))
        ET.SubElement(root,f'{{{NS}}}rect',dict(width='1800',height='1120',fill='#faf9f6'))
        def text(y,value,size=18):
            node=ET.SubElement(root,f'{{{NS}}}text',{'x':'40','y':str(y),'font-family':'sans-serif','font-size':str(size),'fill':'#242424'});node.text=value
        text(40,f'{title}: detail of the world layout',27)
        text(70,'Positions are unchanged. Country shapes can continue outside the frame.')
        text(96,f'World checks: {metrics["tiles"]:,} tiles; count error {metrics["absolute_tile_error"]:,}; {metrics["missing_contacts"]} missing and {metrics["false_contacts"]} false contacts. Not a production map.',15)
        if metrics['disconnected_regions'] or metrics['regions_with_holes']:
            text(118,f'Topology: {metrics["disconnected_regions"]} disconnected regions; {metrics["regions_with_holes"]} regions with holes, including occupied holes.',15)
        source=ET.parse(layout/'review.svg').getroot()
        zoom=min(1760/(x1-x0),940/(y1-y0))
        group=source.find(f'{{{NS}}}g')
        if group is not None:
            for node in list(group):
                if node.tag==f'{{{NS}}}text':group.remove(node)
                elif node.get('stroke'):node.set('vector-effect','non-scaling-stroke')
            biggest={}
            for c,points in tiles.items():
                visible={p for p in points if x0<=left+(p[0]-xmin)*scale<=x1 and y0<=top+(ymax-p[1])*scale<=y1}
                country=shapes[c]['country_id']
                if visible and (country not in biggest or len(visible)>len(biggest[country])):biggest[country]=visible
            boxes=[]
            for country,points in sorted(biggest.items(),key=lambda item:(-len(item[1]),item[0])):
                if len(points)*(scale*zoom)**2<300:continue
                x,y=label_point(points);px=left+(x-xmin)*scale;py=top+(ymax-y)*scale
                bounds=(px-19/zoom,py-10/zoom,px+19/zoom,py+6/zoom)
                if any(not(bounds[2]<b[0] or b[2]<bounds[0] or bounds[3]<b[1] or b[3]<bounds[1]) for b in boxes):continue
                boxes.append(bounds)
                node=ET.SubElement(group,f'{{{NS}}}text',{'x':str(px),'y':str(py),'text-anchor':'middle','font-size':str(14/zoom),'paint-order':'stroke','stroke':'#faf9f6','stroke-width':str(2/zoom)})
                node.text=country
        source.attrib.update(x='20',y='130',width='1760',height='940',viewBox=f'{x0} {y0} {x1-x0} {y1-y0}')
        root.append(source)
        text(1094,'Sources: Kontur population; Natural Earth. Region selection uses source component bounds, not country membership.',13)
        path=output/(name+'.svg');ET.ElementTree(root).write(path,encoding='unicode')
        if render:subprocess.run(['rsvg-convert',str(path),'-o',str(path.with_suffix('.png'))],check=True)
        regions.append(dict(name=name,source_bounds=[west,east,south,north],selected_components=len(selected),svg_view_box=[x0,y0,x1-x0,y1-y0]))
    report=dict(regions=regions,inputs={str(p):digest(p) for p in [inputs/'groups.csv',layout/'cells.csv',layout/'review.svg',layout/'metrics.json']},script_sha256=digest(Path(__file__)))
    (output/'regions.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','layout','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--svg-only',action='store_true')
    args=parser.parse_args();run(args.inputs,args.layout,args.output,not args.svg_only)
