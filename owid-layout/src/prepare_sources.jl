import Arrow, H3, LibGEOS, GeoInterface

file_digest(path)=open(io->bytes2hex(sha256(io)),path)

function natural_earth_parts(boundary)
    parts=NamedTuple[]
    for feature in boundary["features"]
        props=feature["properties"]; geometry=feature["geometry"]
        geometry["type"] in ("Polygon","MultiPolygon") || error("Expected polygon geometry")
        polygons=geometry["type"]=="Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
        for coordinates in polygons
            rings=[[Float64[p[1],p[2]] for p in ring] for ring in coordinates]
            id=string(props["GU_A3"],":",bytes2hex(sha256(JSON.json(rings)))[1:16])
            outer=first(rings)
            push!(parts,(component_id=id,country_id=String(props["ADM0_A3"]),map_unit=String(props["GU_A3"]),
                name=String(props["NAME"]),raw_country_code=string(props["ISO_N3_EH"]),rings=rings,
                west=minimum(first,outer),south=minimum(last,outer),east=maximum(first,outer),north=maximum(last,outer)))
        end
    end
    allunique(p.component_id for p in parts) || error("Duplicate Natural Earth component IDs")
    sort!(parts;by=p->p.component_id)
end

function source_index(parts)
    context=LibGEOS.GEOSContext()
    geometries=Vector{Union{Nothing,LibGEOS.Polygon}}(nothing,length(parts))
    prepared=Vector{Union{Nothing,LibGEOS.PreparedGeometry{LibGEOS.Polygon}}}(nothing,length(parts))
    bins=[Int[] for _ in 1:360*180]; skipped=NamedTuple[]
    for (i,p) in enumerate(parts)
        if p.east-p.west>180
            push!(skipped,(component_id=p.component_id,reason="longitude_span_over_180"));continue
        end
        g=LibGEOS.Polygon(p.rings,context)
        if !LibGEOS.isValid(g)
            push!(skipped,(component_id=p.component_id,reason=LibGEOS.isValidReason(g)));continue
        end
        geometries[i]=g;prepared[i]=LibGEOS.prepareGeom(g)
        for x in clamp(floor(Int,p.west+180),0,359):clamp(floor(Int,p.east+180),0,359),
            y in clamp(floor(Int,p.south+90),0,179):clamp(floor(Int,p.north+90),0,179)
            push!(bins[x+360y+1],i)
        end
    end
    (;context,geometries,prepared,bins,skipped)
end

function source_owner(index,parts,longitude,latitude)
    -180<=longitude<=180 && -90<=latitude<=90 || error("Invalid geographic coordinate")
    x=clamp(floor(Int,longitude+180),0,359);y=clamp(floor(Int,latitude+90),0,179)
    owner=0
    for i in index.bins[x+360y+1]
        p=parts[i]
        p.west<longitude<p.east && p.south<latitude<p.north || continue
        geometry=index.prepared[i];context=index.context
        result=GC.@preserve geometry context LibGEOS.GEOSPreparedContainsXY_r(context,geometry.ptr,longitude,latitude)
        result in (0,1) || error("GEOS contains failed")
        if result==1
            owner==0 || return -1
            owner=i
        end
    end
    owner
end

function dissolved_parts(parts,populations,counts,index)
    parent=collect(eachindex(parts))
    function root(i)
        while parent[i]!=i;parent[i]=parent[parent[i]];i=parent[i];end
        i
    end
    segments=Dict{Tuple{NTuple{2,Float64},NTuple{2,Float64}},Vector{Int}}()
    for (i,p) in enumerate(parts),ring in p.rings,j in 1:length(ring)-1
        a,b=Tuple(ring[j]),Tuple(ring[j+1]);a==b && continue
        push!(get!(segments,minmax(a,b),Int[]),i)
    end
    for indices in values(segments),i in indices,j in indices
        parts[i].country_id==parts[j].country_id || continue
        a,b=root(i),root(j);parent[max(a,b)]=min(a,b)
    end
    groups=Dict{Int,Vector{Int}}()
    for i in eachindex(parts);push!(get!(groups,root(i),Int[]),i);end
    rows=NamedTuple[];features=Dict[];crosswalk=NamedTuple[]
    for indices in sort!(collect(values(groups));by=first)
        p=parts[first(indices)];rings=p.rings
        scope=p.map_unit;name=p.name
        if length(indices)>1
            all(i->index.geometries[i]!==nothing,indices) || error("Invalid polygon in a dissolve")
            geoms=LibGEOS.Polygon[index.geometries[i] for i in indices]
            merged=LibGEOS.unaryUnion(LibGEOS.GeometryCollection(geoms,index.context))
            merged isa LibGEOS.Polygon && LibGEOS.isValid(merged) || error("Shared-edge union is not one valid polygon")
            isapprox(LibGEOS.area(merged),sum(LibGEOS.area,geoms);rtol=1e-10) || error("Overlapping source polygons")
            rings=GeoInterface.coordinates(merged);scope=p.country_id;name=p.country_id
        end
        id=string(scope,":",bytes2hex(sha256(JSON.json(rings)))[1:16]);outer=first(rings)
        push!(rows,(component_id=id,country_id=p.country_id,map_unit=scope,name=name,raw_country_code=p.raw_country_code,
            population=sum(populations[indices]),source_cells=sum(counts[indices]),holes=length(rings)-1,
            west=minimum(first,outer),south=minimum(last,outer),east=maximum(first,outer),north=maximum(last,outer)))
        push!(features,Dict("type"=>"Feature","properties"=>Dict("component_id"=>id,"country_id"=>p.country_id,"map_unit"=>scope,"name"=>name),
                           "geometry"=>Dict("type"=>"Polygon","coordinates"=>rings)))
        append!(crosswalk,[(original_component_id=parts[i].component_id,component_id=id) for i in indices])
    end
    allunique(r.component_id for r in rows) || error("Duplicate dissolved IDs")
    (;rows=sort!(rows;by=r->r.component_id),features=sort!(features;by=f->f["properties"]["component_id"]),crosswalk)
end

"""Prepare components directly from a Kontur H3-8 Arrow and Natural Earth GeoJSON.

Membership uses strict contains on native H3 centres. Boundary, unmatched, and
ambiguous centres are not silently reassigned. The geometry library is pinned.
"""
function prepare_sources(population_path,boundary_path,output)
    ispath(output) && error("Use a new source output directory")
    parts=natural_earth_parts(JSON.parsefile(boundary_path));index=source_index(parts)
    table=Arrow.Table(population_path)
    sorted=sort!(UInt64.(table.h3))
    all(i->sorted[i]!=sorted[i-1],2:length(sorted)) || error("Duplicate Kontur H3 IDs")
    sorted=nothing
    populations=zeros(length(parts));counts=zeros(Int,length(parts));owners=zeros(Int32,length(table.h3))
    unmatched=0.0;ambiguous=0.0;total=0.0
    for (i,(raw_id,raw_value)) in enumerate(zip(table.h3,table.population))
        id=UInt64(raw_id);value=Float64(raw_value)
        H3.API.isValidCell(id) && H3.API.getResolution(id)==8 || error("Expected valid native H3-8 cells")
        isfinite(value) && value>0 || error("Invalid population")
        point=H3.API.cellToLatLng(id)
        owner=source_owner(index,parts,rad2deg(point.lng),rad2deg(point.lat));owners[i]=owner;total+=value
        if owner>0
            populations[owner]+=value;counts[owner]+=1
        elseif owner==0
            unmatched+=value
        else
            ambiguous+=value
        end
        i%2_000_000==0 && println("Source preparation: $i / $(length(owners)) centres")
    end
    isapprox(sum(populations)+unmatched+ambiguous,total;rtol=1e-12) || error("Population accounting failed")
    dissolved=dissolved_parts(parts,populations,counts,index)
    root=dirname(abspath(output));mkpath(root);temporary=mktempdir(root;prefix="sources-")
    try
        CSV.write(joinpath(temporary,"components.csv"),dissolved.rows)
        CSV.write(joinpath(temporary,"original-to-dissolved.csv"),dissolved.crosswalk)
        open(io->JSON.print(io,Dict("type"=>"FeatureCollection","features"=>dissolved.features)),joinpath(temporary,"polygons.geojson"),"w")
        Arrow.write(joinpath(temporary,"source-membership.arrow"),(id=table.h3,population=table.population,original_component_index=owners))
        CSV.write(joinpath(temporary,"original-components.csv"),[(component_index=i,component_id=p.component_id) for (i,p) in enumerate(parts)])
        manifest=(input_cells=length(owners),input_population=total,population=sum(populations),
            unmatched_cells=count(==(0),owners),unmatched_population=unmatched,
            ambiguous_cells=count(==(-1),owners),ambiguous_population=ambiguous,skipped=index.skipped,
            input_polygons=length(parts),output_polygons=length(dissolved.rows),population_year="not declared by input Arrow",
            method="Native H3-8 centres; strict GEOS contains; exact shared-edge dissolve within ADM0_A3",
            julia_version=string(VERSION),libgeos_version=string(Base.pkgversion(LibGEOS)),
            inputs=Dict(p=>file_digest(p) for p in (population_path,boundary_path,@__FILE__,joinpath(@__DIR__,"..","Manifest.toml"))))
        open(io->JSON.print(io,manifest),joinpath(temporary,"manifest.json"),"w")
        write(joinpath(temporary,"complete.txt"),"complete\n")
        mv(temporary,output)
        manifest
    finally
        ispath(temporary) && rm(temporary;recursive=true)
    end
end
