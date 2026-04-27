defmodule Image.LensFun do
  @moduledoc """
  Lookup, interpolation and EXIF resolution for the
  [lensfun](https://github.com/lensfun/lensfun) calibration database.

  The compiled database is shipped with the application as an Erlang
  term file under `priv/lensfun/lensfun.etf` and can be regenerated
  with `Image.LensFun.Importer.import/1`.
  """

  alias Vix.Vips.Image, as: Vimage

  @app_name Mix.Project.config()[:app]
  @db_save_file "priv/lensfun/lensfun.etf"

  @doc "Absolute path to the bundled lensfun ETF database."
  def db_path do
    Application.app_dir(@app_name, @db_save_file)
  end

  @doc """
  Load and decode the bundled lensfun database. Cached in the persistent
  term cache so repeated calls are cheap.
  """
  def db do
    case :persistent_term.get({__MODULE__, :db}, :missing) do
      :missing ->
        loaded =
          db_path()
          |> File.read!()
          |> :erlang.binary_to_term()

        :persistent_term.put({__MODULE__, :db}, loaded)
        loaded

      cached ->
        cached
    end
  end

  @doc """
  Find the calibration set for a lens.

  ### Arguments

  * `maker` is the manufacturer string as it appears in the lensfun database
    (for example `"Canon"`).

  * `lens_model` is the lens model string. Matching is case-insensitive
    and tolerates leading/trailing whitespace; if no exact match is found,
    a fuzzy substring match is attempted.

  ### Options

  * `:crop_factor` selects the calibration set whose crop factor is
    closest to (but no smaller than `0.96 * crop_factor`). Defaults to
    `nil` which returns the first match.

  ### Returns

  * `{:ok, lens}` where `lens` is the lensfun calibration map, or

  * `{:error, :not_found}`.

  """
  def find_lens(maker, lens_model, options \\ []) do
    crop_factor = Keyword.get(options, :crop_factor)

    candidates =
      db().lenses
      |> Map.get(canonical_maker(maker), [])
      |> match_lens_model(lens_model)

    case {candidates, crop_factor} do
      {[], _} ->
        {:error, :not_found}

      {list, nil} ->
        {:ok, List.first(list)}

      {list, crop} ->
        case pick_calibration_set(list, crop) do
          nil -> {:error, :not_found}
          lens -> {:ok, lens}
        end
    end
  end

  @doc """
  Search the bundled lensfun database for lenses matching a query.

  Returns a list of `{maker, lens}` tuples ordered by relevance. The
  `query` is a free-form string matched against the maker and model
  name; matching is case-insensitive and word-by-word, so
  `"canon 100 macro"` will find `"Canon EF 100mm f/2.8 Macro USM"`.

  ### Options

  * `:maker` restricts results to a single maker (case-insensitive).

  * `:limit` caps the number of results returned. Defaults to `50`.

  * `:has` is a list of capability filters drawn from
    `[:distortion, :vignetting, :tca]`. Only lenses with calibration
    data for **every** listed capability are returned.

  ### Examples

      iex> [{"Canon", lens} | _] = Image.LensFun.search_lenses("canon 100 macro", maker: "Canon")
      iex> lens.model =~ "100mm"
      true

  """
  @doc subject: "Database", since: "0.1.0"

  @spec search_lenses(String.t(), Keyword.t()) :: [{String.t(), map()}]
  def search_lenses(query, options \\ []) when is_binary(query) do
    limit = Keyword.get(options, :limit, 50)
    capabilities = Keyword.get(options, :has, [])
    maker_filter = options |> Keyword.get(:maker) |> normalize_maker_filter()

    query_words =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    db().lenses
    |> Enum.flat_map(fn {maker, lenses} -> Enum.map(lenses, &{maker, &1}) end)
    |> Stream.filter(fn {maker, _lens} ->
      maker_filter == nil or String.downcase(maker) == maker_filter
    end)
    |> Stream.filter(fn {_maker, lens} -> has_capabilities?(lens, capabilities) end)
    |> Stream.map(fn {maker, lens} -> {maker, lens, score(maker, lens, query_words)} end)
    |> Stream.filter(fn {_, _, score} -> score > 0 end)
    |> Enum.sort_by(fn {_, _, score} -> -score end)
    |> Enum.take(limit)
    |> Enum.map(fn {maker, lens, _} -> {maker, lens} end)
  end

  defp normalize_maker_filter(nil), do: nil
  defp normalize_maker_filter(maker), do: maker |> String.downcase() |> String.trim()

  defp has_capabilities?(_lens, []), do: true

  defp has_capabilities?(lens, [:distortion | rest]),
    do: lens.distortion != [] and has_capabilities?(lens, rest)

  defp has_capabilities?(lens, [:vignetting | rest]),
    do: lens.vignetting != [] and has_capabilities?(lens, rest)

  defp has_capabilities?(lens, [:tca | rest]),
    do: lens.tca != [] and has_capabilities?(lens, rest)

  defp has_capabilities?(lens, [_ | rest]),
    do: has_capabilities?(lens, rest)

  defp score(maker, lens, query_words) do
    haystack = "#{String.downcase(maker)} #{String.downcase(lens.model)}"

    Enum.reduce(query_words, 0, fn word, acc ->
      if String.contains?(haystack, word), do: acc + 1, else: acc
    end)
  end

  @doc """
  Find the camera record for a make and model.

  Returns `{:ok, %{model:, mount:, crop_factor:}}` or `{:error, :not_found}`.
  """
  def find_camera(maker, model) do
    list = Map.get(db().cameras, canonical_maker(maker), [])

    target = normalize_model(model)

    case Enum.find(list, fn c -> normalize_model(c.model) == target end) do
      nil -> {:error, :not_found}
      camera -> {:ok, camera}
    end
  end

  @doc """
  Interpolate the distortion calibration for a target focal length.

  Implements the same Catmull-Rom Hermite interpolation as
  `lfLens::InterpolateDistortion` from lensfun, with degenerate
  endpoints handled by clamping. Returns `{:ok, distortion}` or
  `{:error, :no_calibration}`.
  """
  def interpolate_distortion(%{distortion: []}, _focal), do: {:error, :no_calibration}

  def interpolate_distortion(%{distortion: distortions}, focal) when is_number(focal) do
    case Enum.find(distortions, &(&1.focal_length == focal)) do
      %{} = exact ->
        {:ok, exact}

      nil ->
        sorted = Enum.sort_by(distortions, & &1.focal_length)
        {:ok, hermite_interpolate(sorted, focal)}
    end
  end

  @doc """
  Interpolate the TCA (lateral chromatic aberration) calibration for a
  target focal length using the same Hermite spline as
  `interpolate_distortion/2`.

  Returns `{:ok, tca}` or `{:error, :no_calibration}`.
  """
  def interpolate_tca(lens, focal)

  def interpolate_tca(%{tca: []}, _focal), do: {:error, :no_calibration}

  def interpolate_tca(%{tca: tcas}, focal) when is_number(focal) do
    case Enum.find(tcas, &(&1.focal_length == focal)) do
      %{} = exact ->
        {:ok, exact}

      nil ->
        sorted = Enum.sort_by(tcas, & &1.focal_length)
        {:ok, hermite_interpolate(sorted, focal)}
    end
  end

  @doc """
  Interpolate the vignetting calibration for a target focal length,
  aperture and distance using inverse-distance weighting (the same
  approach as lensfun's `InterpolateVignetting`).
  """
  def interpolate_vignetting(%{vignetting: []}, _focal, _aperture, _distance) do
    {:error, :no_calibration}
  end

  def interpolate_vignetting(%{vignetting: vigs} = lens, focal, aperture, distance)
      when is_number(focal) and is_number(aperture) and is_number(distance) do
    {min_focal, max_focal} = focal_range(lens)
    df = max_focal - min_focal

    weights =
      Enum.map(vigs, fn v ->
        f1 = if df == 0.0, do: 0.0, else: (focal - min_focal) / df
        f2 = if df == 0.0, do: 0.0, else: (v.focal_length - min_focal) / df
        a1 = 4.0 / aperture
        a2 = 4.0 / v.aperture
        d1 = 0.1 / distance
        d2 = 0.1 / v.distance

        dist = :math.sqrt((f2 - f1) ** 2 + (a2 - a1) ** 2 + (d2 - d1) ** 2)
        {v, dist}
      end)

    case Enum.find(weights, fn {_v, d} -> d < 0.0001 end) do
      {exact, _} ->
        {:ok, exact}

      nil ->
        smallest = weights |> Enum.map(&elem(&1, 1)) |> Enum.min()

        if smallest > 1.0 do
          {:error, :no_calibration}
        else
          power = 3.5
          weighted = Enum.map(weights, fn {v, d} -> {v, abs(1.0 / :math.pow(d, power))} end)
          total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

          terms =
            Enum.reduce(weighted, %{k1: 0.0, k2: 0.0, k3: 0.0}, fn {v, w}, acc ->
              %{
                k1: acc.k1 + w * v.terms.k1,
                k2: acc.k2 + w * v.terms.k2,
                k3: acc.k3 + w * v.terms.k3
              }
            end)

          terms = %{
            k1: terms.k1 / total,
            k2: terms.k2 / total,
            k3: terms.k3 / total
          }

          {:ok,
           %{
             model: :pa,
             focal_length: focal,
             aperture: aperture,
             distance: distance,
             terms: terms
           }}
        end
    end
  end

  @doc """
  Resolve the metrics needed to look up calibration data from the
  combination of an image's EXIF metadata and explicit options.

  ### Options

  * `:make` overrides the camera maker.
  * `:model` overrides the camera model.
  * `:lens_make` overrides the lens maker (defaults to `:make`).
  * `:lens_model` overrides the lens model.
  * `:focal_length` overrides the focal length in millimetres.
  * `:aperture` overrides the f-number.
  * `:distance` overrides the focus distance in metres
    (defaults to `1000.0` — effectively infinity).
  * `:crop_factor` overrides the camera's crop factor.

  Returns `{:ok, metrics}` or `{:error, reason}` where `metrics` is a
  map with keys `:make`, `:model`, `:lens_make`, `:lens_model`,
  `:focal_length`, `:aperture`, `:distance`, `:crop_factor`.
  """
  def metrics_from_exif_and_options(%Vimage{} = image, options \\ []) do
    exif =
      case Image.exif(image) do
        {:ok, e} -> e
        _ -> %{}
      end

    make = Keyword.get(options, :make) || Map.get(exif, :make)
    model = Keyword.get(options, :model) || Map.get(exif, :model)
    lens_make = Keyword.get(options, :lens_make) || Map.get(exif, :lens_make) || make
    lens_model = Keyword.get(options, :lens_model) || Map.get(exif, :lens_model)

    focal_length =
      Keyword.get(options, :focal_length) ||
        Map.get(exif, :focal_length) ||
        Map.get(exif, :focal_length_in_35mm_film)

    aperture = Keyword.get(options, :aperture) || Map.get(exif, :f_number)
    distance = Keyword.get(options, :distance, 1000.0)

    crop_factor =
      case Keyword.fetch(options, :crop_factor) do
        {:ok, value} ->
          value

        :error ->
          case {make, model} do
            {m, mo} when is_binary(m) and is_binary(mo) ->
              case find_camera(m, mo) do
                {:ok, %{crop_factor: cf}} when is_number(cf) -> cf
                _ -> nil
              end

            _ ->
              nil
          end
      end

    {:ok,
     %{
       make: make,
       model: model,
       lens_make: lens_make,
       lens_model: lens_model,
       focal_length: focal_length && to_float(focal_length),
       aperture: aperture && to_float(aperture),
       distance: to_float(distance),
       crop_factor: crop_factor && to_float(crop_factor)
     }}
  end

  ## Internal helpers

  defp focal_range(%{distortion: ds, vignetting: vs}) do
    focals =
      (Enum.map(ds, & &1.focal_length) ++ Enum.map(vs, & &1.focal_length))
      |> Enum.reject(&is_nil/1)

    case focals do
      [] -> {0.0, 0.0}
      list -> {Enum.min(list), Enum.max(list)}
    end
  end

  defp canonical_maker(nil), do: nil

  defp canonical_maker(maker) when is_binary(maker) do
    target = String.downcase(String.trim(maker))

    db().lenses
    |> Map.keys()
    |> Enum.find(maker, fn key -> String.downcase(key) == target end)
  end

  defp normalize_model(string) when is_binary(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, " ")
    |> String.trim()
  end

  defp normalize_model(_), do: ""

  defp match_lens_model(lenses, model) when is_binary(model) do
    target = normalize_model(model)

    case Enum.filter(lenses, &(normalize_model(&1.model) == target)) do
      [] ->
        Enum.filter(lenses, fn lens ->
          lens_norm = normalize_model(lens.model)

          target != "" and
            (String.contains?(lens_norm, target) or String.contains?(target, lens_norm))
        end)

      list ->
        list
    end
  end

  defp match_lens_model(_lenses, _), do: []

  defp pick_calibration_set(lenses, crop) when is_number(crop) do
    lenses
    |> Enum.filter(fn lens ->
      is_number(lens.crop_factor) and crop / lens.crop_factor >= 0.96
    end)
    |> Enum.min_by(
      fn lens -> crop / lens.crop_factor end,
      fn -> nil end
    )
  end

  # Hermite (Catmull-Rom) interpolation between bracketing focal lengths.
  defp hermite_interpolate([only], _focal), do: only

  defp hermite_interpolate(sorted, focal) do
    cond do
      focal <= hd(sorted).focal_length ->
        hd(sorted)

      focal >= List.last(sorted).focal_length ->
        List.last(sorted)

      true ->
        {below, above} = Enum.split_while(sorted, &(&1.focal_length < focal))
        p1 = List.last(below)
        [p2 | _] = above
        p0 = below |> Enum.drop(-1) |> List.last() || p1
        p3 = above |> Enum.drop(1) |> List.first() || p2

        t = (focal - p1.focal_length) / (p2.focal_length - p1.focal_length)

        terms =
          Map.new(p1.terms, fn {key, v1} ->
            v0 = Map.get(p0.terms, key, v1)
            v2 = Map.get(p2.terms, key, v1)
            v3 = Map.get(p3.terms, key, v2)
            {key, hermite(v0, v1, v2, v3, t)}
          end)

        real_focal =
          case {p1.real_focal, p2.real_focal} do
            {nil, _} -> nil
            {_, nil} -> nil
            {a, b} -> a + (b - a) * t
          end

        %{p1 | focal_length: focal, terms: terms, real_focal: real_focal}
    end
  end

  defp hermite(y1, y2, y3, y4, t) do
    t2 = t * t
    t3 = t2 * t
    tg2 = (y3 - y1) * 0.5
    tg3 = (y4 - y2) * 0.5

    (2 * t3 - 3 * t2 + 1) * y2 +
      (t3 - 2 * t2 + t) * tg2 +
      (-2 * t3 + 3 * t2) * y3 +
      (t3 - t2) * tg3
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp to_float({n, d}) when is_integer(n) and is_integer(d) and d != 0, do: n / d

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp to_float(_), do: nil
end
