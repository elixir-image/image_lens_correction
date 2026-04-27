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
  end
end
