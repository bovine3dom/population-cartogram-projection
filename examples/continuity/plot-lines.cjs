const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const mon=process.env.H3_MON_ROOT||path.join(os.homedir(),'projects/H3-MON');
const {tableFromIPC}=require(path.join(mon,'node_modules/apache-arrow'));
const h3=require(path.join(mon,'node_modules/h3-js'));
const dir=process.argv[2];if(!dir)throw Error('usage: plot-lines.cjs EXPORTED_TRIAL_DIRECTORY');
const names={24:'Angola',180:'DRC',894:'Zambia',466:'Mali',854:'Burkina Faso',276:'Germany',616:'Poland'};
const boundaries=JSON.parse(fs.readFileSync('make-lookup-table/population-data/country-boundaries/ne_10m_admin_0_map_units.geojson'));
const radians=Math.PI/180;
const position=new Map(),population=new Map();
function load(name){
 const centres=fs.readFileSync(path.join(dir,name+'-centres.csv'),'utf8').trim().split('\n').slice(1).map(line=>{
  const [x,y,code,lon,lat]=line.split(',').map(Number);return {x,y,code,lon,lat};
 });
 const lookup=new Map(centres.map((c,i)=>[`${c.x},${c.y}`,i])),rows=[],byCell=centres.map(()=>[]);
 const table=tableFromIPC(fs.readFileSync(path.join(dir,name+'_hilo.arrow')));
 for(const r of table){const index=r.id.toString(16),cell=lookup.get(`${r.x},${r.y}`);if(cell===undefined)throw Error('unknown target');
  if(!position.has(index)){const [lat,lon]=h3.cellToLatLng(index);position.set(index,[lon,lat]);population.set(index,r.population);}
  byCell[cell].push(rows.length);rows.push({index,weight:r.weight});
 }
 return {centres,lookup,rows,byCell};
}
const data={baseline:load('baseline'),candidate:load('candidate')};
function distance(a,b){const dlat=(b.lat-a.lat)*radians,dlon=(b.lon-a.lon)*radians;
 const v=Math.sin(dlat/2)**2+Math.cos(a.lat*radians)*Math.cos(b.lat*radians)*Math.sin(dlon/2)**2;
 return 12742*Math.asin(Math.sqrt(Math.min(1,v)));}
const pairs=new Map();
for(const a of data.baseline.centres)for(const [x,y] of [[a.x+2,a.y],[a.x,a.y+2]]){
 const i=data.baseline.lookup.get(`${x},${y}`);if(i===undefined)continue;
 const b=data.baseline.centres[i];if(a.code===b.code)continue;
 const pair=[a.code,b.code].sort((a,b)=>a-b).join('-');
 if(!pairs.has(pair))pairs.set(pair,[]);pairs.get(pair).push({a,b,distance:distance(a,b)});
}
function components(projected,threshold){const ids=new Set(projected.filter(p=>p.weight>=threshold).map(p=>p.index)),sizes=[];
 while(ids.size){const queue=[ids.values().next().value];ids.delete(queue[0]);let size=0;
  while(queue.length){const id=queue.pop();size++;for(const n of h3.gridDisk(id,1))if(ids.delete(n))queue.push(n);}sizes.push(size);
 }return sizes.sort((a,b)=>b-a);
}
function panel(features,trace,bounds){
 const [xmin,xmax,ymin,ymax]=bounds,W=500,H=300,cos=Math.cos((ymin+ymax)/2*radians);
 const scale=Math.min(460/((xmax-xmin)*cos),260/(ymax-ymin));
 const X=x=>W/2+(x-(xmin+xmax)/2)*cos*scale,Y=y=>H/2-(y-(ymin+ymax)/2)*scale;
 let svg='<svg width="500" height="300" viewBox="0 0 500 300" style="overflow:hidden;background:#fafafa">';
 for(const f of boundaries.features){const g=f.geometry,polys=g.type==='Polygon'?[g.coordinates]:g.coordinates;
  for(const poly of polys)for(const ring of poly){const xs=ring.map(p=>p[0]),ys=ring.map(p=>p[1]);
   if(Math.max(...xs)<xmin||Math.min(...xs)>xmax||Math.max(...ys)<ymin||Math.min(...ys)>ymax)continue;
   svg+=`<path d="${ring.map((p,i)=>`${i&&Math.abs(p[0]-ring[i-1][0])<180?'L':'M'}${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join('')}" fill="none" stroke="#aaa" stroke-width=".6"/>`;
  }
 }
 for(const f of features){const p=position.get(f.index);svg+=`<circle cx="${X(p[0])}" cy="${Y(p[1])}" r="2" fill="#0080ff" opacity="${Math.min(1,f.weight)}"/>`;}
 let last=null;for(const c of trace){if(c&&last)svg+=`<path d="M${X(last.lon)},${Y(last.lat)}L${X(c.lon)},${Y(c.lat)}" stroke="#c33" stroke-width="1" fill="none"/>`;if(c)svg+=`<circle cx="${X(c.lon)}" cy="${Y(c.lat)}" r="2" fill="#c33"/>`;last=c;}
 return svg+'</svg>';
}
(async()=>{
 const {strokeCoverage,projectStroke}=await import(path.join(mon,'src/cartogram-line.js'));
 const results=[];
 let html='<html><body style="font:15px sans-serif;background:white"><h1>Before and after: the same straight cartogram lines</h1><p>Blue: H3 population footprints, with source-normalized line scores. Red: target means in line order, not mapped paths. Both panels use the same geographic extent.</p>';
 for(const [pair,edges] of pairs)for(const quantile of [.5,.9]){
  edges.sort((a,b)=>a.distance-b.distance);const edge=edges[Math.min(edges.length-1,Math.floor(edges.length*quantile))];
  const horizontal=edge.a.y===edge.b.y;
  const start=[edge.a.x-(horizontal?10:0),edge.a.y-(horizontal?0:10)];
  const end=[edge.a.x+(horizontal?12:0),edge.a.y+(horizontal?0:12)];
  const result={pair,quantile,start,end,baseline_seam_km:edge.distance,stages:{}};
  for(const [name,d] of Object.entries(data)){
   const coverage=strokeCoverage(d.centres.map(c=>c.x),d.centres.map(c=>c.y),start,end,2);
   const projected=projectStroke(coverage,d.byCell,r=>d.rows[r].weight,r=>d.rows[r].index);
   if(projected.some(p=>p.weight>1+1e-8))throw Error('line score exceeds one');
   const trace=[];for(let k=-5;k<=6;k++){const x=edge.a.x+(horizontal?2*k:0),y=edge.a.y+(horizontal?0:2*k);const i=d.lookup.get(`${x},${y}`);trace.push(i===undefined?null:d.centres[i]);}
   result.stages[name]={projected,trace,population:projected.reduce((s,p)=>s+p.weight*population.get(p.index),0),components01:components(projected,.1)};
   fs.writeFileSync(path.join(dir,`line-${pair}-${quantile}-${name}.geojson`),JSON.stringify({type:'FeatureCollection',features:projected.map(p=>({type:'Feature',geometry:{type:'Point',coordinates:position.get(p.index)},properties:{h3:p.index,score:p.weight}}))}));
  }
  const points=Object.values(result.stages).flatMap(s=>s.projected.filter(p=>p.weight>=.01).map(p=>position.get(p.index)));
  const bounds=[Math.min(...points.map(p=>p[0]))-.2,Math.max(...points.map(p=>p[0]))+.2,Math.min(...points.map(p=>p[1]))-.2,Math.max(...points.map(p=>p[1]))+.2];
  html+=`<h2>${pair.split('-').map(c=>names[c]||c).join(' / ')}: baseline seam quantile ${quantile}</h2><p>Cartogram ${start} to ${end}. Selected baseline seam: ${Math.round(edge.distance)} km.</p><div style="display:flex">`;
  for(const [name,s] of Object.entries(result.stages))html+=`<div><h3>${name}</h3>${panel(s.projected,s.trace,bounds)}<p>Footprint components at score ≥0.1: ${s.components01.length}. Transported population: ${Math.round(s.population)}.</p></div>`;
  html+='</div>';
  for(const s of Object.values(result.stages))delete s.projected;
  results.push(result);
 }
 fs.writeFileSync(path.join(dir,'lines.html'),html+'</body></html>');
 fs.writeFileSync(path.join(dir,'lines.json'),JSON.stringify(results,null,2));
 const {chromium}=require(path.join(mon,'node_modules/playwright'));
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{const page=await browser.newPage({viewport:{width:1040,height:900}});await page.goto('file://'+path.resolve(dir,'lines.html'));await page.screenshot({path:path.join(dir,'lines.png'),fullPage:true});}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
