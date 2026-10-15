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

## Validation and completed migration

The final CPU checks pass: 45 storage tests, 18 independent audit tests,
10 fitted-mapping storage tests, 17 native binary tests, 20 hierarchy tests,
and four local-transfer tests. The publisher tests pass, including five
invalid-input cases. An intermediate hierarchy test found one remaining
local-balance call to the deleted selector. Removed that call and repeated
the tests successfully. Tiny positive contributions are retained; invalid
negative weights are rejected. No GPU test competed with the unrelated fit.

H3-MON passes 67 unit tests, the actual Arrow dictionary checks, and its build.
Desktop and mobile rendering checks pass ordinary dictionaries and line probes.
All four native datasets pass headless checks with the new loader, including
three camera changes. The H3-5 compatibility map also passes. The existing
legend warning remains; no new browser error was recorded.

Installed the full saved native mappings as ordinary IPC files at the existing
URLs. The factor-2 full-reference URL now has the same files as factor 2.

| Native factor | Transport and density bytes |
| --- | ---: |
| 1 | 173,437,724 |
| 2 | 192,856,532 |
| 3 | 227,334,572 |
| 5 | 337,722,660 |

The files are larger. This is the cost of removing optional reduction and
per-batch dictionaries. The large native geographic-layer memory cost remains.
No mobile-memory safety claim is made. All input and publication hashes pass.
The preferred sharp H3-5 directory is byte-for-byte unchanged. The older H3-5
preview URL now serves a documented compatibility copy of that sharp map.

Previous publications are preserved in
`output/continuity-format-cleanup/archived-publications/`. The migration journal,
full before-and-after hashes, test logs, export scripts, and browser reports
are in `output/continuity-format-cleanup/`. No service was restarted. Production,
regional, and automatic-cartogram datasets were not changed. The unrelated
fit process was left running.
