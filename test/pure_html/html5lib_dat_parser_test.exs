defmodule PureHTML.Html5libDatParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libEncodingTests, as: Encoding
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
          assert correction.spec =~ "walk in CLAUDE.md", inspect(correction.data)
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
      files = Path.wildcard(Path.join(Tok.corrections_dir(), "*.json"))
      assert files != []

      for corrections_path <- files do
        name = Path.basename(corrections_path, ".json")
        fixture_path = Path.join(Tok.test_dir(), name <> ".test")
        assert File.exists?(fixture_path), "#{name} corrects a fixture that does not exist"

        # Act: parse_file/1 raises for a stale or unmatched entry
        corrections = Tok.parse_corrections(corrections_path)
        {tests, _mode} = Tok.parse_file(fixture_path)
        corrected = Enum.filter(tests, &Map.has_key?(&1, "spec"))

        # Assert
        assert length(corrected) == length(corrections), name

        for correction <- corrections do
          assert correction["spec"] =~ "walk in CLAUDE.md", inspect(correction["input"])
          assert Map.has_key?(correction, "upstream"), inspect(correction["input"])
        end
      end
    end
  end
end
