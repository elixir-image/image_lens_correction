defmodule ImageLensCorrection.MixProject do
  use Mix.Project

  @version "0.1.0"
  @app_name :image_lens_correction
  @source_url "https://github.com/elixir-image/image_lens_correction"

  def project do
    [
      app: @app_name,
      version: @version,
      elixir: "~> 1.17",
      description: description(),
      package: package(),
      deps: deps(),
      docs: docs(),
      source_url: @source_url,
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore_warnings",
        plt_add_apps: ~w(mix ex_unit)a,
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    Lens corrections (radial distortion, vignetting, lateral chromatic aberration
    and geometric projection) for images created or processed with the `image`
    library, driven by calibration data from the `lensfun` project.
    """
  end

  defp deps do
    [
      {:image, "~> 0.59 or ~> 1.0"},
      # Used by `Image.LensFun.Importer` to read the lensfun XML
      # database; pulled transitively by `:image` for XMP metadata so
      # cannot be scoped to `:dev` here.
      {:sweet_xml, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false}
    ] ++ maybe_json_polyfill()
  end

  defp maybe_json_polyfill do
    if Code.ensure_loaded?(:json) do
      []
    else
      [{:json_polyfill, "~> 0.2 or ~> 1.0"}]
    end
  end

  defp package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: links(),
      files: [
        "lib",
        "priv/lensfun/lensfun.etf",
        "guides",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ]
    ]
  end

  defp links do
    %{
      "GitHub" => @source_url,
      "Readme" => "#{@source_url}/blob/v#{@version}/README.md",
      "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md",
      "Image" => "https://github.com/elixir-image/image",
      "Lensfun" => "https://github.com/lensfun/lensfun"
    }
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extra_section: "Guides",
      extras: [
        "README.md",
        "guides/lens_corrections.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      formatters: ["html", "markdown"],
      groups_for_docs: [
        Distortion: &(&1[:subject] == "Distortion"),
        Database: &(&1[:subject] == "Database")
      ],
      groups_for_modules: [
        "Correction primitives": [
          Image.LensCorrection,
          Image.LensCorrection.Tca,
          Image.LensCorrection.Geometry
        ],
        "Database lookup": [
          Image.LensFun,
          Image.LensFun.Correct,
          Image.LensFun.Importer
        ]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "lensfun", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "lensfun"]
  defp elixirc_paths(_), do: ["lib"]
end
