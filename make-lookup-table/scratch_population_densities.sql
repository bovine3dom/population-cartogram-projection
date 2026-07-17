drop table if exists population_densities;

create table population_densities
engine = Memory
as
select h3ToParent(h3, 5) h3_p, quantileExactWeighted(0.5)(population/(h3CellAreaM2(h3)/(1000*1000)), toUInt64(population)) value from 'population-data/kontur_population_20231101.arrow'
group by h3_p;

select substring(lower(hex(h3_p)), 2) index, value from population_densities
into outfile 'population_density.arrow' truncate
settings output_format_arrow_compression_method = 'none';

select 
    toUInt32(bitAnd(h3_p, toUInt64(4294967295))) as index_lower,
    toUInt32(bitShiftRight(h3_p, 32)) as index_upper,
    value 
    from population_densities
into outfile 'population_density_hilo.arrow' truncate
settings output_format_arrow_compression_method = 'none';
