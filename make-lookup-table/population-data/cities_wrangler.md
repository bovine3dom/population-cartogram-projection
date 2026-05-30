getting data

```sh
#!/bin/bash
wget https://download.geonames.org/export/dump/cities500.zip

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
