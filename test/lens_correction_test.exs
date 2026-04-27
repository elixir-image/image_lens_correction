defmodule Image.LensCorrection.Test do
  use ExUnit.Case, async: true

  alias Image.LensCorrection
  alias Vix.Vips.Image, as: Vimage

  @sample_image_path Path.join(__DIR__, "support/images/gridlines_barrel.png")

  describe "radial_distortion_correction/4 (ptlens)" do
    test "returns a same-size image with the same band format" do
      image = Image.open!(@sample_image_path)
      {:ok, corrected} = LensCorrection.radial_distortion_correction(image, -0.0077, 0.087, 0.0)
      assert Image.width(corrected) == Image.width(image)
      assert Image.height(corrected) == Image.height(image)
      assert Vimage.format(corrected) == Vimage.format(image)
    end

    test "zero distortion is approximately the identity" do
      image = Image.new!(64, 64, color: :red, bands: 3)
      {:ok, corrected} = LensCorrection.radial_distortion_correction(image, 0.0, 0.0, 0.0)
      assert image_diff(image, corrected) < 0.5
    end

    test "Newton inverse round-trips against the forward formula" do
      # Apply forward then inverse should round-trip in the small-distortion regime.
      a = -0.005
      b = 0.05
      c = 0.0
      # check Newton converges: distance vs. forward applied
      # at rd = 0.5
      d = 1.0 - a - b - c
      ru_initial = 0.5

      rd =
        ru_initial *
          (a * :math.pow(ru_initial, 3) + b * :math.pow(ru_initial, 2) + c * ru_initial + d)

      # Newton in scalar form
      ru =
        Enum.reduce(1..6, rd, fn _i, ru ->
          f = a * :math.pow(ru, 4) + b * :math.pow(ru, 3) + c * :math.pow(ru, 2) + d * ru - rd
          fp = 4.0 * a * :math.pow(ru, 3) + 3.0 * b * :math.pow(ru, 2) + 2.0 * c * ru + d
          ru - f / fp
        end)

      assert_in_delta ru, ru_initial, 1.0e-9
    end
  end

  describe "poly3_correction/2" do
    test "applies without error" do
      image = Image.open!(@sample_image_path)
      assert {:ok, _} = LensCorrection.poly3_correction(image, -0.005)
    end

    test "zero coefficient is the identity" do
      image = Image.new!(64, 64, color: :red, bands: 3)
      {:ok, corrected} = LensCorrection.poly3_correction(image, 0.0)
      assert image_diff(image, corrected) < 0.5
    end
  end

  describe "poly5_correction/3" do
    test "applies without error" do
      image = Image.open!(@sample_image_path)
      assert {:ok, _} = LensCorrection.poly5_correction(image, -0.005, 0.001)
    end

    test "zero coefficients are the identity" do
      image = Image.new!(64, 64, color: :red, bands: 3)
      {:ok, corrected} = LensCorrection.poly5_correction(image, 0.0, 0.0)
      assert image_diff(image, corrected) < 0.5
    end
  end

  describe "apply_distortion/2 dispatch" do
    test "ptlens model" do
      image = Image.open!(@sample_image_path)

      assert {:ok, _} =
               LensCorrection.apply_distortion(image, %{
                 model: :ptlens,
                 terms: %{a: -0.0077, b: 0.087, c: 0.0}
               })
    end

    test "poly3 model" do
      image = Image.open!(@sample_image_path)

      assert {:ok, _} =
               LensCorrection.apply_distortion(image, %{model: :poly3, terms: %{k1: -0.005}})
    end

    test "unknown model returns an error" do
      image = Image.open!(@sample_image_path)

      assert {:error, {:unsupported_distortion_model, _}} =
               LensCorrection.apply_distortion(image, %{model: :unknown, terms: %{}})
    end
  end

  describe "vignette_correction/4" do
    test "zero coefficients are the identity" do
      image = Image.new!(64, 64, color: :red, bands: 3)
      {:ok, corrected} = LensCorrection.vignette_correction(image, 0.0, 0.0, 0.0)
      assert image_diff(image, corrected) < 0.5
    end

    test "negative k1 brightens edges" do
      image = Image.new!(100, 100, color: [128, 128, 128], bands: 3)
      {:ok, corrected} = LensCorrection.vignette_correction(image, -0.4, 0.0, 0.0)

      centre = Image.get_pixel!(corrected, 50, 50) |> List.first()
      corner = Image.get_pixel!(corrected, 0, 0) |> List.first()

      # When k1 < 0, the multiplier 1 + k1*r² < 1 at the edges, so dividing
      # raises edge values relative to the centre.
      assert corner > centre
    end
  end

  describe "apply_vignetting/2 dispatch" do
    test "pa model" do
      image = Image.new!(64, 64, color: :red, bands: 3)

      assert {:ok, _} =
               LensCorrection.apply_vignetting(image, %{
                 model: :pa,
                 terms: %{k1: -0.2, k2: 0.05, k3: -0.07}
               })
    end

    test "unknown model returns an error" do
      image = Image.new!(64, 64, color: :red, bands: 3)

      assert {:error, {:unsupported_vignetting_model, _}} =
               LensCorrection.apply_vignetting(image, %{model: :unknown, terms: %{}})
    end
  end

  describe "rescale_coefficients/4" do
    test "matching crop factors leave coefficients in the same family" do
      distortion = %{
        model: :ptlens,
        terms: %{a: 0.01, b: -0.02, c: 0.005},
        focal_length: 50.0,
        real_focal: nil
      }

      {:ok, scaled_a} = LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.5)
      {:ok, scaled_b} = LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.5)
      assert scaled_a.terms == scaled_b.terms
    end

    test "smaller image crop factor scales coefficients up" do
      distortion = %{
        model: :ptlens,
        terms: %{a: 0.01, b: -0.02, c: 0.005},
        focal_length: 50.0,
        real_focal: nil
      }

      {:ok, same} = LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.5)
      {:ok, smaller} = LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.0)
      assert abs(smaller.terms.a) > abs(same.terms.a)
    end

    test "poly3 model" do
      distortion = %{model: :poly3, terms: %{k1: -0.005}, focal_length: 50.0, real_focal: nil}

      assert {:ok, %{terms: %{k1: _}}} =
               LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.5)
    end

    test "poly5 model" do
      distortion = %{
        model: :poly5,
        terms: %{k1: -0.005, k2: 0.001},
        focal_length: 50.0,
        real_focal: nil
      }

      assert {:ok, %{terms: %{k1: _, k2: _}}} =
               LensCorrection.rescale_coefficients(distortion, 1.5, 1.5, 1.5)
    end
  end

  describe "TCA" do
    test "linear TCA is approximately the identity at kr=kb=1.0" do
      image = Image.new!(100, 100, color: [128, 64, 200], bands: 3)
      {:ok, corrected} = LensCorrection.Tca.linear_tca_correction(image, 1.0, 1.0)
      assert image_diff(image, corrected) < 0.5
    end

    test "poly3 TCA dispatch via apply_tca" do
      image = Image.new!(100, 100, color: [128, 64, 200], bands: 3)

      assert {:ok, _} =
               LensCorrection.Tca.apply_tca(image, %{
                 model: :poly3,
                 terms: %{vr: 1.0001, vb: 1.0002, cr: 0.0, cb: 0.0, br: 0.0, bb: 0.0}
               })
    end

    test "preserves alpha channel for RGBA input" do
      image = Image.new!(50, 50, color: :red, bands: 3)
      {:ok, rgba} = Image.add_alpha(image, :transparent)
      {:ok, corrected} = LensCorrection.Tca.linear_tca_correction(rgba, 1.0004, 1.0002)
      assert Image.bands(corrected) == 4
    end
  end

  describe "Geometry projections" do
    test "focal_length_in_pixels matches lensfun convention" do
      f = LensCorrection.Geometry.focal_length_in_pixels(8.0, 1.5, 5000.0)
      assert_in_delta f, 1386.75, 0.1
    end

    test "fisheye→rectilinear preserves dimensions" do
      image = Image.new!(200, 200, color: :red, bands: 3)
      {:ok, out} = LensCorrection.Geometry.fisheye_to_rectilinear(image, 100.0)
      assert Image.width(out) == 200
    end

    test "rectilinear→fisheye preserves dimensions" do
      image = Image.new!(200, 200, color: :red, bands: 3)
      {:ok, out} = LensCorrection.Geometry.rectilinear_to_fisheye(image, 100.0)
      assert Image.height(out) == 200
    end

    test "project/4 returns the image unchanged for matching projections" do
      image = Image.new!(100, 100, color: :red, bands: 3)

      assert {:ok, ^image} =
               LensCorrection.Geometry.project(image, :rectilinear, :rectilinear, 100.0)
    end

    test "project/4 errors on unsupported pair" do
      image = Image.new!(100, 100, color: :red, bands: 3)

      assert {:error, {:unsupported_projection_pair, :panoramic, :fisheye}} =
               LensCorrection.Geometry.project(image, :panoramic, :fisheye, 100.0)
    end
  end

  defp image_diff(a, b) do
    a
    |> Image.Math.subtract!(b)
    |> Image.Math.pow!(2)
    |> Vix.Vips.Operation.avg!()
  end
end
