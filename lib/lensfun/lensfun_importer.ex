defmodule Image.LensFun.Importer do
  @moduledoc false

  @default_lensfun_db "../lensfun"
  @db_location "/data/db/*.xml"

  def import(lensfun_git_dir \\ @default_lensfun_db) when is_binary(lensfun_git_dir) do
    with {:ok, lensfun_git_dir} <- resolve_lensfun_db_location(lensfun_git_dir) do
      lens_db =
        lensfun_git_dir
        |> Path.wildcard()
        |> Enum.reduce(%{}, fn path, acc ->
          IO.puts "Processing #{path}"
          Enum.reduce parse_xml(path), acc, fn {maker, lens_data}, acc ->
            Map.put(acc, maker, lens_data)
          end
        end)
        |> :erlang.term_to_binary()

      path = Image.LensFun.db_path()
      File.write!(path, lens_db)
      IO.puts "Saved lensfun database to #{inspect path}"
    end
  end

  def resolve_lensfun_db_location(lensfun_git_dir) do
    cond do
      File.exists?(lensfun_git_dir) ->
        {:ok, Path.join(lensfun_git_dir, @db_location)}

      lensfun_git_dir == @default_lensfun_db ->
        {:error,
          """
          lensfun git repo not found at the default location #{inspect @default_lensfun_db}.

          Please clone https://github.com/lensfun/lensfun" and call Image.LensFun.Importer.import/1
          with that directory as the parameter.
          """
        }

      true ->
        {:error, "lensfun git repo not found at #{inspect lensfun_git_dir}."}
    end
  end

  def parse_xml(path) do
    import SweetXml

    path
    |> File.read!
    |> xpath(
      ~x"//lens"l,
      maker:  ~x"./maker[not(@lang)]/text()"s,
      crop_factor: ~x"./cropfactor/text()"s |> transform_by(&to_float/1),
      lens: ~x"./model[not(@lang)]/text()"s,
      distortion: [
        ~x"./calibration/distortion"l,
        focal_length: ~x"@focal"s |> transform_by(&to_integer/1),
        model: ~x"@model"s,
        a: ~x"@a"s |> transform_by(&to_float/1),
        b: ~x"@a"s |> transform_by(&to_float/1),
        c: ~x"@a"s |> transform_by(&to_float/1),
        k1: ~x"@k1"s |> transform_by(&to_float/1),
        k2: ~x"@k2"s |> transform_by(&to_float/1),
        ],
      vignetting: [
        ~x"./calibration/vignetting[@k1]"l,
        focal_length: ~x"@focal"s  |> transform_by(&to_integer/1),
        model: ~x"@model"s,
        aperture: ~x"@aperture"s |> transform_by(&to_float/1),
        distance: ~x"@distance"s |> transform_by(&to_float/1),
        k1: ~x"@k1"s |> transform_by(&to_float/1),
        k2: ~x"@k2"s |> transform_by(&to_float/1),
        k3: ~x"@k3"s |> transform_by(&to_float/1),
      ]
    )
    |> Enum.group_by(&(&1.maker))
    |> Enum.map(fn {maker, lens} ->
      lens =
        lens
        |> Enum.group_by(&(&1.lens), &(Map.take(&1, [:crop_factor, :distortion, :vignetting])))
        |> Enum.map(fn {lens, data} ->
          data =
            Enum.map(data, fn map ->
              key =
                map.crop_factor

              value =
                map
                |> Map.take([:distortion, :vignetting])
                |> normalize_distortion()
              {key, value}
            end)
            |> Map.new()

          {lens, data}
        end)
        |> Map.new()
      {maker, lens}
    end)
  end

  # https://lensfun.github.io/calibration-tutorial/lens-distortion.html
  defp normalize_distortion(map) do
    distortion =
      map
      |> Map.fetch!(:distortion)
      |> Enum.map(fn
        %{model: "poly3"} = distortion ->
          distortion
          |> Map.delete(:b)
          |> Map.delete(:a)
          |> Map.delete(:c)
          |> Map.delete(:k2)

        # Is this correct?
        %{model: "poly5"} = distortion ->
          distortion
          |> Map.delete(:b)
          |> Map.delete(:a)
          |> Map.delete(:c)

        %{model: "ptlens"} = distortion ->
          distortion
          |> Map.delete(:k1)
          |> Map.delete(:k2)
      end)
      |> Enum.reverse()

    Map.put(map, :distortion, distortion)
  end

  defp to_float("") do
    nil
  end

  defp to_float(string) do
    case String.split(string, ".") do
      ["-", fraction] -> String.to_float("-0." <> fraction)
      [_integer, _fraction] -> String.to_float(string)
      [integer] -> String.to_float(integer <> ".0")
    end
  end

  defp to_integer(string) do
    case String.split(string, ".") do
      [integer] -> String.to_integer(integer)
      [integer, "0"] -> String.to_integer(integer)
      _other -> String.to_float(string)
    end
  end
end
