defmodule Image.LensCorrection.RegressionTest do
  use ExUnit.Case, async: true

  import Image.TestSupport

  alias Image.LensCorrection
  alias Image.LensCorrection.{Geometry, Tca}

  @rgb_path image_path("gridlines_rgb.png")

  test "vignette_correction/4 against golden image" do
    src = Image.open!(@rgb_path)
    {:ok, corrected} = LensCorrection.vignette_correction(src, -0.4, 0.1, -0.05)
    assert_images_equal(corrected, validate_path("vignette_corrected.png"))
  end

  test "linear TCA against golden image" do
    src = Image.open!(@rgb_path)
    {:ok, corrected} = Tca.linear_tca_correction(src, 1.002, 0.999)
    assert_images_equal(corrected, validate_path("tca_linear_corrected.png"))
  end

  test "poly3 TCA against golden image" do
    src = Image.open!(@rgb_path)

    {:ok, corrected} =
      Tca.poly3_tca_correction(src, %{
        vr: 1.0005,
        vb: 0.9995,
        cr: 0.0,
        cb: 0.0,
        br: 1.0e-5,
        bb: -1.0e-5
      })

    assert_images_equal(corrected, validate_path("tca_poly3_corrected.png"))
  end

  test "fisheye_to_rectilinear against golden image" do
    src = Image.open!(@rgb_path)
    diagonal = :math.sqrt(Image.width(src) ** 2 + Image.height(src) ** 2)
    focal = Geometry.focal_length_in_pixels(8.0, 1.5, diagonal)
    {:ok, corrected} = Geometry.fisheye_to_rectilinear(src, focal)
    assert_images_equal(corrected, validate_path("fisheye_rectilinear.png"))
  end

  test "equirectangular_to_rectilinear against golden image" do
    src = Image.open!(@rgb_path)
    diagonal = :math.sqrt(Image.width(src) ** 2 + Image.height(src) ** 2)
    focal = Geometry.focal_length_in_pixels(8.0, 1.5, diagonal)
    {:ok, corrected} = Geometry.equirectangular_to_rectilinear(src, focal)
    assert_images_equal(corrected, validate_path("equirect_rectilinear.png"))
  end
end
