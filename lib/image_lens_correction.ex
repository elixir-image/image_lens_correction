defmodule Image.LensCorrection do
  @moduledoc """
  Lens corrections for images coming from `Image`/`Vix.Vips`.

  Distortion, vignetting and (in future) chromatic aberration corrections
  for camera lenses, with calibration coefficients sourced from the
  [lensfun](https://github.com/lensfun/lensfun) project.

  Three distortion models are supported:

  * `:ptlens` — `Rd = Ru * (a*Ru³ + b*Ru² + c*Ru + d)` with `d = 1 - a - b - c`.
  * `:poly3`  — `Rd = Ru * (1 - k1 + k1*Ru²)` (Hugin convention).
  * `:poly5`  — `Rd = Ru * (1 + k1*Ru² + k2*Ru⁴)`.

  All radii are expressed in the Hugin convention where `r = 1` corresponds
  to the half short-edge of a 3:2 sensor at the calibration crop factor.

  Vignetting follows the lensfun "pa" model:

  * `Cd = Cs * (1 + k1*r² + k2*r⁴ + k3*r⁶)` where `r = 1` at the image corner.

  See `Image.LensFun` for database lookup, focal-length interpolation
  and EXIF resolution of calibration parameters, and
  `Image.LensFun.Correct.correct/2` for the database-driven, EXIF-aware
  one-call wrapper.

  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation, as: Operation
  alias Image.Complex, as: Complex

  @newton_iterations 6

  @doc """
  Apply the ptlens distortion correction to an image.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  * `a`, `b`, `c` are the lens-specific Hugin-form distortion coefficients
    typically sourced from the [lensfun](https://github.com/lensfun/lensfun)
    database. The implicit fourth coefficient `d` is computed as
    `d = 1 - a - b - c` so that `r = 1` is invariant.

  ### Returns

  * `{:ok, undistorted_image}` or
  * `{:error, reason}`

  ### Examples

        iex> image = Image.open!("./test/support/images/gridlines_barrel.png")
        iex> {:ok, _} = Image.LensCorrection.radial_distortion_correction(image, -0.007715, 0.086731, 0.0)

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec radial_distortion_correction(
          image :: Vimage.t(),
          a :: number(),
          b :: number(),
          c :: number()
        ) :: {:ok, Vimage.t()} | {:error, term()}

  def radial_distortion_correction(%Vimage{} = image, a, b, c)
      when is_number(a) and is_number(b) and is_number(c) do
    apply_radial(image, {:ptlens, %{a: a, b: b, c: c}})
  end

  @doc """
  Apply the poly3 distortion correction to an image.

  Implements the Hugin poly3 model `Rd = Ru * (1 - k1 + k1*Ru²)`.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.
  * `k1` is the lens-specific quadratic coefficient.

  ### Returns

  * `{:ok, undistorted_image}` or `{:error, reason}`.

  ### Examples

        iex> image = Image.open!("./test/support/images/gridlines_barrel.png")
        iex> {:ok, _} = Image.LensCorrection.poly3_correction(image, -0.005)

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec poly3_correction(image :: Vimage.t(), k1 :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def poly3_correction(%Vimage{} = image, k1) when is_number(k1) do
    apply_radial(image, {:poly3, %{k1: k1}})
  end

  @doc """
  Apply the poly5 distortion correction to an image.

  Implements `Rd = Ru * (1 + k1*Ru² + k2*Ru⁴)`.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.
  * `k1`, `k2` are the lens-specific Hugin poly5 coefficients.

  ### Returns

  * `{:ok, undistorted_image}` or `{:error, reason}`.

  ### Examples

        iex> image = Image.open!("./test/support/images/gridlines_barrel.png")
        iex> {:ok, _} = Image.LensCorrection.poly5_correction(image, -0.005, 0.001)

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec poly5_correction(image :: Vimage.t(), k1 :: number(), k2 :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def poly5_correction(%Vimage{} = image, k1, k2) when is_number(k1) and is_number(k2) do
    apply_radial(image, {:poly5, %{k1: k1, k2: k2}})
  end

  @doc """
  Apply a distortion correction described by a parameter map.

  This is the lensfun-shaped form used by `Image.LensFun.interpolate_distortion/2`:

      %{model: :ptlens | :poly3 | :poly5, terms: %{...}}

  ### Returns

  * `{:ok, image}` or `{:error, reason}`.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec apply_distortion(image :: Vimage.t(), distortion :: map()) ::
          {:ok, Vimage.t()} | {:error, term()}

  def apply_distortion(%Vimage{} = image, %{model: :ptlens, terms: %{a: a, b: b, c: c}}) do
    radial_distortion_correction(image, a, b, c)
  end

  def apply_distortion(%Vimage{} = image, %{model: :poly3, terms: %{k1: k1}}) do
    poly3_correction(image, k1)
  end

  def apply_distortion(%Vimage{} = image, %{model: :poly5, terms: %{k1: k1, k2: k2}}) do
    poly5_correction(image, k1, k2)
  end

  def apply_distortion(_image, distortion) do
    {:error, {:unsupported_distortion_model, distortion}}
  end

  @doc """
  Apply a vignetting correction to an image.

  Implements the inverse of the lensfun "pa" model
  `Cd = Cs * (1 + k1*r² + k2*r⁴ + k3*r⁶)` where `r = 1` corresponds to
  the corner of the image.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  * `k1`, `k2`, `k3` are the lens-specific vignetting coefficients,
    typically interpolated from `Image.LensFun.interpolate_vignetting/4`.

  ### Returns

  * `{:ok, unvignetted_image}` or `{:error, reason}`.

  ### Examples

        iex> image = Image.new!(200, 200, color: :green)
        iex> {:ok, _} = Image.LensCorrection.vignette_correction(image, -0.2764, -1.26031, 0.7727)

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec vignette_correction(
          image :: Vimage.t(),
          k1 :: number(),
          k2 :: number(),
          k3 :: number()
        ) :: {:ok, Vimage.t()} | {:error, term()}

  def vignette_correction(%Vimage{} = image, k1, k2, k3)
      when is_number(k1) and is_number(k2) and is_number(k3) do
    use Image.Math

    format = Image.band_format(image)
    width = Image.width(image)
    height = Image.height(image)

    centre_x = (width - 1) / 2
    centre_y = (height - 1) / 2

    # Distance from image centre to the corner -- the lensfun "pa" model
    # places r = 1 at the corner.
    corner_radius = :math.sqrt(centre_x * centre_x + centre_y * centre_y)

    index = Operation.xyz!(width, height) - [centre_x, centre_y]
    r = Complex.polar!(index)[0] / corner_radius

    r2 = r ** 2
    r4 = r2 ** 2
    r6 = r4 * r2

    multiplier = 1.0 + k1 * r2 + k2 * r4 + k3 * r6
    Image.cast(image / multiplier, format)
  end

  @doc """
  Apply a vignetting correction described by a lensfun-shaped parameter map.

  Accepts the output of `Image.LensFun.interpolate_vignetting/4`:

      %{model: :pa, terms: %{k1: ..., k2: ..., k3: ...}}

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec apply_vignetting(image :: Vimage.t(), vignetting :: map()) ::
          {:ok, Vimage.t()} | {:error, term()}

  def apply_vignetting(%Vimage{} = image, %{model: :pa, terms: %{k1: k1, k2: k2, k3: k3}}) do
    vignette_correction(image, k1, k2, k3)
  end

  def apply_vignetting(_image, vignetting) do
    {:error, {:unsupported_vignetting_model, vignetting}}
  end

  @doc """
  Rescale calibration coefficients from one crop factor / aspect ratio to
  another.

  Implements the same crop/aspect/focal adjustment as lensfun's
  `rescale_polynomial_coefficients` (`mod-coord.cpp`). The returned terms
  are still in the Hugin coordinate system (so the existing
  `radial_distortion_correction/4`, `poly3_correction/2` and
  `poly5_correction/3` functions consume them directly), but compensated
  for the difference between the calibration sensor and the camera the
  image was taken on.

  ### Arguments

  * `distortion` is a `%{model:, terms:, focal_length:, real_focal:}` map
    as produced by `Image.LensFun.interpolate_distortion/2`.

  * `calib_crop_factor` is the crop factor of the lens calibration set.

  * `calib_aspect_ratio` is its aspect ratio (width / height, defaults
    to `1.5`).

  * `image_crop_factor` is the crop factor of the camera the image was
    captured on.

  ### Returns

  * `{:ok, %{model:, terms:, focal_length:, real_focal:}}` with rescaled
    `terms`.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec rescale_coefficients(map(), number(), number(), number()) :: {:ok, map()}
  def rescale_coefficients(distortion, calib_crop_factor, calib_aspect_ratio, image_crop_factor)
      when is_number(calib_crop_factor) and is_number(image_crop_factor) do
    aspect = calib_aspect_ratio || 1.5

    real_focal =
      case Map.get(distortion, :real_focal) do
        nil -> Map.fetch!(distortion, :focal_length)
        rf -> rf
      end

    hugin_scale =
      :math.sqrt(36.0 * 36.0 + 24.0 * 24.0) / calib_crop_factor /
        :math.sqrt(aspect * aspect + 1.0) / 2.0

    hugin_scaling = real_focal / hugin_scale

    crop_ratio = calib_crop_factor / image_crop_factor

    scale = hugin_scaling * crop_ratio

    new_terms =
      case distortion do
        %{model: :ptlens, terms: %{a: a, b: b, c: c}} ->
          d = 1.0 - a - b - c

          %{
            a: a * :math.pow(scale, 3) / :math.pow(d, 4),
            b: b * :math.pow(scale, 2) / :math.pow(d, 3),
            c: c * scale / :math.pow(d, 2)
          }

        %{model: :poly3, terms: %{k1: k1}} ->
          d = 1.0 - k1
          %{k1: k1 * :math.pow(scale, 2) / :math.pow(d, 3)}

        %{model: :poly5, terms: %{k1: k1, k2: k2}} ->
          %{
            k1: k1 * :math.pow(scale, 2),
            k2: k2 * :math.pow(scale, 4)
          }
      end

    {:ok, %{distortion | terms: new_terms}}
  end

  ## Internal — radial distortion engine

  # Build the Vips coordinate map common to all radial models, then
  # delegate to a model-specific Newton iteration.
  defp apply_radial(%Vimage{} = image, {model, terms}) do
    use Image.Math

    width = Image.width(image)
    height = Image.height(image)

    radius = min(width / 1, height / 1) / 2.0
    centre_x = (width - 1) / 2.0
    centre_y = (height - 1) / 2.0

    delta = (Operation.xyz!(width, height) - [centre_x, centre_y]) / radius
    rd = Complex.polar!(delta)[0]

    factor =
      case model do
        :ptlens -> ptlens_inverse_factor(rd, terms.a, terms.b, terms.c)
        :poly3 -> poly3_inverse_factor(rd, terms.k1)
        :poly5 -> poly5_inverse_factor(rd, terms.k1, terms.k2)
      end

    transform = [centre_x, centre_y] + delta * factor * radius
    Operation.mapim(image, transform)
  end

  # ptlens forward: Rd = Ru * (a*Ru³ + b*Ru² + c*Ru + d), d = 1-a-b-c
  # Solve for Ru via Newton. Return Ru/Rd (the radial factor).
  defp ptlens_inverse_factor(rd, a, b, c) do
    use Image.Math
    d = 1.0 - a - b - c

    ru =
      Enum.reduce(1..@newton_iterations, rd, fn _i, ru ->
        ru2 = ru ** 2
        ru3 = ru2 * ru
        ru4 = ru2 * ru2
        f = a * ru4 + b * ru3 + c * ru2 + d * ru - rd
        fp = 4.0 * a * ru3 + 3.0 * b * ru2 + 2.0 * c * ru + d
        ru - f / fp
      end)

    safe_ratio(ru, rd)
  end

  # poly3 forward: Rd = Ru * (1 - k1 + k1*Ru²) = (1-k1)*Ru + k1*Ru³
  defp poly3_inverse_factor(rd, k1) do
    use Image.Math
    d = 1.0 - k1

    ru =
      Enum.reduce(1..@newton_iterations, rd, fn _i, ru ->
        ru2 = ru ** 2
        f = k1 * ru2 * ru + d * ru - rd
        fp = 3.0 * k1 * ru2 + d
        ru - f / fp
      end)

    safe_ratio(ru, rd)
  end

  # poly5 forward: Rd = Ru * (1 + k1*Ru² + k2*Ru⁴)
  defp poly5_inverse_factor(rd, k1, k2) do
    use Image.Math

    ru =
      Enum.reduce(1..@newton_iterations, rd, fn _i, ru ->
        ru2 = ru ** 2
        ru4 = ru2 * ru2
        f = ru * (1.0 + k1 * ru2 + k2 * ru4) - rd
        fp = 1.0 + 3.0 * k1 * ru2 + 5.0 * k2 * ru4
        ru - f / fp
      end)

    safe_ratio(ru, rd)
  end

  # Avoid divide-by-zero at the image centre by pinning rd to a tiny
  # value where it would otherwise be 0.
  defp safe_ratio(ru, rd) do
    use Image.Math
    is_zero = Operation.relational_const!(rd, :VIPS_OPERATION_RELATIONAL_EQUAL, [0.0])
    safe_rd = is_zero * 1.0e-12 + rd
    ru / safe_rd
  end
end
