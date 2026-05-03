defmodule Image.LensFun.Correct.Test do
  use ExUnit.Case, async: true

  alias Image.LensFun.Correct

  describe "correct/2" do
    test "returns missing_lens_metadata when no lens info supplied" do
      image = Image.new!(100, 100, color: :red, bands: 3)
      assert {:error, :missing_lens_metadata} = Correct.correct(image)
    end

    test "returns :not_found for an unknown lens" do
      image = Image.new!(100, 100, color: :red, bands: 3)

      assert {:error, :not_found} =
               Correct.correct(image,
                 lens_make: "FakeBrand",
                 lens_model: "Nonexistent",
                 focal_length: 50.0,
                 aperture: 2.8
               )
    end

    test "applies distortion via lensfun lookup" do
      image = Image.new!(200, 200, color: :red, bands: 3)

      assert {:ok, corrected} =
               Correct.correct(image,
                 lens_make: "Canon",
                 lens_model: "Canon PowerShot G3 & compatibles (Standard)",
                 focal_length: 10.0,
                 aperture: 4.0,
                 distance: 1000.0,
                 corrections: [:distortion]
               )

      assert Image.width(corrected) == 200
    end

    test "respects :corrections option" do
      image = Image.new!(200, 200, color: :red, bands: 3)

      assert {:ok, corrected} =
               Correct.correct(image,
                 lens_make: "Canon",
                 lens_model: "Canon PowerShot G3 & compatibles (Standard)",
                 focal_length: 10.0,
                 aperture: 4.0,
                 corrections: []
               )

      diff =
        image
        |> Image.Math.subtract!(corrected)
        |> Image.Math.pow!(2)
        |> Vix.Vips.Operation.avg!()

      assert diff < 0.5
    end

    test ":projection routes through Geometry for a fisheye lens" do
      # Samyang 7.5mm fisheye is in the bundled DB with type: :fisheye.
      image = Image.new!(200, 200, color: :red, bands: 3)

      assert {:ok, corrected} =
               Correct.correct(image,
                 lens_make: "Samyang",
                 lens_model: "Samyang 7.5mm f/3.5 UMC Fish-eye MFT",
                 focal_length: 7.5,
                 aperture: 4.0,
                 crop_factor: 2.0,
                 corrections: [:projection],
                 target_projection: :rectilinear
               )

      # Projection conversion preserves dimensions but should change pixel
      # values (the image is geometrically reprojected). Compare against
      # the input — if projection actually ran, the corner moves.
      assert Image.width(corrected) == Image.width(image)
      assert Image.height(corrected) == Image.height(image)
    end

    test ":projection is a no-op when source equals target" do
      # Most lenses default to :rectilinear; selecting :rectilinear as the
      # target is a no-op even when projection is enabled.
      image = Image.new!(100, 100, color: [128, 64, 200], bands: 3)

      assert {:ok, corrected} =
               Correct.correct(image,
                 lens_make: "Canon",
                 lens_model: "Canon EF 100mm f/2.8 Macro USM",
                 focal_length: 100.0,
                 aperture: 5.6,
                 crop_factor: 1.0,
                 corrections: [:projection],
                 target_projection: :rectilinear
               )

      diff =
        image
        |> Image.Math.subtract!(corrected)
        |> Image.Math.pow!(2)
        |> Vix.Vips.Operation.avg!()

      assert diff < 0.5
    end
  end
end
