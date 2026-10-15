"""Pack Arrow columns in an uncompressed IPC stream without changing rows."""
import hashlib
import json
from pathlib import Path
import sys
import time

import pyarrow as pa
import pyarrow.compute as pc


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def decoded(array):
    # Decode each dictionary before joining chunks with different pools.
    if isinstance(array, pa.ChunkedArray):
        return pa.concat_arrays([decoded(chunk) for chunk in array.chunks])
    return array.dictionary_decode() if pa.types.is_dictionary(array.type) else array


def pack(source, destination, *, batch_rows=65536):
    source, destination = Path(source), Path(destination)
    pending = destination.with_name(destination.name + ".pending")
    if destination.exists() or pending.exists():
        raise ValueError("Output or staging file already exists")
    if not 1 <= batch_rows <= 65536:
        raise ValueError("Batch size must be 1 to 65536 rows")
    started = time.monotonic()
    original_hash = digest(source)
    with pa.memory_map(str(source), "r") as memory:
        try:
            reader = pa.ipc.open_file(memory)
        except pa.ArrowInvalid:
            memory.seek(0)
            reader = pa.ipc.open_stream(memory)
        original = reader.read_all()
    if not original.num_rows:
        raise ValueError("Input has no rows")
    widths = {"x": 8, "y": 8, "code": 8, "label": 8, "population": 16,
              "index_lower": 8, "index_upper": 16}
    fields = []
    for field in original.schema:
        value = field.type.value_type if pa.types.is_dictionary(field.type) else field.type
        index = pa.int8() if widths.get(field.name) == 8 else pa.int16()
        kind = pa.dictionary(index, value) if field.name in widths else value
        fields.append(pa.field(field.name, kind, nullable=field.nullable, metadata=field.metadata))
    schema = pa.schema(fields, metadata=original.schema.metadata)
    pending.parent.mkdir(parents=True, exist_ok=True)
    sizes, offset = [], 0
    options = pa.ipc.IpcWriteOptions(compression=None, emit_dictionary_deltas=False)
    with pa.OSFile(str(pending), "wb") as sink, pa.ipc.new_stream(sink, schema, options=options) as writer:
        while offset < original.num_rows:
            count = min(batch_rows, original.num_rows - offset)
            while True:
                arrays, fits = [], True
                for field in schema:
                    values = decoded(original.column(field.name).slice(offset, count))
                    if pa.types.is_dictionary(field.type):
                        values = pc.dictionary_encode(values)
                        if len(values.dictionary) > 2 ** (field.type.index_type.bit_width - 1):
                            fits = False
                            break
                        indices = pc.cast(values.indices, field.type.index_type)
                        values = pa.DictionaryArray.from_arrays(indices, values.dictionary)
                    arrays.append(values)
                if fits:
                    break
                count //= 2
                if count < 1:
                    raise ValueError("Dictionary cannot fit")
            writer.write_batch(pa.RecordBatch.from_arrays(arrays, schema=schema))
            sizes.append(count)
            offset += count
    offset = 0
    with pa.memory_map(str(pending), "r") as memory:
        for batch in pa.ipc.open_stream(memory):
            for name in schema.names:
                expected = decoded(original.column(name).slice(offset, batch.num_rows))
                if not decoded(batch.column(name)).equals(expected):
                    raise ValueError(f"Column differs: {name}, row {offset}")
            offset += batch.num_rows
    if offset != original.num_rows or digest(source) != original_hash:
        raise ValueError("Input or row coverage changed")
    pending.rename(destination)
    report = dict(input=str(source), output=str(destination), input_sha256=original_hash,
                  output_sha256=digest(destination), rows=offset, batches=len(sizes),
                  min_batch=min(sizes), max_batch=max(sizes), input_bytes=source.stat().st_size,
                  output_bytes=destination.stat().st_size, seconds=time.monotonic() - started,
                  pyarrow=pa.__version__, compression=None)
    destination.with_suffix(".packing.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: pack_stream.py INPUT_ARROW NEW_OUTPUT_ARROW")
    print(json.dumps(pack(*sys.argv[1:])), flush=True)
