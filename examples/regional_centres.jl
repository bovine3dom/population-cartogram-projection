#!/usr/bin/env julia

module RegionalCentresExample

using CSV
using DataFrames
using PopulationCartogramProjection

include(joinpath(@__DIR__, "publish_output.jl"))

const ROOT = normpath(joinpath(@__DIR__, ".."))
const FIXTURE_PATH = joinpath(ROOT, "test", "fixtures", "synthetic_sources.csv")

function main(args=ARGS)
    length(args) <= 1 || error("usage: regional_centres.jl [output-directory]")
    output_dir = isempty(args) ? joinpath(ROOT, "output", "regional-centres") : abspath(only(args))

    sources = CSV.read(FIXTURE_PATH, DataFrame)
    sources.households = [510_000, 760_000, 1_080_000, 390_000, 310_000]
    sources.employment_rate = [0.71, 0.74, 0.69, 0.76, 0.67]
    validate_sources(sources)

    grid = load_owid_grid()
    plan = plan_mapping(sources, grid)
    fitted = fit_mapping_auto(sources, plan.grid; backend=:cpu)
    households = project_extensive(
        fitted.mapping, sources, plan.grid; value=:households,
    )
    employment_rate = project_ratio(
        fitted.mapping,
        sources,
        plan.grid;
        value=:employment_rate,
        weight=:population,
        denominator=:projected_population,
    )

    paths = (;
        mapping=joinpath(output_dir, "mapping.csv"),
        source_retention=joinpath(output_dir, "source_retention.csv"),
        sources=joinpath(output_dir, "sources.csv"),
        grid=joinpath(output_dir, "grid.csv"),
        metadata=joinpath(output_dir, "metadata.toml"),
        households=joinpath(output_dir, "projected_households.csv"),
        employment_rate=joinpath(output_dir, "projected_employment_rate.csv"),
        summary=joinpath(output_dir, "summary.csv"),
    )
    publish_output(output_dir) do staged_dir
        save_fit(staged_dir, fitted; sources, grid=plan.grid)
        CSV.write(joinpath(staged_dir, basename(paths.households)), households.cells)
        CSV.write(joinpath(staged_dir, basename(paths.employment_rate)), employment_rate.cells)
        CSV.write(joinpath(staged_dir, basename(paths.summary)), DataFrame(
            metric=[
                "selected_eta",
                "mapping_rows",
                "retained_population_share",
                "projected_households",
                "dropped_households",
            ],
            value=[
                string(fitted.metadata.selected_eta),
                string(nrow(fitted.mapping)),
                string(employment_rate.metadata.weighted_retained_share),
                string(households.metadata.projected_total),
                string(households.metadata.dropped_total),
            ],
        ))
    end

    println("Wrote regional projection CSVs to $output_dir")
    println(
        "Retained population: " *
        "$(round(100 * employment_rate.metadata.weighted_retained_share; digits=3))%",
    )
    return paths
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    RegionalCentresExample.main(ARGS)
end
