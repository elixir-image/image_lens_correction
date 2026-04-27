defmodule Image.LensCorrection.Geometry do
  @moduledoc """
  Lens geometry / projection conversions.

  Converts an image captured under one projection to another. The
  source projections supported are:

    * `:rectilinear` — the standard pinhole projection used by most
      lenses.
    * `:fisheye` — the equidistant fisheye projection
      `r = f * θ`.
    * `:equirectangular` — the panorama projection.

  Coordinates are normalised by `focal_length_pixels`, the focal
  length of the lens expressed in pixels. The helper
  `focal_length_in_pixels/3` derives this value from the focal length
  in millimetres, the camera's crop factor and the image's diagonal in
  pixels.
  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation, as: Operation

  @sensor_diagonal_mm :math.sqrt(36.0 * 36.0 + 24.0 * 24.0)

  @doc """
  Convert focal length in millimetres to focal length in pixels for the
  current image, using the lensfun coordinate convention.

  ### Arguments

  * `focal_length_mm` is the lens focal length in millimetres.
  * `crop_factor` is the camera body crop factor.
  * `image_diagonal_pixels` is the image diagonal in pixels — the
    Pythagorean sum of width and height.

  ### Examples

      iex> f = Image.LensCorrection.Geometry.focal_length_in_pixels(8.0, 1.5, 5000.0)
      iex> Float.round(f, 2)
      1386.75
  """
  @spec focal_length_in_pixels(number(), number(), number()) :: float()
  def focal_length_in_pixels(focal_length_mm, crop_factor, image_diagonal_pixels)
      when is_number(focal_length_mm) and is_number(crop_factor) and
             is_number(image_diagonal_pixels) do
    focal_length_mm * image_diagonal_pixels * crop_factor / @sensor_diagonal_mm
  end

  @doc """
  Project a fisheye image to a rectilinear image.

  Implements the inverse of the equidistant fisheye mapping
  `r = f * θ` so the result behaves like a pinhole image.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  * `focal_length_pixels` is the lens focal length expressed in pixels
    (see `focal_length_in_pixels/3`).
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec fisheye_to_rectilinear(image :: Vimage.t(), focal_length_pixels :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def fisheye_to_rectilinear(%Vimage{} = image, focal_length_pixels)
      when is_number(focal_length_pixels) do
    use Image.Math

    {width, height, centre, f} = geom_params(image, focal_length_pixels)

    delta = (Operation.xyz!(width, height) - centre) / f
    r = polar_radius(delta)

    # source_pos = atan(r) / r * dest_pos (with limit r→0 → 1)
    safe_r = safe(r)
    factor = atan_image(safe_r) / safe_r

    transform = centre + delta * factor * f
    Operation.mapim(image, transform)
  end

  @doc """
  Project a rectilinear image to a fisheye image.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.
  * `focal_length_pixels` see `focal_length_in_pixels/3`.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec rectilinear_to_fisheye(image :: Vimage.t(), focal_length_pixels :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def rectilinear_to_fisheye(%Vimage{} = image, focal_length_pixels)
      when is_number(focal_length_pixels) do
    use Image.Math

    {width, height, centre, f} = geom_params(image, focal_length_pixels)

    delta = (Operation.xyz!(width, height) - centre) / f
    r = polar_radius(delta)

    safe_r = safe(r)
    factor = tan_image(safe_r) / safe_r

    transform = centre + delta * factor * f
    Operation.mapim(image, transform)
  end

  @doc """
  Project an equirectangular image to a rectilinear image.

  The horizontal coordinate in the source corresponds to longitude
  (angle around the optical axis) and the vertical coordinate to
  latitude.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec equirectangular_to_rectilinear(image :: Vimage.t(), focal_length_pixels :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def equirectangular_to_rectilinear(%Vimage{} = image, focal_length_pixels)
      when is_number(focal_length_pixels) do
    use Image.Math

    {width, height, centre, f} = geom_params(image, focal_length_pixels)

    xy = (Operation.xyz!(width, height) - centre) / f
    x = xy[0]
    y = xy[1]

    # Source: longitude = atan(x/1), latitude = atan(y/sqrt(1+x²))
    src_x = atan_image(x)
    src_y = atan2_image(y, (1.0 + x ** 2) ** 0.5)

    transform = centre + Operation.bandjoin!([src_x, src_y]) * f
    Operation.mapim(image, transform)
  end

  @doc """
  Project a rectilinear image to an equirectangular image.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec rectilinear_to_equirectangular(image :: Vimage.t(), focal_length_pixels :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def rectilinear_to_equirectangular(%Vimage{} = image, focal_length_pixels)
      when is_number(focal_length_pixels) do
    use Image.Math

    {width, height, centre, f} = geom_params(image, focal_length_pixels)

    xy = (Operation.xyz!(width, height) - centre) / f
    x = xy[0]
    y = xy[1]

    # tan(x), y / cos(x)
    src_x = tan_image(x)
    src_y = y / cos_image(x)

    transform = centre + Operation.bandjoin!([src_x, src_y]) * f
    Operation.mapim(image, transform)
  end

  @doc """
  Apply a projection conversion driven by source and target lens types.

  Currently supported pairs:

    * `:fisheye → :rectilinear`
    * `:rectilinear → :fisheye`
    * `:equirectangular → :rectilinear`
    * `:rectilinear → :equirectangular`

  Returns `{:ok, image}` for matching `from`/`to` (no-op) and
  `{:error, {:unsupported_projection_pair, from, to}}` for
  unsupported pairs.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec project(Vimage.t(), atom(), atom(), number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def project(%Vimage{} = image, from, to, _focal) when from == to, do: {:ok, image}

  def project(%Vimage{} = image, :fisheye, :rectilinear, focal),
    do: fisheye_to_rectilinear(image, focal)

  def project(%Vimage{} = image, :rectilinear, :fisheye, focal),
    do: rectilinear_to_fisheye(image, focal)

  def project(%Vimage{} = image, :equirectangular, :rectilinear, focal),
    do: equirectangular_to_rectilinear(image, focal)

  def project(%Vimage{} = image, :rectilinear, :equirectangular, focal),
    do: rectilinear_to_equirectangular(image, focal)

  def project(_image, from, to, _focal),
    do: {:error, {:unsupported_projection_pair, from, to}}

  ## Internals

  defp geom_params(%Vimage{} = image, focal_length_pixels) do
    width = Image.width(image)
    height = Image.height(image)
    centre = [(width - 1) / 2.0, (height - 1) / 2.0]
    {width, height, centre, focal_length_pixels * 1.0}
  end

  defp polar_radius(delta) do
    use Image.Math
    Image.Complex.polar!(delta)[0]
  end

  defp safe(r) do
    use Image.Math
    is_zero = Operation.relational_const!(r, :VIPS_OPERATION_RELATIONAL_EQUAL, [0.0])
    is_zero * 1.0e-12 + r
  end

  # libvips trig operations work in degrees; convert at the boundary.
  defp atan_image(image) do
    use Image.Math
    Operation.math!(image, :VIPS_OPERATION_MATH_ATAN) * (:math.pi() / 180.0)
  end

  defp tan_image(image) do
    use Image.Math
    Operation.math!(image * (180.0 / :math.pi()), :VIPS_OPERATION_MATH_TAN)
  end

  defp cos_image(image) do
    use Image.Math
    Operation.math!(image * (180.0 / :math.pi()), :VIPS_OPERATION_MATH_COS)
  end

  # atan2 isn't exposed at the per-band level; rectilinear→equirectangular
  # only ever calls this with x > 0 (x = sqrt(1+something²) ≥ 1), so a
  # plain atan(y/x) is correct.
  defp atan2_image(y, x) do
    use Image.Math
    atan_image(y / x)
  end
end
