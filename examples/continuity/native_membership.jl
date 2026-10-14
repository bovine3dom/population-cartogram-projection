module NativeMembership
using H3,Dates
# Diagnostic native-cell classification. No polygon simplification.
struct RingBins
 xmin::Float64
 xmax::Float64
 ymin::Float64
 ymax::Float64
 bins::Vector{Vector{NTuple{4,Float64}}}
end
const LATBIN=deg2rad(.25)
function ring_bins(ring)
 length(ring)>=4 && first(ring)==last(ring) || error("expected a closed polygon ring")
 points=[(deg2rad(p[1]),deg2rad(p[2])) for p in ring]
 xmin,xmax=extrema(first.(points));ymin,ymax=extrema(last.(points))
 bins=[NTuple{4,Float64}[] for _ in 1:floor(Int,(ymax-ymin)/LATBIN)+1]
 for k in 1:length(points)-1
  ax,ay=points[k];bx,by=points[k+1]
  abs(bx-ax)<=pi || error("unsplit antimeridian edge")
  ay==by && continue
  edge=(ax,ay,by,(bx-ax)/(by-ay))
  for j in floor(Int,(min(ay,by)-ymin)/LATBIN)+1:floor(Int,(max(ay,by)-ymin)/LATBIN)+1
   push!(bins[j],edge)
  end
 end
 RingBins(xmin,xmax,ymin,ymax,bins)
end
function contains(r::RingBins,x,y)
 r.xmin<=x<=r.xmax && r.ymin<=y<=r.ymax || return false
 inside=false
 for (ax,ay,by,slope) in r.bins[clamp(floor(Int,(y-r.ymin)/LATBIN)+1,1,length(r.bins))]
  ((ay>y)!=(by>y)) && x<ax+(y-ay)*slope && (inside=!inside)
 end
 inside
end
function point_owners(ids,boundaries,allowed)
 polygons=Tuple{Int32,Vector{RingBins}}[]
 for feature in boundaries["features"]
  code=tryparse(Int,string(feature["properties"]["ISO_N3_EH"]))
  code in allowed || continue
  g=feature["geometry"];g["type"] in ("Polygon","MultiPolygon") || error("unsupported boundary")
  for p in (g["type"]=="Polygon" ? [g["coordinates"]] : g["coordinates"])
   push!(polygons,(Int32(code),ring_bins.(p)))
  end
 end
 sort!(polygons;by=first)
 buckets=[Int[] for _ in 1:72,_ in 1:36]
 xbin(x)=clamp(floor(Int,(rad2deg(x)+180)/5)+1,1,72)
 ybin(y)=clamp(floor(Int,(rad2deg(y)+90)/5)+1,1,36)
 for (k,(_,rings)) in enumerate(polygons)
  outer=first(rings)
  for ix in xbin(outer.xmin):xbin(outer.xmax),iy in ybin(outer.ymin):ybin(outer.ymax)
   push!(buckets[ix,iy],k)
  end
 end
 owner=zeros(Int32,length(ids));overlaps=0
 for (i,id) in enumerate(ids)
  coord=H3.API.cellToLatLng(id);x,y=coord.lng,coord.lat;lastcode=Int32(0)
  for k in buckets[xbin(x),ybin(y)]
   code,rings=polygons[k];lastcode==code && continue
   contains(first(rings),x,y) || continue
   any(r->contains(r,x,y),view(rings,2:length(rings))) && continue
   lastcode=code
   if owner[i]==0;owner[i]=code;else;overlaps+=1;end
  end
  i%5_000_000==0 && (println(now(UTC)," native points=",i);flush(stdout))
 end
 return owner,overlaps
end

end
