module PoseGraph
using LinearAlgebra, Random
using ..ContinuityExperiment
const CE=ContinuityExperiment

function tables(countries,choices,edges,weights;strength=10.,eta=.002,scale_km=900.,fold_strength=1.)
    labels=length(first(choices))
    all(length(c)==labels for c in choices) || error("pose counts differ")
    q=[[CE.means(c,p) for p in plans] for (c,plans) in zip(countries,choices)]
    unary=zeros(length(countries),labels)
    pair=Dict{Tuple{Int,Int},Matrix{Float64}}()
    face_count=max(length(CE.triangles(countries)),1)
    scale=strength/(2*(scale_km/6371)^2)
    for (k,c) in enumerate(countries), label in 1:labels
        p=choices[k][label]
        unary[k,label]=sum(c.cost.*p)+eta*sum(x->x>0 ? x*(log(x)-1) : 0.,p)
        faces=CE.triangles([c])
        unary[k,label]+=fold_strength*length(faces)/face_count*
            first(CE.fold_penalty_gradient([c],[p],faces;forces_only=true))
    end
    for ((k,j,l,t),weight) in zip(edges,weights)
        if k==l
            for label in 1:labels
                unary[k,label]+=scale*weight*max(0.,2-2dot(q[k][label][:,j],q[k][label][:,t]))
            end
        else
            if k>l
                k,j,l,t=l,t,k,j
            end
            table=get!(pair,(k,l)) do
                zeros(labels,labels)
            end
            for a in 1:labels,b in 1:labels
                table[a,b]+=scale*weight*max(0.,2-2dot(q[k][a][:,j],q[l][b][:,t]))
            end
        end
    end
    return unary,pair
end

energy(unary,pair,labels)=sum(unary[k,a] for (k,a) in enumerate(labels))+
                        sum((table[labels[k],labels[l]] for ((k,l),table) in pair);init=0.)

function search(unary,pair;starts=64,seed=20261011,max_sweeps=50)
    rng=MersenneTwister(seed)
    n,choices=size(unary)
    initial=vcat([fill(a,n) for a in 1:choices],[rand(rng,1:choices,n) for _ in 1:starts])
    results=NamedTuple[]
    seen=Set{Tuple}()
    for labels in initial
        sweeps=0
        for sweep in 1:max_sweeps
            changed=false
            for k in randperm(rng,n)
                costs=copy(unary[k,:])
                for ((i,j),table) in pair
                    i==k && (costs .+= table[:,labels[j]])
                    j==k && (costs .+= table[labels[i],:])
                end
                best=argmin(costs)
                if costs[best]<costs[labels[k]]-1e-12
                    labels[k]=best;changed=true
                end
            end
            sweeps=sweep
            changed || break
        end
        Tuple(labels) in seen && continue
        push!(seen,Tuple(labels))
        push!(results,(;labels=copy(labels),sweeps,energy=energy(unary,pair,labels)))
    end
    return sort!(results;by=r->r.energy)
end
end
