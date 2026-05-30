Grab 'map units' from https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-admin-0-details/

```bash
7z x ne_10m_admin_0_map_units.zip
ogr2ogr -f GeoJSON ne_10m_admin_0_map_units.{geojson, shp}
# https://github.com/bovine3dom/geojson2h3
# you probably need to go in and disable zstd compression
julia +1.9.4 --project=. --threads auto geojson2h3.jl -r 8 -k'ISO_N3_EH' --compact ne_10m_admin_0_map_units.{geojson, arrow}
```

TODO: decide what resolution to use! For decent behaviour at borders we probably want 7/8. Kontur is 8

```clickhouse
# clickhouse-local
select * from file('ne_10m_admin_0_map_units.arrow') order by h3 asc into outfile 'ne_10m_admin_0_map_units.asc.arrow' format arrow
settings output_format_arrow_compression_method = 'none'
```
