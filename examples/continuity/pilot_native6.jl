using Serialization,Dates,LinearAlgebra,Statistics,oneAPI,CSV,DataFrames
include("experiment.jl")
include("sparse_refinement.jl")
include("diagnostics.jl")
const CE=ContinuityExperiment
const SR=SparseRefinement
function main()
 length(ARGS)==6 || error("usage: pilot_native6.jl COUNTRIES.jls PASS.jls SOURCE.arrow CODE FACTOR OUTPUT")
 code,factor=parse.(Int,ARGS[4:5]);out=ARGS[6]
 factor>=1 || error("invalid factor");ispath(out)&&error("output exists");mkpath(out)
 countries=deserialize(ARGS[1]);checkpoint=deserialize(ARGS[2])
 k=only(findall(c->c.code==code,countries));c=countries[k];p=checkpoint.plans[k]
 CE.compact_stats!(p,c)
 target=copy(c.target);target.parent_cell_id=collect(1:nrow(target));target.cell_id=copy(target.parent_cell_id)
 c=merge(c,(;target))
 fine=DataFrame([(x=factor*r.x+2ix-factor-1,y=factor*r.y+2iy-factor-1,parent_cell_id=j)
     for (j,r) in enumerate(eachrow(target)) for ix in 1:factor for iy in 1:factor])
 d=CE.country(ARGS[3],code;target=fine,dense=false)
 all(id->CE.H3.API.getResolution(id)==6,d.source.id) || error("expected H3-6 sources")
 all(id->CE.H3.API.getResolution(id)==5,c.source.id) || error("expected H3-5 guide")
 centres=CE.refined_centres(c,p,d)
 orientation(q)=ContinuityDiagnostics.orientations([(code=code,target=fine,xyz=q)],[nothing];moments=(c,p)->c.xyz)
 CSV.write(joinpath(out,"guide-orientation.csv"),orientation(centres))
 # Pilot only: a bounded graph around the accepted coarse transport support.
 lookup=Dict((r.x,r.y)=>j for (j,r) in enumerate(eachrow(target)))
 source_lookup=Dict(id=>i for (i,id) in enumerate(c.source.id))
 support=Vector{Vector{Int}}(undef,length(c.a))
 block=max(1,div(1_000_000,length(c.b)))
 for start in 1:block:length(c.a)
   indices=start:min(start+block-1,length(c.a));values=exp.(CE.logblock(p,indices))
   for (local_i,i) in enumerate(indices)
     row=view(values,local_i,:);threshold=.99999sum(row)
     order=sortperm(row;rev=true);mass=0.;keep=Set{Int}()
     for j in order
         mass+=row[j]
         for dx in -4:2:4,dy in -4:2:4
             t=get(lookup,(target.x[j]+dx,target.y[j]+dy),0);t>0&&push!(keep,t)
         end
         mass>=threshold && break
     end
     support[i]=sort!(collect(keep))
   end
 end
 source=Int32[];dest=Int32[];cost=Float64[];missing=0
 for i in eachindex(d.a)
     parent=CE.H3.API.cellToParent(d.source.id[i],5);ci=get(source_lookup,parent,0)
     # Native country extraction can add coarse parents absent from the old input.
     if ci==0
         missing+=1
         distances=[sum((d.xyz[l,i]-centres[l,j])^2 for l in 1:3) for j in axes(centres,2)]
         js=partialsortperm(distances,1:min(100,length(distances)))
     else
         js=[(j-1)*factor^2+t for j in support[ci] for t in 1:factor^2]
     end
     length(cost)+length(js)<=20_000_000 || error("pilot graph budget exceeded")
     for j in js
         push!(source,i);push!(dest,j);push!(cost,sum((d.xyz[l,i]-centres[l,j])^2 for l in 1:3)/2)
     end
 end
 scale=max(maximum(cost),eps());cost./=scale
 g=SR.graph(length(d.a),length(d.b),source,dest,cost)
 println((;time=now(UTC),code,factor,n=g.n,m=g.m,edges=length(cost),missing,scale,population=sum(d.source.value)));flush(stdout)
 serialize(joinpath(out,"graph.jls"),(;g,d,centres,scale))
 backend=oneAPI.oneAPIBackend();beta=nothing;rows=NamedTuple[]
 for eta in parse.(Float64,split(get(ENV,"PILOT_ETAS","1e-3,1e-4,5e-5,2.5e-5"),','))
     elapsed=@elapsed result=SR.solve(g,d.a,d.b,backend;eta,initial_beta=beta,tolerance=1e-4,maxrelative=.001)
     beta=result.beta
     count995=0;spread=0.;q=zeros(3,g.m)
     for i in 1:g.n
         r=g.rows.ptr[i]:g.rows.ptr[i+1]-1;w=result.weights[r];js=g.target[r]
         count995+=searchsortedfirst(cumsum(sort(w;rev=true)),.995d.a[i])
         mx=sum(w.*fine.x[js])/d.a[i];my=sum(w.*fine.y[js])/d.a[i]
         spread+=sum(w.*((fine.x[js].-mx).^2 .+ (fine.y[js].-my).^2))/4
     end
     masses=zeros(g.m)
     for e in eachindex(result.weights)
         i,j=g.source[e],g.target[e];w=result.weights[e];masses[j]+=w
         for l in 1:3;q[l,j]+=w*d.xyz[l,i];end
     end
     q./=transpose(masses)
     displacement=sqrt(sum(abs2,q.-centres)/g.m)*6371
     geometry=orientation(q);CSV.write(joinpath(out,"eta-$eta-orientation.csv"),geometry)
     row=(;eta,elapsed,fold_area_km2=only(geometry.positive_area_km2),iterations=result.iterations,primal=result.primal_iterations,ratio995=count995/g.n,spatial_rms=sqrt(spread),centre_rms_km=displacement,result.error...)
     println(row);flush(stdout);push!(rows,row);CSV.write(joinpath(out,"summary.csv"),rows)
     serialize(joinpath(out,"eta-$eta.jls"),(;result,eta))
     GC.gc(true)
 end
end
main()
