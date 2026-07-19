# GeoNames City Extract

The local `cities500.zip` snapshot contains a `cities500.txt` entry dated
2026-04-14 and has SHA-256
`754948177b169cb2ddd24dc90c56465e9be3324cab970d3901f25aebcc8aa548`.
GeoNames data is licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
Attribute the data to [GeoNames](https://www.geonames.org/).

The download URL serves a changing snapshot. Record a new archive date and
checksum whenever refreshing it.

## Getting Data

```sh
#!/bin/bash
wget -O cities500.zip https://download.geonames.org/export/dump/cities500.zip

```
```sql
-- duckdb
install zipfs from community;
load zipfs;

drop table if exists cities500;
create table cities500 as
select * from read_csv('zip://cities500.zip/cities500.txt',
    columns = {
        geonameid: int64,
        name: varchar,
        asciiname: varchar,
        alternatenames: varchar,
        latitude: float,
        longitude: float,
        feature_class: varchar,
        feature_code: varchar,
        country_code: varchar,
        cc2: varchar,
        admin1_code: varchar,
        admin2_code: varchar,
        admin3_code: varchar,
        admin4_code: varchar,
        population: int64,
        elevation: float,
        dem: float,
        timezone: varchar,
        modification_date: date
    }
)
order by population desc, geonameid asc;

copy (
select name, country_code, latitude, longitude, population from cities500
    --where population > 50_000 -- change this to make file bigger or smaller. or even just use a limit
    order by population desc
) to 'tiny-cities.csv';
```
