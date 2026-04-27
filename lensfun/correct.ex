defmodule Image.LensFun.Correct do
  @moduledoc """
  Database-driven, EXIF-aware top-level correction entry point.

  This module lives outside `lib/` so the bundled lensfun database
  lookup code is only compiled in the `:dev` and `:test` environments
  and is not shipped in the published package. End users who need
  database-driven correction should depend on this library at
  development time and inline `Image.LensFun.Correct.correct/2` into
  their own code, or apply the standalone correction functions in
  `Image.LensCorrection`, `Image.LensCorrection.Tca` and
  `Image.LensCorrection.Geometry` directly with their own
  coefficients.
  """

  alias Vix.Vips.Image, as: Vimage
  alias Image.LensCorrection
  alias Image.LensFun

  @doc """
  Apply all available lens corrections to an image.

  Resolves camera, lens and shooting parameters from EXIF metadata
  (overridable via `options`), looks the lens up in the bundled
  lensfun database, interpolates the distortion, vignetting and TCA
  calibrations to the image's focal length / aperture and applies
  them in turn.

  ### Arguments

  * `image` is any `t:Vimage.t/0`.

  ### Options

  * `:make`, `:model`, `:lens_make`, `:lens_model` override the
    corresponding EXIF tags.

  * `:focal_length` (millimetres), `:aperture` (f-number) and
    `:distance` (metres, defaults to `1000.0`) override the EXIF
    shooting parameters.

  * `:crop_factor` overrides the camera crop factor lookup.

  * `:corrections` is a list of correction kinds to apply, drawn from
    `[:distortion, :vignetting, :tca, :projection]`. Defaults to
    `[:distortion, :vignetting, :tca]`.

  * `:target_projection` (one of `:rectilinear`, `:fisheye`,
    `:equirectangular`) controls the destination projection when
    `:projection` is enabled. Defaults to `:rectilinear`.

  ### Returns

  * `{:ok, corrected_image}` when at least one correction was applied,
    or `{:error, reason}` if the image lacks the metadata required to
    pick a lens.

  """
  @doc subject: "Database", since: "0.1.0"

  @spec correct(image :: Vimage.t(), options :: Keyword.t()) ::
          {:ok, Vimage.t()} | {:error, term()}

  def correct(%Vimage{} = image, options \\ []) do
    corrections = Keyword.get(options, :corrections, [:distortion, :vignetting, :tca])
    target_projection = Keyword.get(options, :target_projection, :rectilinear)

    with {:ok, metrics} <- LensFun.metrics_from_exif_and_options(image, options),
         {:ok, lens} <- resolve_lens(metrics),
         {:ok, image} <- run_distortion(image, lens, metrics, :distortion in corrections),
         {:ok, image} <- run_tca(image, lens, metrics, :tca in corrections),
         {:ok, image} <- run_vignetting(image, lens, metrics, :vignetting in corrections),
         {:ok, image} <-
           run_projection(image, lens, metrics, target_projection, :projection in corrections) do
      {:ok, image}
    end
  end

  defp resolve_lens(%{lens_make: make, lens_model: model})
       when is_binary(make) and is_binary(model) do
    LensFun.find_lens(make, model)
  end

  defp resolve_lens(_metrics), do: {:error, :missing_lens_metadata}

  defp run_distortion(image, _lens, _metrics, false), do: {:ok, image}

  defp run_distortion(image, lens, %{focal_length: focal, crop_factor: crop}, true)
       when is_number(focal) do
    with {:ok, distortion} <- LensFun.interpolate_distortion(lens, focal) do
      {:ok, scaled} =
        LensCorrection.rescale_coefficients(
          distortion,
          lens.crop_factor,
          lens.aspect_ratio,
          crop || lens.crop_factor
        )

      LensCorrection.apply_distortion(image, scaled)
    end
    |> maybe_skip(:no_calibration, image)
  end

  defp run_distortion(image, _lens, _metrics, true), do: {:ok, image}

  defp run_vignetting(image, _lens, _metrics, false), do: {:ok, image}

  defp run_vignetting(
         image,
         lens,
         %{focal_length: focal, aperture: aperture, distance: distance},
         true
       )
       when is_number(focal) and is_number(aperture) and is_number(distance) do
    case LensFun.interpolate_vignetting(lens, focal, aperture, distance) do
      {:ok, vignetting} -> LensCorrection.apply_vignetting(image, vignetting)
      {:error, :no_calibration} -> {:ok, image}
    end
  end

  defp run_vignetting(image, _lens, _metrics, true), do: {:ok, image}

  defp run_tca(image, _lens, _metrics, false), do: {:ok, image}

  defp run_tca(image, lens, %{focal_length: focal}, true) when is_number(focal) do
    case LensFun.interpolate_tca(lens, focal) do
      {:ok, tca} -> LensCorrection.Tca.apply_tca(image, tca)
      {:error, :no_calibration} -> {:ok, image}
    end
  end

  defp run_tca(image, _lens, _metrics, true), do: {:ok, image}

  defp run_projection(image, _lens, _metrics, _target, false), do: {:ok, image}

  defp run_projection(image, lens, %{focal_length: focal, crop_factor: crop}, target, true)
       when is_number(focal) do
    width = Image.width(image)
    height = Image.height(image)
    diagonal = :math.sqrt(width * width + height * height)
    crop = crop || lens.crop_factor || 1.0

    focal_pixels = LensCorrection.Geometry.focal_length_in_pixels(focal, crop, diagonal)

    case LensCorrection.Geometry.project(image, lens.type, target, focal_pixels) do
      {:ok, image} -> {:ok, image}
      {:error, _} -> {:ok, image}
    end
  end

  defp run_projection(image, _lens, _metrics, _target, true), do: {:ok, image}

  defp maybe_skip({:error, reason}, reason, fallback), do: {:ok, fallback}
  defp maybe_skip(other, _reason, _fallback), do: other
end
