# Changelog

## v0.2.0 – 2025‑07‑17

### Breaking ⚠️

- `Memory.aligned_alloc` argument order reversed to (alignment, size).
- Constant `SPSC_STORAGE_BUFFER_OFFSET` renamed to `SPSC_BUFFER_OFFSET`.
- SPSC shared‑memory layout redesigned (adds `SPSC_MAGIC`, `SPSC_ABI_VERSION = 1`, and `msg_count`);
  queues from ≤ v0.1.x are incompatible and must be recreated.
- `max_payload_size(queue)` now excludes the 8‑byte size header.

### Added

- `length(queue)` returns O(1) message count via new `msg_count`.
- Constants: `SPSC_CACHE_LINE_SIZE`, `SPSC_MAGIC`, `SPSC_ABI_VERSION`, `SPSC_BUFFER_OFFSET`.
- New unit tests covering queue length and edge cases.

### Changed / Improved

- Robust wrap‑around handling, 8‑byte alignment, and full‑queue detection in SPSC enqueue logic.
- Extensive argument validation and clearer error messages.
- Safer PubSub shared‑memory (re)creation, clearer logging, atomic drop‑count tracking.
- README/examples updated (`aligned_alloc`, `SPSC_BUFFER_OFFSET`).

### Fixed

- Proper errors for invalid alignment (non‑power‑of‑two, too small).
- Eliminated dead‑wrap when writer meets reader at buffer end.
- Correct size‑mismatch handling when reopening shared memory.

Upgrade notes:

1. Recreate any existing SPSC shared‑memory segments with v0.2.0.
2. Replace:
   - `aligned_alloc(size, alignment)` → `aligned_alloc(alignment, size)`
   - `SPSC_STORAGE_BUFFER_OFFSET` → `SPSC_BUFFER_OFFSET`
