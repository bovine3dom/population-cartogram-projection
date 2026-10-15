# Lossless Arrow stream packing

`pack_stream.py` changes storage only. It does not remove rows, change values,
or change row order. It uses small replacement dictionaries for each record
batch. It keeps the H3 halves as UInt32 and source population as Float64.
The IPC stream is not compressed. Keep the server's existing compression
policy. No gzip response setting or nginx change is required.

## Run and check

Use an isolated Python environment with `pyarrow==25.0.1`:

```sh
python examples/continuity/mobile/pack_stream.py INPUT.arrow OUTPUT.arrow
julia --project=examples/continuity/mobile \
  examples/continuity/mobile/verify_stream.jl INPUT.arrow OUTPUT.arrow REPORT.toml
```

The output path must be new. The Python check compares every decoded column
with the input, checks row coverage, and checks that the input hash did not
change. The Julia check reads each batch separately and makes the same value
comparison. The reference for the Julia check must be a normal Arrow table
without replacement dictionaries.

Run `test/pack_stream.py` in that Python environment. Its transport test includes
null labels, large UInt32 halves, changing dictionary pools, and a second packing
pass. Its density test checks multiple batches.

## Reader limits

This is a standard IPC **stream**, not an IPC file with a footer. A reader must
support replacement dictionaries. PyArrow and H3-MON's Apache Arrow JavaScript
reader pass the full native-planet comparison. The headless H3-MON check also
loads the stream without errors. No H3-MON code change is required.

With the installed Arrow.jl 2.8.1, `Arrow.Table` gives incorrect values when it
joins these replacement dictionaries. Use `Arrow.Stream` and process each batch
before reading the next batch. That reader passes the full column comparison.
Do not describe the stream as compatible with all existing Arrow consumers.
Keep the ordinary Arrow export as the compatibility reference.

The format support is described in the
[PyArrow IPC options](https://arrow.apache.org/docs/python/generated/pyarrow.ipc.IpcWriteOptions.html).

## Measured native baseline

The factor-1 native H3-6 files use 173,964,652 bytes before this packing and
125,848,832 bytes after it. All 6,188,040 transport rows remain. This is a storage
reduction, not a sharper fit, and it still exceeds the 100 MB file goal.

File size is not browser memory. The default-precision headless planet check
retains about 1.3 GB of backing storage plus 102 MB of JavaScript heap after
collection. The native source map has almost two million geographic cells.
These checks do not establish safe use on a phone. The old H3-5 dataset remains
available. The removed viewport-geometry feature is not restored.
