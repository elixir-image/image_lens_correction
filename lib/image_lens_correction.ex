defmodule ImageLensCorrection do
  @moduledoc """


  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation, as: Operation
  alias Image.Complex, as: Complex

  @doc """
  Applies a correction for [barrel distortion](https://www.iphotography.com/blog/what-is-lens-barrel-distortion/)
  and pincushion distortion.

  Barrel/pincushion distortion is present in all but the most optically
  perfect camera lens. Some cameras will apply a correction
  in-camera, many do not.

  The parameters to the function, which are "a", "b", "c" and
  optionally "d", are specific to each lens and focal distance.

  The primary source of these parameters is the [lensfun database](https://github.com/lensfun/lensfun)
  which lists the parameters for many lens.

  In general these numbers are very small, typically less than
  0.1, so when experimenting to find acceptable output start with
  small numbers for `a` and `b` and `0.0` for `c`. Omit the `d`
  parameter in most, if not all, cases.

  A future release may incorporate the lensfun database to automatically
  derive the correct parameters based upon image [exif](https://en.wikipedia.org/wiki/Exif) data.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  * `a`, `b`, `c` are parameters specific to each
    camera lens and focal distance, typically found in the
    [lensfun](https://github.com/lensfun/lensfun) database.

  ### Returns

  * `{:ok, undistorted_image}` or

  * `{:error, reason}`

  ### Example

        iex> image = Image.open!("./test/support/images/gridlines_barrel.png")
        iex> Image.radial_distortion_correction(image, -0.007715, 0.086731, 0.0)

  """

  # Models
  # poly3:
  #   "Rd = Ru * (1 - k1 + k1 * Ru^2)\n".
  #   http://www.imatest.com/docs/distortion.html
  # poly5:
  #   "Rd = Ru * (1 + k1 * Ru^2 + k2 * Ru^4)\n".
  #   http://www.imatest.com/docs/distortion.html
  # ptlens:
  #   "Rd = Ru * (a * Ru^3 + b * Ru^2 + c * Ru + 1 - (a + b + c))\n"
  #   http://wiki.panotools.org/Lens_correction_model

  @doc subject: "Distortion", since: "0.58.0"

  @spec radial_distortion_correction(
          image :: Vimage.t(),
          a :: number(),
          b :: number(),
          c :: number()
        ) ::
          {:ok, Vimage.t()} | {:error, Image.error_message}

  def radial_distortion_correction(%Vimage{} = image, a, b, c)
      when is_number(a) and is_number(b) and is_number(c) do
    use Image.Math

    width = Image.width(image)
    height = Image.height(image)

    radius = min(width, height) / 2
    centre_x = (width - 1) / 2
    centre_y = (height - 1) / 2

    # Cartesian coordinates of the destination point
    # relative to the centre of the image.
    index = Operation.xyz!(width, height)
    delta = (index - [centre_x, centre_y]) / radius

    # distance or radius of destination image
    dstr = Complex.polar!(delta)[0]

    # distance or radius of source image (with formula)
    d = 1.0 - a - b - c
    srcr = dstr * (a * dstr ** 3 + b * dstr ** 2 + c * dstr + d)

    # comparing old and new distance to get factor
    factor = Operation.abs!(dstr / srcr)

    # coordinates in the source image
    transform = [centre_x, centre_y] + delta * factor * radius

    # Map new coordinates
    Operation.mapim(image, transform)
  end

  @doc """
  Applies a correction for [vignetting](https://en.wikipedia.org/wiki/Vignetting).

  In photography and optics, vignetting is a reduction of an image's
  brightness or saturation toward the periphery compared to the
  image center.

  Vignetting is often an unintended and undesired effect caused by
  camera settings or lens limitations.

  The parameters to the function, which are "k1", "k2" and "k3"
  are specific to each lens, aperature and focal distance.

  The primary source of these parameters is the [lensfun database](https://github.com/lensfun/lensfun)
  which lists the parameters for many lens.

  In general these numbers are very small, typically less than
  0.1, so when experimenting to find acceptable output start with
  small numbers for `k1` and `k2` and `0.0` for `k3`.

  A future release may incorporate the lensfun database to automatically
  derive the correct parameters based upon image [exif](https://en.wikipedia.org/wiki/Exif) data.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  * `k1`, `k2`, `k3` are parameters specific to each
    camera lens and focal distance, typically found in the
    [lensfun](https://github.com/lensfun/lensfun) database.

  ### Returns

  * `{:ok, unvignetted_image}` or

  * `{:error, reason}`

  ### Example

        iex> image = Image.new!(200, 200, color: :green)
        iex> Image.vignette_correction(image, -0.2764, -1.26031, 0.7727)

  """

  @doc subject: "Distortion", since: "0.59.0"

  @spec vignette_correction(
          image :: Vimage.t(),
          k1 :: number(),
          k2 :: number(),
          k3 :: number()
        ) ::
          {:ok, Vimage.t()} | {:error, Image.error_message}

  def vignette_correction(%Vimage{} = image, k1, k2, k3) do
    use Image.Math

    format = Image.band_format(image)
    width = Image.width(image)
    height = Image.height(image)

    centre_x = (width - 1) / 2
    centre_y = (height - 1) / 2

    # Cartesian coordinates of the destination point
    # relative to the centre of the image.
    index = Operation.xyz!(width, height)
    index = (index - [centre_x, centre_y])

    # Get the radial distance from the centre
    # which is band 0 of the polar image
    r = Complex.polar!(index)[0]
    r = r / max!(r)

    # Correction function from https://lensfun.github.io/calibration-tutorial/lens-vignetting.html
    # Also http://download.macromedia.com/pub/labs/lensprofile_creator/lensprofile_creator_cameramodel.pdf
    # Cd = Cs * (1 + k1 * R^2 + k2 * R^4 + k3 * R^6)
    # Inverting the formula to un-vignette (rather than calibrate the vignette)
    d_dest = 1.0 - (k1 * r**2) + (k2 * r**4) + (k3 * r**6)

    Image.cast(image / d_dest, format)
  end
end
