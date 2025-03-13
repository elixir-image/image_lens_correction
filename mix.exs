defmodule ImageLensCorrection.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_lens_correction,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # {:image, "~> 0.59.0 or ~> 1.0"}
      {:image, path: "../image"}
    ]
  end

  defp preferred_cli_env() do
    []
  end

  def aliases do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "mix", "test"]
  defp elixirc_paths(:dev), do: ["lib", "mix", "bench"]
  defp elixirc_paths(:release), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]
end
