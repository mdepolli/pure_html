defmodule PureHTML.Html5libDatParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libEncodingTests, as: Encoding
  alias PureHTML.Test.Html5libSerializerTests, as: Ser
  alias PureHTML.Test.Html5libTokenizerTests, as: Tok
  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  describe "list_test_files/0" do
    test "lists tree-construction fixtures recursively under their relative names" do
      names = Enum.map(H5.list_test_files(), &H5.fixture_name/1)

      assert "webkit01" in names
      assert "scripted/webkit01" in names
    end

    test "lists encoding fixtures recursively under their relative names" do
      names = Enum.map(Encoding.list_test_files(), &Encoding.fixture_name/1)

      assert "tests1" in names
      assert "scripted/tests1" in names
    end

    test "every scripted fixture is listed and classified as needing script execution" do
      assert_scripted_classified(H5)
      assert_scripted_classified(Encoding)
    end

    test "lists every regular file under each suite dir except known non-fixtures" do
      # README.md is the html5lib suite readme, not a fixture.
      # encoding/chardet/test_big5.txt is a Big5 sample for upstream's chardet
      # tests, not a sniffing fixture.
      assert_lists_every_regular_file(H5, ~w(README.md))
      assert_lists_every_regular_file(Encoding, ~w(chardet/test_big5.txt))
      assert_lists_every_regular_file(Tok, ~w(README.md))
      assert_lists_every_regular_file(Ser, [])
    end
  end

  describe "parse_file/1 expected errors" do
    test "does not count #new-errors as extra expected errors" do
      # Arrange
      path = Path.join(H5.test_dir(), "comments01.dat")

      # Act
      tests = H5.parse_file(path)
      test = Enum.find(tests, &(&1.data == "FOO<!-- BAR --!>BAZ"))

      # Assert
      # #errors has two lines; #new-errors renames the second. Expected count is 2.
      assert length(test.errors) == 2
    end

    test "every tree correction names an existing fixture and lands on exactly one case" do
      # Arrange
      files = Path.wildcard(Path.join(H5.corrections_dir(), "**/*.dat"))
      assert files != []

      for corrections_path <- files do
        rel = Path.relative_to(corrections_path, H5.corrections_dir())
        fixture_path = Path.join(H5.test_dir(), rel)
        assert File.exists?(fixture_path), "#{rel} corrects a fixture that does not exist"

        # Act: parse_file/1 raises for a stale or unmatched block
        corrections = H5.parse_corrections(corrections_path)
        tests = H5.parse_file(fixture_path)
        corrected = Enum.filter(tests, &(&1.spec != nil))

        # Assert
        assert length(corrected) == length(corrections), rel

        for correction <- corrections do
          assert correction.spec =~ "walk in WALKS.md", inspect(correction.data)
          assert correction.spec =~ "https://html.spec.whatwg.org/multipage/parsing.html#"

          assert Enum.all?(correction.errors, &String.starts_with?(&1, "text:")),
                 inspect(correction.data)
        end

        for test <- tests -- corrected do
          refute Enum.any?(test.errors, &String.starts_with?(&1, "text:")), inspect(test.data)
        end
      end
    end

    test "every tokenizer correction names an existing fixture and lands on exactly one case" do
      # Arrange
      files = Path.wildcard(Path.join(Tok.corrections_dir(), "**/*.json"))
      assert files != []

      for corrections_path <- files do
        rel = Path.relative_to(corrections_path, Tok.corrections_dir())
        name = Path.rootname(rel, ".json")
        fixture_path = Path.join(Tok.test_dir(), name <> ".test")
        assert File.exists?(fixture_path), "#{name} corrects a fixture that does not exist"

        # Act: parse_file/1 raises for a stale or unmatched entry
        corrections = Tok.parse_corrections(corrections_path)
        {tests, _mode} = Tok.parse_file(fixture_path)
        corrected = Enum.filter(tests, &Map.has_key?(&1, "spec"))

        # Assert
        assert length(corrected) == length(corrections), name

        for correction <- corrections do
          assert correction["spec"] =~ "walk in WALKS.md", inspect(correction["input"])
          assert Map.has_key?(correction, "upstream"), inspect(correction["input"])
        end
      end
    end
  end

  describe "skip_reason/1" do
    @options_reason "uses html5lib serializer options the fragment algorithm does not have"

    test "runs whitespace cases whose text is only under html5lib space-preserve elements" do
      # Arrange
      cases = whitespace_cases()

      # Act + Assert
      for desc <- [
            "text within <pre>",
            "text within <pre>, with inner markup",
            "text within <textarea>",
            "text within <script>",
            "text within <style>"
          ] do
        assert Ser.skip_reason(case_named(cases, desc)) == nil, desc
      end
    end

    test "skips whitespace cases whose strip_whitespace option would change the text" do
      # Arrange
      cases = whitespace_cases()

      # Act + Assert
      for desc <- [
            "bare text with leading spaces",
            "bare text with trailing spaces",
            "bare text with inner spaces"
          ] do
        assert Ser.skip_reason(case_named(cases, desc)) == @options_reason, desc
      end
    end

    test "still skips injectmeta cases that use html5lib serializer options" do
      # Arrange
      [test | _] = Ser.parse_file(Path.join(Ser.test_dir(), "injectmeta.test"))

      # Act + Assert
      assert Ser.skip_reason(test) == @options_reason
    end

    @running_keys [
      {"core", "void element (as EmptyTag token)"},
      {"core", "void element (as StartTag token)"},
      {"core", "doctype in error"},
      {"core", "character data"},
      {"core", "doctype"},
      {"whitespace", "text within <pre>"},
      {"whitespace", "text within <pre>, with inner markup"},
      {"whitespace", "text within <textarea>"},
      {"whitespace", "text within <script>"},
      {"whitespace", "text within <style>"}
    ]

    @skip_totals %{
      "uses html5lib serializer options the fragment algorithm does not have" => 21,
      "expects an unclosed start tag; the fragment algorithm closes every non-void element" => 44,
      "has an end tag with no open element; the fragment algorithm serializes a tree" => 151,
      "expects a PUBLIC/SYSTEM doctype; the fragment algorithm writes the name only" => 3,
      "expects an omitted end tag; the fragment algorithm closes every non-void element" => 1
    }

    test "the fragment-algorithm cases are exactly the ten keyed by file and description" do
      # Arrange / Act
      running =
        for path <- Ser.list_test_files(),
            test <- Ser.parse_file(path),
            Ser.skip_reason(test) == nil do
          {Ser.fixture_name(path), test["description"]}
        end

      # Assert
      assert Enum.sort(running) == Enum.sort(@running_keys)
    end

    test "skip totals by reason" do
      # Arrange / Act
      totals =
        for path <- Ser.list_test_files(),
            test <- Ser.parse_file(path),
            reason = Ser.skip_reason(test),
            reason != nil,
            reduce: %{} do
          acc -> Map.update(acc, reason, 1, &(&1 + 1))
        end

      # Assert
      assert totals == @skip_totals
      assert Enum.sum(Map.values(totals)) == 220
    end
  end

  defp whitespace_cases do
    Ser.parse_file(Path.join(Ser.test_dir(), "whitespace.test"))
  end

  defp case_named(cases, description) do
    Enum.find(cases, &(&1["description"] == description)) ||
      flunk("no serializer case #{inspect(description)}")
  end

  defp assert_lists_every_regular_file(mod, non_fixtures) do
    # Arrange
    listed = Enum.sort(mod.list_test_files())

    skipped =
      Enum.map(non_fixtures, fn rel ->
        path = Path.join(mod.test_dir(), rel)
        assert File.regular?(path), "#{rel} is on the non-fixture list but is not a file"
        path
      end)

    on_disk =
      mod.test_dir()
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&(&1 in skipped))
      |> Enum.sort()

    # Assert
    assert on_disk != []
    assert listed == on_disk
  end

  defp assert_scripted_classified(mod) do
    # Arrange
    listed = mod.list_test_files()

    on_disk =
      mod.test_dir()
      |> Path.join("scripted/**/*.dat")
      |> Path.wildcard()
      |> Enum.sort()

    # Act
    {scripted, rest} = Enum.split_with(listed, &mod.needs_script_execution?/1)

    # Assert
    assert on_disk != []
    assert Enum.sort(scripted) == on_disk
    refute Enum.any?(rest, &mod.needs_script_execution?/1)
  end
end
