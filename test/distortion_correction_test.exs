defmodule Image.DistortionCorrection.Test do
  use ExUnit.Case, async: true
  import Image.TestSupport

  test "Image.distortion_correction/5" do
    image_file = "gridlines_barrel.png"
    validate_file = "gridlines_barrel_corrected.png"

    image_path = image_path(image_file)
    validate_path = validate_path(validate_file)

    image = Image.open!(image_path)
    {:ok, corrected} = Image.LensCorrection.radial_distortion_correction(image, -0.007715, 0.086731, 0.0)

    # {:ok, _image} = Image.write(corrected, validate_path)
    assert_images_equal(corrected, validate_path)
  end
end
