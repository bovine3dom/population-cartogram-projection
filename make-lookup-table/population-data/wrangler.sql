-- clickhouse-local
SELECT reinterpretAsUInt64(reverse(unhex(h3))) h3, population from sqlite('kontur_population_20231101.gpkg', 'population')
INTO OUTFILE 'kontur_population_20231101.arrow' TRUNCATE FORMAT Arrow
SETTINGS output_format_arrow_compression_method = 'none';


-- on the server
create table public_kontur_population_20231101
engine=MergeTree()
order by h3
as
select assumeNotNull(h3) h3, assumeNotNull(population) population from file('chungus/kontur_population_20231101.arrow')
