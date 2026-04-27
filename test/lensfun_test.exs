defmodule Image.LensFun.Test do
  use ExUnit.Case, async: true

  alias Image.LensFun

  describe "db/0" do
    test "loads cameras and lenses" do
      db = LensFun.db()
      assert is_map(db.cameras)
      assert is_map(db.lenses)
      assert map_size(db.cameras) > 0
      assert map_size(db.lenses) > 0
    end

    test "is cached on subsequent calls" do
      a = LensFun.db()
      b = LensFun.db()
      # Same persistent_term entry — identity guaranteed
      assert :erlang.term_to_binary(a) == :erlang.term_to_binary(b)
    end

    test "lens entries carry distinct a, b and c (regression: importer typo)" do
      db = LensFun.db()
      ptlens = find_ptlens_with_three_terms(db)
      refute is_nil(ptlens), "expected at least one ptlens entry with non-equal a/b/c"
      assert ptlens.terms.a != ptlens.terms.b or ptlens.terms.b != ptlens.terms.c
    end
  end

  describe "find_lens/3" do
    test "exact match returns the lens" do
      assert {:ok, lens} = LensFun.find_lens("Canon", "Canon EF 100mm f/2.8 Macro")
      assert lens.model =~ "100mm"
    end

    test "case-insensitive maker match" do
      assert {:ok, _} = LensFun.find_lens("canon", "Canon EF 100mm f/2.8 Macro")
    end

    test "fuzzy substring fallback" do
      assert {:ok, lens} = LensFun.find_lens("Canon", "EF 100mm")
      assert lens.model =~ "100mm"
    end

    test "unknown lens" do
      assert {:error, :not_found} = LensFun.find_lens("Canon", "Definitely Not Real")
    end

    test "unknown maker" do
      assert {:error, :not_found} = LensFun.find_lens("FakeBrand", "Whatever")
    end

    test "crop_factor option narrows the calibration set" do
      # Canon PowerShot G3 calibration crop ~= 4.843
      assert {:ok, lens} =
               LensFun.find_lens(
                 "Canon",
                 "Canon PowerShot G3 & compatibles (Standard)",
                 crop_factor: 4.843
               )

      assert_in_delta lens.crop_factor, 4.843, 0.01
    end
  end

  describe "search_lenses/2" do
    test "finds canon 100mm macro" do
      results = LensFun.search_lenses("canon 100 macro", maker: "Canon")
      assert length(results) > 0
      assert Enum.all?(results, fn {maker, _} -> maker == "Canon" end)
      assert Enum.any?(results, fn {_, lens} -> lens.model =~ "100mm" end)
    end

    test "respects :limit" do
      assert LensFun.search_lenses("canon", limit: 3) |> length() == 3
    end

    test ":has filters by capability" do
      tca_results = LensFun.search_lenses("", has: [:tca], limit: 1000)
      assert Enum.all?(tca_results, fn {_, lens} -> lens.tca != [] end)
    end

    test "no matches returns []" do
      assert [] = LensFun.search_lenses("zzz_no_such_lens_zzz")
    end
  end

  describe "find_camera/2" do
    test "returns crop factor" do
      assert {:ok, %{crop_factor: 1.0}} = LensFun.find_camera("Canon", "Canon EOS 5D Mark III")
    end

    test "unknown camera" do
      assert {:error, :not_found} = LensFun.find_camera("Canon", "Made-up Body")
    end
  end

  describe "interpolate_distortion/2" do
    setup do
      {:ok, lens} = LensFun.find_lens("Canon", "Canon PowerShot G3 & compatibles (Standard)")
      %{lens: lens}
    end

    test "exact focal returns the calibration unchanged", %{lens: lens} do
      assert {:ok, d} = LensFun.interpolate_distortion(lens, 9.094)
      assert d.focal_length == 9.094
      assert d.terms.a == 0.009637
      assert d.terms.b == -0.019881
    end

    test "between-focal interpolates", %{lens: lens} do
      assert {:ok, d} = LensFun.interpolate_distortion(lens, 10.0)
      # Between 9.094 (a=0.009637) and 10.188 (a=0.00983)
      assert d.terms.a > 0.0096 and d.terms.a < 0.011
    end

    test "below-range clamps to lowest", %{lens: lens} do
      assert {:ok, d} = LensFun.interpolate_distortion(lens, 1.0)
      assert d.focal_length == 7.188
    end

    test "above-range clamps to highest", %{lens: lens} do
      assert {:ok, d} = LensFun.interpolate_distortion(lens, 999.0)
      assert d.focal_length == 28.813
    end

    test "no calibration data" do
      assert {:error, :no_calibration} = LensFun.interpolate_distortion(%{distortion: []}, 50.0)
    end
  end

  describe "interpolate_vignetting/4" do
    setup do
      {:ok, lens} = LensFun.find_lens("Canon", "Canon PowerShot G3 & compatibles (Standard)")
      %{lens: lens}
    end

    test "exact match returns the calibration", %{lens: lens} do
      assert {:ok, v} = LensFun.interpolate_vignetting(lens, 7.2, 2.8, 1000.0)
      assert v.terms.k1 == -0.184
    end

    test "interpolated values stay finite", %{lens: lens} do
      assert {:ok, v} = LensFun.interpolate_vignetting(lens, 9.0, 4.0, 50.0)
      assert is_float(v.terms.k1)
      assert is_float(v.terms.k2)
      assert is_float(v.terms.k3)
    end
  end

  describe "metrics_from_exif_and_options/2" do
    test "options take precedence" do
      image = Image.new!(10, 10, color: :red)

      assert {:ok, metrics} =
               LensFun.metrics_from_exif_and_options(image,
                 make: "Canon",
                 model: "EOS 5D Mark III",
                 lens_make: "Canon",
                 lens_model: "EF 50mm",
                 focal_length: 50.0,
                 aperture: 2.8,
                 crop_factor: 1.0
               )

      assert metrics.make == "Canon"
      assert metrics.lens_model == "EF 50mm"
      assert metrics.focal_length == 50.0
      assert metrics.aperture == 2.8
      assert metrics.crop_factor == 1.0
      # Default
      assert metrics.distance == 1000.0
    end

    test "lens_make defaults to make" do
      image = Image.new!(10, 10, color: :red)
      {:ok, metrics} = LensFun.metrics_from_exif_and_options(image, make: "Canon")
      assert metrics.lens_make == "Canon"
    end

    test "image without EXIF returns nil fields" do
      image = Image.new!(10, 10, color: :red)
      {:ok, metrics} = LensFun.metrics_from_exif_and_options(image)
      assert metrics.make == nil
      assert metrics.model == nil
      assert metrics.focal_length == nil
    end

    test "crop_factor falls back to camera DB lookup" do
      image = Image.new!(10, 10, color: :red)

      {:ok, metrics} =
        LensFun.metrics_from_exif_and_options(image,
          make: "Canon",
          model: "Canon EOS 5D Mark III"
        )

      assert metrics.crop_factor == 1.0
    end
  end

  defp find_ptlens_with_three_terms(db) do
    db.lenses
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn lens -> Enum.filter(lens.distortion, &(&1.model == :ptlens)) end)
    |> Enum.find(fn d ->
      vals = [d.terms.a, d.terms.b, d.terms.c]
      Enum.uniq(vals) == vals and Enum.any?(vals, &(&1 != 0.0))
    end)
  end
end
