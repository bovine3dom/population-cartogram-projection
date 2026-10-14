# Local mass correction before native-source refinement.
module LocalBalance
using ..NativeHierarchy
using LinearAlgebra
const NH=NativeHierarchy
function pushheap!(heap,value)
 push!(heap,value);i=length(heap)
 while i>1
  p=i÷2;heap[p]<=heap[i]&&break;heap[p],heap[i]=heap[i],heap[p];i=p
 end
end
function popheap!(heap)
 value=heap[1];last=pop!(heap)
 if !isempty(heap)
  heap[1]=last;i=1
  while 2i<=length(heap)
   j=2i;j<length(heap)&&heap[j+1]<heap[j]&&(j+=1)
   heap[i]<=heap[j]&&break;heap[i],heap[j]=heap[j],heap[i];i=j
  end
 end
 value
end
function target_graph(target,q)
 m=size(q,2);adj=[Tuple{Int,Float64}[] for _ in 1:m];parent=collect(1:m)
 function root(i)
  while parent[i]!=i;parent[i]=parent[parent[i]];i=parent[i];end
  i
 end
 function link(i,j)
  cost=1+6371sqrt(sum((q[l,i]-q[l,j])^2 for l in 1:3))
  push!(adj[i],(j,cost));push!(adj[j],(i,cost));parent[root(i)]=root(j)
 end
 positions=Dict((r.x,r.y)=>i for (i,r) in enumerate(eachrow(target)))
 for (i,r) in enumerate(eachrow(target)),pos in ((r.x+2,r.y),(r.x,r.y+2))
  j=get(positions,pos,0);j>0&&link(i,j)
 end
 virtual=0
 while true
  roots=root.(1:m);length(unique(roots))==1&&break
  best=Dict{Int,Tuple{Float64,Int,Int}}()
  @inbounds for i in 1:m-1,j in i+1:m
   roots[i]==roots[j]&&continue
   distance=sum((q[l,i]-q[l,j])^2 for l in 1:3);edge=(distance,i,j)
   for r in (roots[i],roots[j])
    (!haskey(best,r)||edge<best[r])&&(best[r]=edge)
   end
  end
  for (_,i,j) in sort!(collect(values(best)))
   root(i)==root(j)&&continue;link(i,j);virtual+=1
  end
 end
 (;adj,virtual)
end
function shortest(adj,start)
 dist=fill(Inf,length(adj));pred=zeros(Int,length(adj));dist[start]=0.
 heap=Tuple{Float64,Int}[(0.,start)]
 while !isempty(heap)
  distance,i=popheap!(heap);distance==dist[i]||continue
  for (j,cost) in adj[i]
   next=distance+cost
   if next<dist[j];dist[j]=next;pred[j]=i;pushheap!(heap,(next,j));end
  end
 end
 dist,pred
end
function balance(state)
 (;guide,d,ids,a,xyz,q)=state;n=length(ids);m=length(d.b)
 old=Dict(id=>i for (i,id) in enumerate(guide.meta.ids));columns=[Dict{Int,Float64}() for _ in 1:m]
 mass=zeros(m)
 for (p,id) in enumerate(ids)
  i=get(old,id,0)
  if i==0
   j=argmin([sum((xyz[l,p]-q[l,j])^2 for l in 1:3) for j in 1:m]);columns[j][p]=a[p];mass[j]+=a[p]
  else
   rows=view(guide.index.source_rows,guide.index.source_ptr[i]:guide.index.source_ptr[i+1]-1)
   total=sum(e->guide.weight[e],rows)
   for e in rows
    j=guide.index.target[e];w=a[p]*guide.weight[e]/total
    w>0 || continue
    columns[j][p]=get(columns[j],p,0.)+w;mass[j]+=w
   end
  end
 end
 initial_l1=sum(abs.(mass.-d.b));graph=target_graph(d.target,q);steps=0;moved=0.;tolerance=1e-12
 for sink in sortperm(d.b.-mass;rev=true)
  d.b[sink]-mass[sink]>tolerance||continue
  dist,pred=shortest(graph.adj,sink)
  while d.b[sink]-mass[sink]>tolerance
   donor=0;best=Inf
   for j in 1:m
    mass[j]-d.b[j]>tolerance&&dist[j]<best&&(donor=j;best=dist[j])
   end
   donor==0&&break
   path=Int[donor];j=donor
   while j!=sink
    j=pred[j];j>0||error("disconnected balance path");push!(path,j)
    d.b[j]-mass[j]>tolerance&&break
   end
   flow=min(mass[donor]-d.b[donor],d.b[last(path)]-mass[last(path)],.25/m)
   flow>tolerance||error("mass correction stalled")
   for k in length(path)-1:-1:1
    from,to=path[k],path[k+1];fraction=flow/mass[from];actual=0.
    fraction<=.251||error("excess local transfer")
    for (p,w) in columns[from]
     amount=fraction*w;amount>1e-20||continue
     columns[from][p]=w-amount;columns[to][p]=get(columns[to],p,0.)+amount;actual+=amount
    end
    mass[from]-=actual;mass[to]+=actual;moved+=actual
   end
   steps+=1;steps<=20m||error("too many local transfers")
  end
 end
 source=Int32[];target=Int32[];weights=Float64[]
 for j in 1:m,p in sort!(collect(keys(columns[j])))
  w=columns[j][p];w>1e-25||continue
  push!(source,p);push!(target,j);push!(weights,w)
 end
 keep=NH.retain(source,target,weights,n,m)
 source=source[keep];target=target[keep];weights=weights[keep]
 sums=zeros(n);for (p,w) in zip(source,weights);sums[p]+=w;end
 weights.*=a[source]./sums[source]
 check=NH.SR.residual((;n,m,source,target),weights,a,d.b)
 check.l1<=1e-5&&check.relative<=.0003&&check.source<=1e-10||error("local balance failed checks")
 (;source,target,weights,components=graph.virtual+1,full_edges=sum(length,columns),check,method="local geographic mass redistribution",
   moved_mass=moved,initial_target_l1=initial_l1,steps,virtual_links=graph.virtual)
end
end
