# Vesuvius TIFXYZ Safety Gate

A small, auditable safety layer for Vesuvius Challenge TIFXYZ workflows.

It addresses two currently open failure modes in `ScrollPrize/villa`:

- [`#1379`](https://github.com/ScrollPrize/villa/issues/1379): inverted `scale` metadata makes `vc_flatten` request a **361,753 × 303,196** point grid—**1,316,184,751,056 bytes** for the `cv::Vec3f` matrix alone—before OpenCV fails out of memory.
- [`#1320`](https://github.com/ScrollPrize/villa/issues/1320): `vc_obj2tifxyz` may rasterize **zero valid points**, save a sentinel-only TIFXYZ package, print success, and exit 0.

This repository contributes two complementary pieces:

1. **`tifxyz-safety`**, a Python CLI that audits TIFXYZ metadata against the coordinate grids, forecasts `vc_flatten` allocations, and writes a validated repaired copy without modifying the source.
2. **An upstream-ready C++ patch** that adds a configurable output-pixel budget to `vc_flatten` and makes zero-point `vc_obj2tifxyz` conversions fail loudly.

This is an engineering contribution for the Vesuvius Challenge Progress Prize. It does **not** claim to unwrap a scroll, detect ink, or read new text.

## Reproduced result

Using the published numbers from issue #1379:

| Metadata | Predicted grid | Point-grid allocation | Result |
|---|---:|---:|---|
| Published `scale=[19.997318…, 19.996687…]` | 361,753 × 303,196 | 1,316,184,751,056 bytes (1,225.79 GiB) | rejected before allocation |
| Correct reciprocal convention `scale=[0.05, 0.05]` | 906 × 760 | 8,262,720 bytes (7.88 MiB) | accepted |

The automated test suite asserts the exact recorded dimensions and byte count.

## Install

Python 3.10 or newer is required.

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
pytest
```

Runtime dependencies are only NumPy and tifffile.

## Use

### Audit a TIFXYZ directory

```bash
tifxyz-safety audit /path/to/tifxyz --json audit.json --fail-on-warning
```

The audit checks:

- readable, two-dimensional `x.tif`, `y.tif`, and `z.tif` with matching shapes;
- portable-valid vertices: finite coordinates, no `(-1,-1,-1)` sentinel, and `z > 0`;
- empty/sentinel-only packages;
- declared versus measured bounding box;
- directional adjacent-grid spacing;
- the TIFXYZ `scale` convention: grid cells per voxel, so expected voxel step is `1 / scale`;
- a conservative reciprocal-inversion signature; and
- SHA-256 identity of all coordinate grids.

Exit code is 2 for errors, and also for warnings when `--fail-on-warning` is supplied.

### Forecast `vc_flatten` before allocation

```bash
tifxyz-safety flatten-plan \
  --uv-range-x 18090 \
  --uv-range-y 15162.22 \
  --scale-x 19.997318267822266 \
  --scale-y 19.996686935424805
```

The default budget is 500,000,000 output pixels. The command reports exact grid dimensions, pixel count, `cv::Vec3f` bytes, GiB, and a safe/unsafe decision. It never allocates the predicted grid.

### Write a repaired copy

```bash
tifxyz-safety repair /path/to/source /path/to/repaired --json repair.json
```

Repair is intentionally conservative:

- in-place mutation is disabled;
- coordinate TIFFs are copied byte-for-byte;
- bbox is recomputed from valid coordinates;
- scale is changed automatically only when the reciprocal-inversion signature is strong;
- a generic spacing mismatch requires explicit `--force-scale`;
- all unrelated metadata is preserved;
- source coordinate hashes and every change are recorded in `meta.json` and `repair_manifest.json`;
- the output is re-audited; if errors remain, the destination is deleted.

## Why this does not duplicate TIFXYZ Doctor

[TIFXYZ Doctor](https://github.com/aviad12g/tifxyz-doctor) is a broader, read-only diagnostics project. This contribution deliberately stays narrow and fills a different gap:

- **transactional, provenance-preserving repair** rather than diagnostics alone;
- **pre-allocation forecasting** for `vc_flatten`; and
- an **upstream fail-loud C++ patch** for the two open tool failures.

The projects can be used together: diagnose broadly with TIFXYZ Doctor, then use this tool only for the narrow repairable metadata contract.

## Evidence

- `tests/`: eight deterministic tests, including exact issue #1379 allocation reproduction and zero-vertex handling.
- `validation/`: captured test output, allocation plans, a synthetic TIFXYZ repair transcript, and a standalone C++ guard test.
- `patches/villa-tifxyz-fail-loud.patch`: proposed changes against the current `ScrollPrize/villa` paths.
- `docs/EVIDENCE.md`: claim-by-claim evidence and limitations.

## Upstream patch scope

The patch proposes:

- `ABFConfig::maxOutputPixels`, default 500,000,000;
- overflow-, integer-range-, and pixel-budget checks before constructing the flattened `cv::Mat`;
- `vc_flatten --max-output-pixels` for an explicit override;
- a diagnostic that points maintainers to the reciprocal `scale` convention;
- nonzero failure when `vc_obj2tifxyz` rasterizes no points; and
- corrected help wording for the default UV-metric mode.

The C++ allocation math is covered by a dependency-free reference test. Full Villa integration compilation is not claimed here because the complete OpenCV/OpenABF build environment was not available in this execution environment.

## Test status

```text
8 passed
```

See `validation/pytest.txt` and `validation/cpp_allocation_guard.txt`.

## License

MIT. See `LICENSE`.
