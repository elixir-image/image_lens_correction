# ImageLensCorrection

`ImageLensCorrection` provides corrections for the four most common camera-lens defects — radial (barrel/pincushion) distortion, vignetting, lateral chromatic aberration (TCA), and geometric projection — for images created or processed with the [`:image`](https://hex.pm/packages/image) library. Calibration coefficients come from the [`lensfun`](https://github.com/lensfun/lensfun) project's community-maintained database, which is bundled with the package as a compact ~5 MB Erlang term file covering 1000+ camera bodies and 1400+ lenses.

Corrections are evaluated as `libvips` arithmetic expressions on top of `Vix`, so every correction stays inside the Vix pipeline; no external C library is required at runtime.

Documentation can be found at <https://hexdocs.pm/image_lens_correction>.

## Features

* **Radial distortion correction** — implements the lensfun `:ptlens`, `:poly3` and `:poly5` models, all inverted per pixel via Newton's method evaluated as `libvips` arithmetic.

* **Vignetting correction** — implements the lensfun `:pa` model `Cd = Cs * (1 + k1*r² + k2*r⁴ + k3*r⁶)`, inverted analytically.

* **Lateral chromatic aberration (TCA)** — implements the lensfun `:linear` and `:poly3` TCA models. The image is decomposed into bands, red and blue are remapped per channel via `mapim`, green is taken as the reference, and RGBA inputs preserve their alpha channel.

* **Geometric projection** — converts between `:rectilinear`, `:fisheye` and `:equirectangular` projections.

* **EXIF-driven, one-call correction** — `Image.LensFun.Correct.correct/2` reads camera and lens metadata from the image's EXIF tags, looks the lens up in the bundled database, interpolates the calibration to the image's focal length and aperture, rescales coefficients to the camera's crop factor, and applies the requested corrections in one pipeline. Every EXIF tag is overridable via options for images that lack metadata.

* **Database lookup primitives** — `Image.LensFun.find_lens/3`, `Image.LensFun.find_camera/2`, `Image.LensFun.interpolate_distortion/2`, `Image.LensFun.interpolate_vignetting/4` and `Image.LensFun.interpolate_tca/2` for direct programmatic access to the bundled calibration data, with case-insensitive maker matching, fuzzy-substring lens-model matching and crop-factor-narrowing.

* **Bundled calibration database** — `priv/lensfun/lensfun.etf` is generated from the lensfun XML database at build time and decoded once into a `:persistent_term` cache on first use.

## Installation

The package can be installed by adding `image_lens_correction` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:image_lens_correction, "~> 0.1.0"}
  ]
end
```

## Usage

### One-shot correction from EXIF

For an image whose EXIF metadata identifies the camera and lens, all available corrections (distortion, vignetting and TCA) can be applied with a single call:

```elixir
{:ok, image}     = Image.open("photo.jpg")
{:ok, corrected} = Image.LensFun.Correct.correct(image)
```

For an image without complete EXIF metadata, supply the missing parameters as options. Every parameter that `correct/2` reads from EXIF is overridable:

```elixir
{:ok, corrected} =
  Image.LensFun.Correct.correct(image,
    make: "Canon",
    model: "Canon EOS 5D Mark III",
    lens_make: "Canon",
    lens_model: "Canon EF 100mm f/2.8 Macro USM",
    focal_length: 100.0,
    aperture: 5.6
  )
```

The `:corrections` option selects which corrections to run; the default is `[:distortion, :vignetting, :tca]`. Projection conversion is opt-in (since it changes the field of view) via `corrections: [:projection]` and an optional `:target_projection`.

### Direct correction with explicit coefficients

When you have your own calibration data — or you're experimenting — each model is exposed as a standalone function that takes raw coefficients in the Hugin coordinate convention (`r = 1` at the half short-edge for distortion / TCA / projection, `r = 1` at the corner for vignetting):

```elixir
# ptlens distortion (Hugin form)
{:ok, image} = Image.LensCorrection.radial_distortion_correction(image, -0.0077, 0.087, 0.0)

# poly3 distortion
{:ok, image} = Image.LensCorrection.poly3_correction(image, -0.005)

# poly5 distortion
{:ok, image} = Image.LensCorrection.poly5_correction(image, -0.005, 0.001)

# Vignetting (Adobe Camera Model "pa")
{:ok, image} = Image.LensCorrection.vignette_correction(image, -0.2764, -1.26031, 0.7727)

# Linear TCA
{:ok, image} = Image.LensCorrection.Tca.linear_tca_correction(image, 1.0004, 1.0002)

# Fisheye → rectilinear
focal = Image.LensCorrection.Geometry.focal_length_in_pixels(8.0, 1.5, 5000.0)
{:ok, image} = Image.LensCorrection.Geometry.fisheye_to_rectilinear(image, focal)
```

### Database lookup

```elixir
# Find a lens (case-insensitive maker, fuzzy-substring model)
{:ok, lens} = Image.LensFun.find_lens("Canon", "Canon EF 100mm f/2.8 Macro USM")

# Interpolate the calibration to a specific focal length
{:ok, distortion} = Image.LensFun.interpolate_distortion(lens, 100.0)

# Vignetting needs focal length, aperture and focus distance
{:ok, vignetting} = Image.LensFun.interpolate_vignetting(lens, 100.0, 5.6, 1000.0)

# TCA needs focal length only
{:ok, tca} = Image.LensFun.interpolate_tca(lens, 100.0)

# Apply the result
{:ok, image} = Image.LensCorrection.apply_distortion(image, distortion)
{:ok, image} = Image.LensCorrection.apply_vignetting(image, vignetting)
{:ok, image} = Image.LensCorrection.Tca.apply_tca(image, tca)
```

## Background

The lens defects this library corrects, the mathematical models it uses, and the relationship to the upstream lensfun project are described in detail in the [Lens corrections guide](guides/lens_corrections.md).

## Rebuilding the bundled database

```sh
git clone https://github.com/lensfun/lensfun ../lensfun
mix run -e 'Image.LensFun.Importer.import()'
```

## Attribution

This library re-implements the calibration math and bundles a snapshot of the calibration data from [the lensfun project](https://github.com/lensfun/lensfun). Lens calibration data is distributed under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/); the lensfun reference C library is LGPL v3 (this library does not link to or distribute it).

## License

`ImageLensCorrection` is licensed under the [Apache 2.0 License](LICENSE.md).
