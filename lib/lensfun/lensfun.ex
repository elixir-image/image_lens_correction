defmodule Image.LensFun do
  alias Vix.Vips.Image, as: Vimage

  @app_name Mix.Project.config[:app]
  @db_save_file "priv/lensfun/lensfun.etf"

  def db_path do
    Application.app_dir(@app_name, @db_save_file)
  end

  def db do
    db_path()
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  # Find the nearest distortion metrics
  # based upon exif if possible.

  def distortion(%Vimage{} = image, options) do
    {maker, crop_factor, focal_length} = metrics_from_exif_and_options(image, options)
  end

  def vignetting(%Vimage{} = image, options) do

  end

  def metrics_from_exif_and_options(image, options) do

  end
end