# Lens corrections

This guide explains the lens defects this library can correct, the
mathematical models it uses, and where the calibration data comes
from.

## What is a lens correction?

Real-world camera lenses are imperfect. Even high-end lenses
introduce a handful of optical defects whose strength depends on the
lens, the focal length, the aperture and (for vignetting) the focus
distance. The four kinds of defect this library addresses are:

* **Radial distortion** — straight lines bend outwards (barrel
  distortion) or inwards (pincushion distortion).

* **Vignetting** — pixels at the corners of the image are darker
  than pixels at the centre.

* **Lateral chromatic aberration (TCA)** — the red, green and blue
  channels focus at slightly different scales, producing coloured
  fringes around high-contrast edges.

* **Geometric projection** — fisheye, equirectangular and panoramic
  lenses record the world in non-rectilinear projections that need
  to be reprojected for normal viewing.

All four defects can be modelled as small radial functions of pixel
position, and all four can be undone by sampling the source image
at a slightly different position than the destination — exactly
what `libvips`' `mapim` operation does.

## The lensfun project

[Lensfun](https://github.com/lensfun/lensfun) is a community-driven
database of camera and lens calibration data, plus a reference C
library that consumes it. The project ships an XML database covering
1000+ camera bodies and 1400+ lenses, with calibration coefficients
contributed by photographers using the
[`hugin`](http://hugin.sourceforge.net/) calibration toolchain.

This library:

* Imports the lensfun XML database into a compact Erlang term file
  (`priv/lensfun/lensfun.etf`, ~5&nbsp;MB) at build time.

* Re-implements the lensfun correction math in Elixir on top of
  `libvips`' arithmetic and `mapim` operations, so corrections run
  inside the Vix pipeline rather than calling out to a C library.

* Reproduces lensfun's coordinate conventions, Newton-iteration
  inversion, Hermite-spline focal-length interpolation and
  inverse-distance vignetting interpolation faithfully enough that
  results match the reference C library to floating-point precision
  for typical inputs.

The bundled database and the math originate with lensfun; please
attribute the lensfun project (see the **Attribution** section
below) when you redistribute corrected images or republish the
calibration data.

## Coordinate conventions

The library and the lensfun database share the
[Hugin coordinate convention](http://wiki.panotools.org/Lens_correction_model)
for radial coordinates:

* The origin is the centre of the image.

* For distortion, TCA and projection: `r = 1` corresponds to the
  half short-edge of a 3:2 sensor at the calibration crop factor.

* For vignetting (lensfun's `:pa` model): `r = 1` corresponds to
  the corner of the image (i.e. `r` is normalised by the half
  diagonal).

When you obtain coefficients from the database via
`Image.LensFun.find_lens/3` they are in the calibration's
coordinate frame. `Image.LensCorrection.rescale_coefficients/4`
rescales them into the **target image**'s coordinate frame,
accounting for crop-factor and aspect-ratio differences between
the calibration sensor and the camera that captured the image.

## Distortion models

Lensfun defines three radial-distortion models, all inverses of a
forward polynomial mapping `Ru → Rd`:

| Model    | Forward formula                                                      | Coefficients |
| -------- | -------------------------------------------------------------------- | ------------ |
| `ptlens` | `Rd = Ru * (a*Ru³ + b*Ru² + c*Ru + d)` with `d = 1 − a − b − c`      | `a, b, c`    |
| `poly3`  | `Rd = Ru * (1 − k1 + k1*Ru²)`                                        | `k1`         |
| `poly5`  | `Rd = Ru * (1 + k1*Ru² + k2*Ru⁴)`                                    | `k1, k2`     |

To undistort an image we solve the polynomial for `Ru` given each
destination `Rd`. There is no closed-form inverse so the library
uses six iterations of Newton's method, evaluated as a sequence of
`libvips` arithmetic operations on the radius image — the same
approach lensfun uses internally per pixel.

## Vignetting

Lensfun's `:pa` (Adobe Camera Model) vignetting model expresses the
recorded brightness as a polynomial in radial distance:

    Cd = Cs * (1 + k1*r² + k2*r⁴ + k3*r⁶)

with `r = 1` at the image corner. Correction is the analytic
inverse — divide each pixel by the polynomial — and is implemented
as a single `libvips` arithmetic expression with no per-pixel
iteration.

Because vignetting depends on the **aperture** as well as the
focal length, calibration sets generally contain many vignetting
records per lens. `Image.LensFun.interpolate_vignetting/4` uses
inverse-distance weighting (with power 3.5, matching lensfun) over
focal length, aperture and focus distance.

## Lateral chromatic aberration (TCA)

TCA shifts the red and blue channels radially relative to the
green channel. Lensfun supports two TCA models:

| Model    | Formula (per channel)                          | Coefficients         |
| -------- | ----------------------------------------------- | -------------------- |
| `linear` | `Rd = k * Ru`                                   | `kr, kb`             |
| `poly3`  | `Rd = Ru * (b * Ru² + c * Ru + v)`              | `vr, vb, cr, cb, br, bb` |

The library splits the input into bands, remaps red and blue with
their own `mapim` calls, leaves green unchanged, and rejoins. RGBA
inputs preserve their alpha channel from the green band's
geometry. The poly3 inverse uses the same six-iteration Newton
solver as the radial distortion code.

## Geometric projection

Some lenses — fisheyes, panoramic stitches, equirectangular
panoramas — record the world in a non-rectilinear projection.
Converting between projections is a coordinate-only
transformation; the lens-specific calibration is just the focal
length expressed in pixels.

The library currently supports:

| From               | To                  |
| ------------------ | ------------------- |
| `:fisheye`         | `:rectilinear`      |
| `:rectilinear`     | `:fisheye`          |
| `:equirectangular` | `:rectilinear`      |
| `:rectilinear`     | `:equirectangular`  |

`Image.LensCorrection.Geometry.focal_length_in_pixels/3` derives
the pixel focal length from the focal length in millimetres, the
camera's crop factor and the image's diagonal.

## EXIF-driven correction

`Image.LensFun.Correct.correct/2` reads the relevant EXIF tags
(`make`, `model`, `lens_make`, `lens_model`, `focal_length`,
`f_number`) from the input image, looks the lens up in the
bundled database, interpolates the calibration to the image's
focal length and aperture, rescales coefficients to the camera's
crop factor, and applies the requested corrections in turn.

Each EXIF tag can be overridden by a corresponding option, so
images that carry partial or stripped metadata can still be
corrected:

```elixir
{:ok, corrected} =
  Image.LensFun.Correct.correct(image,
    lens_make: "Canon",
    lens_model: "Canon EF 100mm f/2.8 Macro USM",
    focal_length: 100.0,
    aperture: 5.6
  )
```

The `:corrections` option selects which corrections to run; the
default is `[:distortion, :vignetting, :tca]`. Projection is
opt-in via `corrections: [:projection]` (with an optional
`:target_projection`) because converting projections changes the
field of view.

## Building the database

The bundled `priv/lensfun/lensfun.etf` is generated from the
lensfun XML database by `Image.LensFun.Importer.import/1`.

To rebuild it (for example to pick up new lens calibrations):

```sh
git clone https://github.com/lensfun/lensfun ../lensfun
mix run -e 'Image.LensFun.Importer.import()'
```

The importer reads `data/db/*.xml` from the lensfun checkout,
extracts camera bodies, lenses, distortion, vignetting and TCA
records, normalises them into a uniform map structure, deep-merges
records that share a maker across files, and writes the result to
`priv/lensfun/lensfun.etf`.

## Attribution

The lensfun project (and this library) gratefully relies on
calibration data contributed by photographers. When you use the
bundled database — directly or through `correct/2` — please
attribute lensfun:

> Calibration data from [the lensfun project][lensfun],
> distributed under [CC BY-SA 3.0][cc-by-sa].

[lensfun]: https://github.com/lensfun/lensfun
[cc-by-sa]: https://creativecommons.org/licenses/by-sa/3.0/

The mathematical models and coordinate conventions used in this
library are direct ports of the lensfun reference C
implementation (`libs/lensfun/mod-coord.cpp`, `mod-color.cpp` and
`mod-subpix.cpp`). Bug-for-bug parity with that implementation is
a non-goal but interpretation parity is intentional and welcome
to be reported as an issue.

The lensfun reference library is licensed under the LGPL v3.
This library does not link to or distribute the lensfun C
library; it re-implements the math in Elixir under the
[Apache 2.0 license](../LICENSE.md).

## Unsupported models

The lensfun database also defines an Adobe Camera Model (`acm`)
variant for distortion, vignetting and TCA. As of the current
lensfun release the ACM model is **not** used by any calibration
record in the upstream XML database, and the lensfun reference
library itself does not implement reverse ACM correction
(`mod-coord.cpp` warns `acm distortion model is not yet
implemented for reverse correction`). This library follows
upstream and does not implement ACM either; if you supply an
`%{model: :acm, ...}` map to `Image.LensCorrection.apply_distortion/2`,
`apply_vignetting/2` or `Tca.apply_tca/2` it returns
`{:error, {:unsupported_distortion_model, _}}` (or the
analogous `:unsupported_vignetting_model` /
`:unsupported_tca_model`).
