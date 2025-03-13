defmodule ImageLensCorrection.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_lens_correction,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
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
end
