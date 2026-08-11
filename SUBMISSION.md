# August 2026 Vesuvius Challenge Progress Prize submission

## Title
Vesuvius TIFXYZ Safety Gate: transactional metadata repair and fail-loud allocation guards

## Submitter
Art — GitHub: `artmo87`

## Category
Engineering / data-pipeline reliability / virtual-unwrapping tooling

## Summary
This contribution addresses two open failures in the official Villa pipeline:

1. An inverted `scale` field in the published PHercParis4 `outer_shell` package causes current `vc_flatten` to request a 361,753 × 303,196 point grid, or 1,316,184,751,056 bytes before overhead.
2. `vc_obj2tifxyz` can rasterize zero valid points, save an all-sentinel TIFXYZ package, print success, and exit 0.

The repository provides a tested Python preflight for scale/bbox/spacing audit, exact allocation forecasting, and conservative copy-only metadata repair with SHA-256 provenance and post-repair validation. A locally validated upstream patch is also included in the downloadable evidence bundle prepared with this submission.

## Quantitative evidence
- Eight deterministic Python tests pass in the full validation bundle.
- Exact issue #1379 reproduction: 361,753 × 303,196 = 109,682,062,588 pixels and 1,316,184,751,056 `cv::Vec3f` bytes.
- Corrected reciprocal scale: 906 × 760 = 688,560 pixels and 8,262,720 bytes.
- The proposed default guard rejects the first before allocation and accepts the second.
- Synthetic repair validation confirms source coordinate bytes remain unchanged while the destination is re-audited successfully.

## Open-source status
MIT licensed. Source, evidence, and limitations are public.

## Upstream references
- https://github.com/ScrollPrize/villa/issues/1379
- https://github.com/ScrollPrize/villa/issues/1320
- https://github.com/ScrollPrize/villa/issues/1319

## Claim boundary
This is a Progress Prize engineering submission. It is not a Grand Prize, First Letters, ink-detection, or text-decipherment claim.
