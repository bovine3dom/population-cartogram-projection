# Remove export reduction and replacement dictionaries

## 2026-10-15: policy

The user requests removal of optional row reduction and per-batch replacement
dictionaries from the cartogram repository and H3-MON. Keep eta tuning,
ordinary lossless dictionaries, exact numeric storage, and production zstd.

Removed the importance selectors, moment-reduction solvers, worker wrapper,
reduction runners, reduced-publication path, stream packer, and their dedicated
tests. Retained metadata, quality checks, source ordering, and ordinary IPC
writers. New native source fits export every positive fitted contribution.
They reject resume attempts that use the old row-selected export policy.

Native export and publication reject old moment-packed roots. Publication
accepts audited ordinary IPC files directly. It checks headers, footers,
hashes, sizes, and matching geometry provenance. It no longer uses a stream
verification or replacement-dictionary stage.

H3-MON has no importance-based row reducer. Removed its custom per-chunk
H3 dictionary decoder and replacement-specific tests. The loader now uses
Arrow's public conversion API. Ordinary dictionary and type checks remain.
Other browser memory improvements and query-result streams are unchanged.

## Data migration

Restore the native datasets from the saved parts before optional moment
packing. Write ordinary IPC files and preserve their existing dataset URLs.
Archive prior publications outside the served tree before replacement.
Existing fit checkpoints retain their original numerical sparsification;
this migration does not refit them or claim to restore discarded solver tails.
The updated runner removes row selection from future native exports.

The preferred sharp H3-5 map already uses ordinary dictionaries and no moment
reduction. Keep it unchanged. Retire the older reduced H3-5 preview in favour
of that sharp map, with a documented compatibility copy at its previous URL.
Do not change production, UK, Germany, or automatic-cartogram datasets.

Historical benchmark logs remain historical records. They are not current
export instructions. The format reference is
https://arrow.apache.org/docs/format/Columnar.html#ipc-file-format.
IPC files do not permit replacement dictionaries; ordinary dictionaries remain
valid. No installed dependency or server compression policy is changed.
