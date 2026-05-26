# Population cartogram projection

under construction - just ramblings for now


## thesis

1) maps are maps of physical geography
2) people do not experience physical geography
3) people experience social geography
4) we should have maps of social geography

## goals

- easy interface: dump data, get a map scaled by population
    - auto-detect legend etc
- easy to read:
    - display cities, borders
    - stretch goal: internal boundaries e.g. NUTS2

## method

1) grab cells from https://github.com/owid/cartograms/ / https://owid.github.io/cartograms
2) per country: sort cells and h3 ghs-pop by lat and lon. fractionally assign h3 to cell until weight is filled up. sense check using nuts regions / cities
3) if assigning by sorting is bad, give hungarian algorithm a go - potentially worth doing hungarian at a coarse level and then using the sorting method within each coarse cell
4) in julia play with data and make sure it feels good
5) make some d3.js or three.js web app


## notes

- https://github.com/owid/cartograms/blob/main/data/country-code.csv has the country codes to save you looking again and again
- it'd be cool to borrow their algorithm and make higher resolution cartograms for use within countries
