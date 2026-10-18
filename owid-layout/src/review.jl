# SVG review helpers. Coordinates are north-positive in both input spaces.
escape_markup(s) = replace(string(s), '&'=>"&amp;", '<'=>"&lt;", '>'=>"&gt;", '"'=>"&quot;")

function padded_bounds(points; minimum_span=0.01, padding=0.15)
    isempty(points) && throw(ArgumentError("Empty review geometry"))
    west,south = minimum(first,points),minimum(last,points)
    east,north = maximum(first,points),maximum(last,points)
    dx,dy = max(east-west,minimum_span),max(north-south,minimum_span)
    cx,cy = (east+west)/2,(north+south)/2
    (cx-dx*(0.5+padding),cy-dy*(0.5+padding),cx+dx*(0.5+padding),cy+dy*(0.5+padding))
end

function panel_transform(bounds, x, y, width, height)
    west,south,east,north = bounds
    scale = min(width/(east-west),height/(north-south))
    ox,oy = x+(width-scale*(east-west))/2,y+(height-scale*(north-south))/2
    p -> (ox+(p[1]-west)*scale,oy+(north-p[2])*scale), scale
end

function svg_path(rings, transform)
    join(["M" * join([join(round.(transform(p);digits=2),",") for p in ring]," L") * " Z" for ring in rings]," ")
end

function geo_rings(geometry, longitude, latitude)
    polygons = geometry["type"] == "Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
    [[[( (mod(Float64(p[1])-longitude+180,360)-180)*cosd(latitude), Float64(p[2])-latitude) for p in ring]
      for ring in polygon] for polygon in polygons]
end

function draw_geography(io, shapes, selected, bounds, x, y, width, height, colour, clip)
    transform,scale = panel_transform(bounds,x,y,width,height)
    println(io,"<defs><clipPath id='$clip'><rect x='$x' y='$y' width='$width' height='$height'/></clipPath></defs><g clip-path='url(#$clip)'>")
    # Draw the selected component last so its coast remains visible.
    for id in sort!(collect(keys(shapes));by=id->(id==selected,id))
        polygons = shapes[id]
        for rings in polygons
            outer = first(rings)
            minimum(first,outer)>bounds[3] && continue
            maximum(first,outer)<bounds[1] && continue
            minimum(last,outer)>bounds[4] && continue
            maximum(last,outer)<bounds[2] && continue
            fill = id == selected ? colour : "#dedbd3"
            stroke = id == selected ? "#222" : "#aaa79e"
            println(io,"<path d='$(svg_path(rings,transform))' fill='$fill' fill-rule='evenodd' stroke='$stroke' stroke-width='0.7'><title>$(escape_markup(id))</title></path>")
        end
    end
    if haskey(shapes,selected)
        points = [p for rings in shapes[selected] for p in first(rings)]
        west,south,east,north = padded_bounds(points;padding=0)
        if max(east-west,north-south)*scale < 10
            px,py = transform(((west+east)/2,(south+north)/2))
            println(io,"<circle cx='$px' cy='$py' r='6' fill='none' stroke='$colour' stroke-width='2' stroke-dasharray='2 2'><title>Location of small component</title></circle>")
        end
    end
    println(io,"</g>")
end

function draw_tiles(io, owners, selected, bounds, x, y, width, height, clip; labels=false, highlights=Set([selected]), colours=Dict())
    transform,scale = panel_transform(bounds,x,y,width,height)
    println(io,"<defs><clipPath id='$clip'><rect x='$x' y='$y' width='$width' height='$height'/></clipPath></defs><g clip-path='url(#$clip)'>")
    for (p,id) in sort!(collect(owners);by=first)
        (bounds[1]-1<=p[1]<=bounds[3]+1 && bounds[2]-1<=p[2]<=bounds[4]+1) || continue
        px,py = transform((p[1]-0.5,p[2]+0.5))
        fill = get(colours,id,id in highlights ? "#eaa35e" : "#d6d6d6")
        println(io,"<rect x='$px' y='$py' width='$scale' height='$scale' fill='$fill'><title>$(escape_markup(id))</title></rect>")
        for (a,b,q) in (((-.5,-.5),(.5,-.5),(p[1],p[2]-1)),((.5,-.5),(.5,.5),(p[1]+1,p[2])),
                        ((.5,.5),(-.5,.5),(p[1],p[2]+1)),((-.5,.5),(-.5,-.5),(p[1]-1,p[2])))
            get(owners,q,"") == id && continue
            ax,ay = transform((p[1]+a[1],p[2]+a[2])); bx,by = transform((p[1]+b[1],p[2]+b[2]))
            println(io,"<path d='M$ax,$ay L$bx,$by' stroke='#555' stroke-width='0.7'/>")
        end
    end
    if labels
        ids = sort!(collect(Set(values(owners)));by=id->(id!=selected,id))
        placed = NTuple{4,Float64}[]
        for id in ids
            points = sort!([p for (p,c) in owners if c==id])
            centre = (sum(first,points)/length(points),sum(last,points)/length(points))
            px,py = transform(centre)
            (x<=px<=x+width && y<=py<=y+height) || continue
            label = last(split(id,':')); halfwidth = 4length(label)+2
            position = nothing
            for radius in 0:12:144, (dx,dy) in ((0,1),(1,0),(0,-1),(-1,0),(1,1),(-1,1),(1,-1),(-1,-1))
                lx,ly = px+radius*dx,py+radius*dy
                box = (lx-halfwidth,ly-12,lx+halfwidth,ly+4)
                (x<=box[1] && box[3]<=x+width && y<=box[2] && box[4]<=y+height) || continue
                any(b -> box[1]<b[3]+2 && box[3]>b[1]-2 && box[2]<b[4]+2 && box[4]>b[2]-2,placed) && continue
                position = (lx,ly); push!(placed,box); break
            end
            isnothing(position) && continue
            lx,ly = position
            if (lx,ly)!=(px,py)
                println(io,"<path d='M$px,$py L$lx,$ly' stroke='#555' stroke-width='0.6'/>")
            end
            println(io,"<text x='$lx' y='$ly' text-anchor='middle' font-size='12' paint-order='stroke' stroke='white' stroke-width='3' fill='#111'>$(escape_markup(label))</text>")
        end
    end
    println(io,"</g>")
end

function svg_start(io, width, height)
    println(io,"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 $width $height' width='$width' height='$height'><rect width='100%' height='100%' fill='#faf9f6'/><g font-family='sans-serif' fill='#222'>")
end
svg_end(io) = println(io,"</g></svg>")
