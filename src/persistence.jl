function _toml_value(value)
    if value isa NamedTuple
        return Dict(
            string(key) => _toml_value(entry)
            for (key, entry) in pairs(value)
            if !ismissing(entry) && !isnothing(entry)
        )
    elseif value isa AbstractDict
        return Dict(
            string(key) => _toml_value(entry)
            for (key, entry) in pairs(value)
            if !ismissing(entry) && !isnothing(entry)
        )
    elseif value isa Tuple || value isa AbstractVector
        return [_toml_value(entry) for entry in value if !ismissing(entry) && !isnothing(entry)]
    elseif value isa Symbol
        return string(value)
    elseif value isa Bool
        return value
    elseif value isa AbstractFloat
        return Float64(value)
    elseif value isa Integer
        return Int(value)
    end
    return value
end

_file_sha256(path) = bytes2hex(open(SHA.sha256, path))

function _publish_fit(output_dir, staged_dir, filenames; overwrite)
    managed_filenames = (
        "mapping.csv",
        "source_retention.csv",
        "sources.csv",
        "grid.csv",
        "country_statuses.csv",
        "metadata.toml",
    )
    existing = filter(name -> ispath(joinpath(output_dir, name)), managed_filenames)
    !overwrite && !isempty(existing) && throw(ArgumentError(
        "refusing to overwrite $(join(existing, ", ")) in $output_dir",
    ))
    output_existed = isdir(output_dir)
    mkpath(output_dir)
    backup_dir = mktempdir(dirname(output_dir); prefix=".cartogram-fit-backup-")
    published = String[]
    publication_succeeded = false
    restoration_succeeded = false
    try
        for filename in existing
            mv(joinpath(output_dir, filename), joinpath(backup_dir, filename))
        end
        for filename in filenames
            mv(joinpath(staged_dir, filename), joinpath(output_dir, filename))
            push!(published, filename)
        end
        publication_succeeded = true
    catch
        for filename in published
            rm(joinpath(output_dir, filename); force=true)
        end
        for filename in existing
            backup = joinpath(backup_dir, filename)
            ispath(backup) && mv(backup, joinpath(output_dir, filename))
        end
        !output_existed && isempty(readdir(output_dir)) && rm(output_dir)
        restoration_succeeded = true
        rethrow()
    finally
        (publication_succeeded || restoration_succeeded) &&
            rm(backup_dir; recursive=true, force=true)
    end
    return nothing
end

function _save_fit(
    path,
    fit;
    sources,
    grid,
    country_statuses,
    schema,
    overwrite,
)
    output_dir = abspath(path)
    ispath(output_dir) && !isdir(output_dir) &&
        throw(ArgumentError("fit output path is not a directory: $output_dir"))
    for (name, table) in ((:sources, sources), (:grid, grid), (:country_statuses, country_statuses))
        isnothing(table) || table isa AbstractDataFrame ||
            throw(ArgumentError("$name must be a data frame"))
    end
    mkpath(dirname(output_dir))
    staged_dir = mktempdir(dirname(output_dir); prefix=".cartogram-fit-stage-")
    tables = [
        (:mapping, "mapping.csv", fit.mapping),
        (:source_retention, "source_retention.csv", fit.source_retention),
    ]
    !isnothing(sources) && push!(tables, (:sources, "sources.csv", sources))
    !isnothing(grid) && push!(tables, (:grid, "grid.csv", grid))
    !isnothing(country_statuses) && push!(
        tables,
        (:country_statuses, "country_statuses.csv", country_statuses),
    )
    try
        manifest = Dict(
            "schema" => schema,
            "schema_version" => 1,
            "package_version" => string(pkgversion(@__MODULE__)),
            "julia_version" => string(VERSION),
            "fit" => _toml_value(fit.metadata),
        )
        paths = Pair{Symbol,String}[]
        for (name, filename, table) in tables
            staged_path = joinpath(staged_dir, filename)
            CSV.write(staged_path, table)
            manifest["$(name)_file"] = filename
            manifest["$(name)_sha256"] = _file_sha256(staged_path)
            push!(paths, name => joinpath(output_dir, filename))
        end
        metadata_filename = "metadata.toml"
        open(joinpath(staged_dir, metadata_filename), "w") do io
            TOML.print(io, manifest; sorted=true)
        end
        filenames = [filename for (_, filename, _) in tables]
        push!(filenames, metadata_filename)
        _publish_fit(output_dir, staged_dir, filenames; overwrite)
        push!(paths, :metadata => joinpath(output_dir, metadata_filename))
        return (; paths...)
    finally
        ispath(staged_dir) && rm(staged_dir; recursive=true, force=true)
    end
end

"""
    save_fit(path, fit; overwrite=false)

Write mapping and retention CSVs plus a versioned TOML audit manifest. This is
not a resumable solver checkpoint and CSV readers must still preserve opaque ID
types explicitly.
"""
function save_fit(
    path::AbstractString,
    fit::MappingFit;
    sources=nothing,
    grid=nothing,
    overwrite::Bool=false,
)
    return _save_fit(
        path,
        fit;
        sources,
        grid,
        country_statuses=nothing,
        schema="PopulationCartogramProjection.MappingFit",
        overwrite,
    )
end

function save_fit(
    path::AbstractString,
    fit::MultiCountryFit;
    grid=nothing,
    overwrite::Bool=false,
)
    return _save_fit(
        path,
        fit;
        sources=fit.sources,
        grid,
        country_statuses=fit.country_statuses,
        schema="PopulationCartogramProjection.MultiCountryFit",
        overwrite,
    )
end
