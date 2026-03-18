Offline math utilities for `packages/predict`.

This folder is for reproducibility and research artifacts only. Files here are not
part of the Move package build or test surface.

Current contents:
- `generate_cdf_coefficients.py`: regenerates the hardcoded `ln` and
  `normal_cdf` constants embedded in
  `packages/predict/sources/helper/math_optimized.move`.

Usage:
```bash
python research/predict_math/generate_cdf_coefficients.py
```
