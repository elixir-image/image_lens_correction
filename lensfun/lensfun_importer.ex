defmodule Image.LensFun.Importer do
  @moduledoc """
  Imports the [lensfun](https://github.com/lensfun/lensfun) XML database
  into a compact Erlang term file at `priv/lensfun/lensfun.etf`.

  The output term has the shape:

      %{
        cameras: %{maker => [%{model: ..., crop_factor: ..., mount: ...}, ...]},
        lenses:  %{maker => [%{
                              model: ...,
                              crop_factor: ...,
                              aspect_ratio: ...,
                              mount: ...,
                              distortion: [%{focal_length: ..., model: :ptlens | :poly3 | :poly5,
                                             real_focal: nil | float, terms: %{...}}, ...],
                              vignetting: [%{focal_length: ..., aperture: ..., distance: ...,
                                             model: :pa, terms: %{k1: ..., k2: ..., k3: ...}}, ...]
                            }, ...]}
      }

  """

  @default_lensfun_db "../lensfun"
  @db_glob "/data/db/*.xml"

  @default_aspect_ratio 1.5

  @doc """
  Parse every lensfun XML file under the given lensfun checkout and write the
  resulting term to `Image.LensFun.db_path/0`.
  """
  def import(lensfun_git_dir \\ @default_lensfun_db) when is_binary(lensfun_git_dir) do
    with {:ok, glob} <- resolve_lensfun_db_location(lensfun_git_dir) do
      {cameras, lenses} =
        glob
        |> Path.wildcard()
        |> Enum.reduce({%{}, %{}}, fn path, {cameras, lenses} ->
          IO.puts("Processing #{path}")
          {file_cameras, file_lenses} = parse_xml(path)
          {merge_by_maker(cameras, file_cameras), merge_by_maker(lenses, file_lenses)}
        end)

      db = %{cameras: cameras, lenses: lenses}
      bin = :erlang.term_to_binary(db)

      path = Image.LensFun.db_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bin)
      IO.puts("Saved lensfun database (#{byte_size(bin)} bytes) to #{inspect(path)}")
      IO.puts("  cameras: #{cameras |> Map.values() |> Enum.map(&length/1) |> Enum.sum()}")
      IO.puts("  lenses:  #{lenses |> Map.values() |> Enum.map(&length/1) |> Enum.sum()}")
    end
  end

  @doc false
  def resolve_lensfun_db_location(lensfun_git_dir) do
    cond do
      File.dir?(lensfun_git_dir) ->
        {:ok, Path.join(lensfun_git_dir, @db_glob)}

      lensfun_git_dir == @default_lensfun_db ->
        {:error,
         """
         lensfun git repo not found at the default location #{inspect(@default_lensfun_db)}.

         Please clone https://github.com/lensfun/lensfun and call
         `Image.LensFun.Importer.import/1` with that directory as the parameter.
         """}

      true ->
        {:error, "lensfun git repo not found at #{inspect(lensfun_git_dir)}."}
    end
  end

  @doc false
  def parse_xml(path) do
    import SweetXml

    doc = File.read!(path)

    cameras =
      doc
      |> xpath(
        ~x"//camera"l,
        maker: ~x"./maker[not(@lang)]/text()"s,
        model: ~x"./model[not(@lang)]/text()"s,
        mount: ~x"./mount/text()"s,
        crop_factor: ~x"./cropfactor/text()"s |> transform_by(&parse_float/1)
      )
      |> Enum.reject(&(&1.maker == "" or &1.model == ""))
      |> Enum.group_by(& &1.maker, &Map.delete(&1, :maker))

    lenses =
      doc
      |> xpath(
        ~x"//lens"l,
        maker: ~x"./maker[not(@lang)]/text()"s,
        model: ~x"./model[not(@lang)]/text()"s,
        mount: ~x"./mount/text()"s,
        type: ~x"./type/text()"s |> transform_by(&parse_lens_type/1),
        crop_factor: ~x"./cropfactor/text()"s |> transform_by(&parse_float/1),
        aspect_ratio: ~x"./aspect-ratio/text()"s |> transform_by(&parse_aspect_ratio/1),
        distortion: [
          ~x"./calibration/distortion"l,
          model: ~x"@model"s,
          focal_length: ~x"@focal"s |> transform_by(&parse_float/1),
          real_focal: ~x"@real-focal"s |> transform_by(&parse_float/1),
          a: ~x"@a"s |> transform_by(&parse_float/1),
          b: ~x"@b"s |> transform_by(&parse_float/1),
          c: ~x"@c"s |> transform_by(&parse_float/1),
          k1: ~x"@k1"s |> transform_by(&parse_float/1),
          k2: ~x"@k2"s |> transform_by(&parse_float/1)
        ],
        vignetting: [
          ~x"./calibration/vignetting"l,
          model: ~x"@model"s,
          focal_length: ~x"@focal"s |> transform_by(&parse_float/1),
          aperture: ~x"@aperture"s |> transform_by(&parse_float/1),
          distance: ~x"@distance"s |> transform_by(&parse_float/1),
          k1: ~x"@k1"s |> transform_by(&parse_float/1),
          k2: ~x"@k2"s |> transform_by(&parse_float/1),
          k3: ~x"@k3"s |> transform_by(&parse_float/1)
        ],
        tca: [
          ~x"./calibration/tca"l,
          model: ~x"@model"s,
          focal_length: ~x"@focal"s |> transform_by(&parse_float/1),
          kr: ~x"@kr"s |> transform_by(&parse_float/1),
          kb: ~x"@kb"s |> transform_by(&parse_float/1),
          vr: ~x"@vr"s |> transform_by(&parse_float/1),
          vb: ~x"@vb"s |> transform_by(&parse_float/1),
          cr: ~x"@cr"s |> transform_by(&parse_float/1),
          cb: ~x"@cb"s |> transform_by(&parse_float/1),
          br: ~x"@br"s |> transform_by(&parse_float/1),
          bb: ~x"@bb"s |> transform_by(&parse_float/1)
        ]
      )
      |> Enum.reject(&(&1.maker == "" or &1.model == ""))
      |> Enum.map(&normalize_lens/1)
      |> Enum.group_by(& &1.maker, &Map.delete(&1, :maker))

    {cameras, lenses}
  end

  defp merge_by_maker(acc, additions) do
    Map.merge(acc, additions, fn _k, v1, v2 -> v1 ++ v2 end)
  end

  defp normalize_lens(lens) do
    distortion =
      lens.distortion
      |> Enum.map(&normalize_distortion/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.focal_length)

    vignetting =
      lens.vignetting
      |> Enum.map(&normalize_vignetting/1)
      |> Enum.reject(&is_nil/1)

    tca =
      lens.tca
      |> Enum.map(&normalize_tca/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.focal_length)

    %{
      maker: lens.maker,
      model: lens.model,
      mount: lens.mount,
      type: lens.type || :rectilinear,
      crop_factor: lens.crop_factor,
      aspect_ratio: lens.aspect_ratio || @default_aspect_ratio,
      distortion: distortion,
      vignetting: vignetting,
      tca: tca
    }
  end

  defp normalize_distortion(%{model: "ptlens"} = d) do
    %{
      model: :ptlens,
      focal_length: d.focal_length,
      real_focal: d.real_focal,
      terms: %{a: d.a || 0.0, b: d.b || 0.0, c: d.c || 0.0}
    }
  end

  defp normalize_distortion(%{model: "poly3"} = d) do
    %{
      model: :poly3,
      focal_length: d.focal_length,
      real_focal: d.real_focal,
      terms: %{k1: d.k1 || 0.0}
    }
  end

  defp normalize_distortion(%{model: "poly5"} = d) do
    %{
      model: :poly5,
      focal_length: d.focal_length,
      real_focal: d.real_focal,
      terms: %{k1: d.k1 || 0.0, k2: d.k2 || 0.0}
    }
  end

  defp normalize_distortion(_other), do: nil

  defp normalize_vignetting(%{model: "pa"} = v) do
    %{
      model: :pa,
      focal_length: v.focal_length,
      aperture: v.aperture,
      distance: v.distance,
      terms: %{k1: v.k1 || 0.0, k2: v.k2 || 0.0, k3: v.k3 || 0.0}
    }
  end

  defp normalize_vignetting(_other), do: nil

  defp normalize_tca(%{model: "linear"} = t) do
    %{
      model: :linear,
      focal_length: t.focal_length,
      terms: %{kr: t.kr || 1.0, kb: t.kb || 1.0}
    }
  end

  defp normalize_tca(%{model: "poly3"} = t) do
    %{
      model: :poly3,
      focal_length: t.focal_length,
      terms: %{
        vr: t.vr || 1.0,
        vb: t.vb || 1.0,
        cr: t.cr || 0.0,
        cb: t.cb || 0.0,
        br: t.br || 0.0,
        bb: t.bb || 0.0
      }
    }
  end

  defp normalize_tca(_other), do: nil

  defp parse_lens_type(""), do: nil
  defp parse_lens_type("rectilinear"), do: :rectilinear
  defp parse_lens_type("fisheye"), do: :fisheye
  defp parse_lens_type("panoramic"), do: :panoramic
  defp parse_lens_type("equirectangular"), do: :equirectangular
  defp parse_lens_type("stereographic"), do: :fisheye_stereographic
  defp parse_lens_type("equisolid"), do: :fisheye_equisolid
  defp parse_lens_type("orthographic"), do: :fisheye_orthographic
  defp parse_lens_type("thoby"), do: :fisheye_thoby
  defp parse_lens_type(other) when is_binary(other), do: String.to_atom(other)

  @doc false
  def parse_float(""), do: nil
  def parse_float(nil), do: nil

  def parse_float(string) when is_binary(string) do
    case Float.parse(string) do
      {value, ""} -> value
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp parse_aspect_ratio(""), do: nil

  defp parse_aspect_ratio(string) when is_binary(string) do
    case String.split(string, ":", parts: 2) do
      [w, h] ->
        case {parse_float(w), parse_float(h)} do
          {wf, hf} when is_number(wf) and is_number(hf) and hf != 0.0 -> wf / hf
          _ -> nil
        end

      [w] ->
        parse_float(w)
    end
  end
end
