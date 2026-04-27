defmodule Image.LensCorrection.Tca do
  @moduledoc """
  Lateral [chromatic aberration (TCA)](https://en.wikipedia.org/wiki/Chromatic_aberration#Lateral)
  correction.

  Two TCA models are supported, matching the lensfun database:

  * `:linear` — `Rd_R = kr * Ru` and `Rd_B = kb * Ru`. The green channel
    is taken as the reference.

  * `:poly3`  — `Rd = Ru * (b * Ru² + c * Ru + v)` applied independently
    to the red and blue channels.

  In both cases the coordinate origin is the image centre and `r = 1`
  corresponds to the half short-edge of the image (Hugin convention).

  RGBA images are supported: the alpha channel is taken from the green
  channel's geometry (i.e. left untouched).
  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation, as: Operation
  alias Image.Complex, as: Complex

  @newton_iterations 6

  @doc """
  Apply a TCA correction described by a lensfun-shaped parameter map.

  Accepts the output of `Image.LensFun.interpolate_tca/2`:

      %{model: :linear, terms: %{kr: ..., kb: ...}}
      %{model: :poly3,  terms: %{vr: ..., vb: ..., cr: ..., cb: ..., br: ..., bb: ...}}

  ### Returns

  * `{:ok, image}` or `{:error, reason}`.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec apply_tca(image :: Vimage.t(), tca :: map()) ::
          {:ok, Vimage.t()} | {:error, term()}

  def apply_tca(%Vimage{} = image, %{model: :linear, terms: %{kr: kr, kb: kb}}) do
    linear_tca_correction(image, kr, kb)
  end

  def apply_tca(%Vimage{} = image, %{model: :poly3, terms: terms}) do
    poly3_tca_correction(image, terms)
  end

  def apply_tca(_image, tca) do
    {:error, {:unsupported_tca_model, tca}}
  end

  @doc """
  Apply a linear TCA correction.

  ### Arguments

  * `image` is any `t:Vimage.t/0` with three or four bands.

  * `kr`, `kb` are the radial scaling factors for the red and blue
    channels relative to green.

  ### Returns

  * `{:ok, corrected}` or `{:error, reason}`.

  ### Examples

      iex> image = Image.open!("./test/support/images/gridlines_barrel.png")
      iex> {:ok, _} = Image.LensCorrection.Tca.linear_tca_correction(image, 1.0004, 1.0002)

  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec linear_tca_correction(image :: Vimage.t(), kr :: number(), kb :: number()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def linear_tca_correction(%Vimage{} = image, kr, kb) when is_number(kr) and is_number(kb) do
    apply_per_band(image, fn _rd, delta, centre, radius ->
      [
        scaled_transform(delta, centre, radius, 1.0 / kr),
        nil,
        scaled_transform(delta, centre, radius, 1.0 / kb)
      ]
    end)
  end

  @doc """
  Apply a poly3 TCA correction.

  ### Arguments

  * `image` is any `t:Vimage.t/0` with three or four bands.

  * `terms` is a map with keys `:vr, :vb, :cr, :cb, :br, :bb` —
    the lensfun poly3 TCA coefficients.

  ### Returns

  * `{:ok, corrected}` or `{:error, reason}`.
  """
  @doc subject: "Distortion", since: "0.1.0"

  @spec poly3_tca_correction(image :: Vimage.t(), terms :: map()) ::
          {:ok, Vimage.t()} | {:error, term()}
  def poly3_tca_correction(%Vimage{} = image, %{vr: vr, vb: vb, cr: cr, cb: cb, br: br, bb: bb}) do
    apply_per_band(image, fn rd, delta, centre, radius ->
      red_factor = poly3_inverse_factor(rd, vr, cr, br)
      blue_factor = poly3_inverse_factor(rd, vb, cb, bb)

      [
        delta_to_transform(delta, centre, radius, red_factor),
        nil,
        delta_to_transform(delta, centre, radius, blue_factor)
      ]
    end)
  end

  ## Internals

  defp apply_per_band(%Vimage{} = image, factor_fn) do
    width = Image.width(image)
    height = Image.height(image)
    bands = Image.bands(image)

    radius = min(width / 1, height / 1) / 2.0
    centre = [(width - 1) / 2.0, (height - 1) / 2.0]

    {rd, delta} = build_delta(width, height, centre, radius)
    [r_t, _, b_t] = factor_fn.(rd, delta, centre, radius)

    with {:ok, red} <- Operation.mapim(image[0], r_t),
         {:ok, blue} <- Operation.mapim(image[2], b_t) do
      green = image[1]

      bands_out =
        if bands >= 4 do
          [red, green, blue, image[3]]
        else
          [red, green, blue]
        end

      Operation.bandjoin(bands_out)
    end
  end

  defp build_delta(width, height, centre, radius) do
    use Image.Math
    delta = (Operation.xyz!(width, height) - centre) / radius
    rd = Complex.polar!(delta)[0]
    {rd, delta}
  end

  # Build a (centre + delta * factor * radius) transform image given a
  # scalar factor.
  defp scaled_transform(delta, centre, radius, factor) when is_number(factor) do
    use Image.Math
    centre + delta * (factor * radius)
  end

  # Build the same transform given a per-pixel factor image.
  defp delta_to_transform(delta, centre, radius, factor) do
    use Image.Math
    centre + delta * factor * radius
  end

  # poly3 forward (TCA): Rd = Ru * (b*Ru² + c*Ru + v)
  # Solve for Ru via Newton, return Ru/Rd.
  defp poly3_inverse_factor(rd, v, c, b) do
    use Image.Math

    ru =
      Enum.reduce(1..@newton_iterations, rd, fn _i, ru ->
        ru2 = ru ** 2
        f = b * ru2 * ru + c * ru2 + v * ru - rd
        fp = 3.0 * b * ru2 + 2.0 * c * ru + v
        ru - f / fp
      end)

    safe_ratio(ru, rd)
  end

  defp safe_ratio(ru, rd) do
    use Image.Math
    is_zero = Operation.relational_const!(rd, :VIPS_OPERATION_RELATIONAL_EQUAL, [0.0])
    safe_rd = is_zero * 1.0e-12 + rd
    ru / safe_rd
  end
end
