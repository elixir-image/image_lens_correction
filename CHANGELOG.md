# Changelog

## ImageLensCorrection 0.1.0

This is the initial release of `ImageLensCorrection`, a lens-correction companion package for [`:image`](https://hex.pm/packages/image).

### Features

* **Radial distortion correction** for the lensfun `:ptlens`, `:poly3` and `:poly5` models. Each model is inverted per pixel via six iterations of Newton's method evaluated as `libvips` arithmetic on the radius image — no per-pixel branching, no NIF callouts. Standalone entry points `Image.LensCorrection.radial_distortion_correction/4`, `Image.LensCorrection.poly3_correction/2` and `Image.LensCorrection.poly5_correction/3`, plus `Image.LensCorrection.apply_distortion/2` for the lensfun-shaped `%{model:, terms:}` map.

* **Vignetting correction** via the lensfun `:pa` model, inverted analytically. `Image.LensCorrection.vignette_correction/4` takes raw `k1, k2, k3`; `Image.LensCorrection.apply_vignetting/2` accepts the interpolated map.

* **Lateral chromatic aberration (TCA) correction** via the lensfun `:linear` and `:poly3` models. `Image.LensCorrection.Tca` decomposes the input into bands, remaps the red and blue channels per channel, leaves green as the reference, and rejoins. RGBA inputs preserve their alpha channel.

* **Geometric projection** between `:rectilinear`, `:fisheye` and `:equirectangular` projections, plus a `Image.LensCorrection.Geometry.focal_length_in_pixels/3` helper that derives the pixel focal length from the focal length in millimetres, the camera's crop factor and the image's diagonal.

* **EXIF-driven correction pipeline** — `Image.LensFun.Correct.correct/2` reads the camera and lens identification, focal length, aperture and (where available) focus distance from the input image's EXIF metadata, looks the lens up in the bundled lensfun database, interpolates the calibration to the image's focal length and aperture, rescales coefficients to the camera's crop factor and applies all enabled corrections in one pipeline. Every parameter is overridable via options for images that lack EXIF metadata.

* **Bundled lensfun database** — `priv/lensfun/lensfun.etf` (~5 MB) covers 1013 camera bodies and 1459 lens calibration sets across the lensfun XML database. Decoded once into a `:persistent_term` cache on first use. Rebuildable from a lensfun checkout via `Image.LensFun.Importer.import/1`.

* **Database lookup primitives** — `Image.LensFun.find_lens/3` (case-insensitive maker matching, fuzzy substring fallback for the model, optional crop-factor narrowing), `Image.LensFun.find_camera/2`, `Image.LensFun.interpolate_distortion/2` (Catmull-Rom Hermite spline matching lensfun's `lfLens::InterpolateDistortion`), `Image.LensFun.interpolate_vignetting/4` (inverse-distance weighting over focal length, aperture and focus distance with `p = 3.5`, matching lensfun's `lfLens::InterpolateVignetting`), `Image.LensFun.interpolate_tca/2`, and `Image.LensFun.metrics_from_exif_and_options/2` for unified EXIF + options metric resolution.

* **Coefficient rescaling** — `Image.LensCorrection.rescale_coefficients/4` implements lensfun's `rescale_polynomial_coefficients` so calibration coefficients can be applied to images captured on a different sensor than the one the lens was calibrated against.

* **Database lens search** — `Image.LensFun.search_lenses/2` performs free-form, word-by-word, case-insensitive lookup across the bundled database with `:maker`, `:limit` and `:has` (capability) filters.

### Notes

* The Adobe Camera Model (`acm`) variants of the lensfun distortion, vignetting and TCA models are not supported. As of the current lensfun release no calibration record in the upstream XML database uses `acm`, and upstream lensfun itself does not implement reverse ACM correction. `apply_distortion/2`, `apply_vignetting/2` and `Tca.apply_tca/2` return a clear `{:error, {:unsupported_*_model, ...}}` tuple if given an ACM map.
