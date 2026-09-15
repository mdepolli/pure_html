defmodule PureHTML.Html5libDatParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libEncodingTests, as: Encoding
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

    test "patched cases carry the spec citation and the text's error lines" do
      # Arrange
      webkit_path = Path.join(H5.test_dir(), "webkit02.dat")
      adoption_path = Path.join(H5.test_dir(), "adoption02.dat")

      citation =
        "walk in CLAUDE.md; " <>
          "https://html.spec.whatwg.org/multipage/parsing.html" <>
          "#parsing-main-inbody #parsing-main-intable #adoption-agency-algorithm — " <>
          "fixture #errors contradicted the text; lines below are the text's count"

      webkit_cases = [
        {"<select><button><selectedcontent></button><option>X", 3},
        {"<select><button><selectedcontent></button><option>x<i>i<b>ib</i>b", 4},
        {"<select><button><selectedcontent></button><option>X<option>Y", 3},
        {"<select><button><selectedcontent></button><option>X<option selected>Y", 3},
        {"<font><select><option>a</option></font></select>", 3}
      ]

      # Act
      webkit_src = File.read!(H5.source_path(webkit_path))
      adoption_src = File.read!(H5.source_path(adoption_path))
      webkit_tests = H5.parse_file(webkit_path)
      adoption_tests = H5.parse_file(adoption_path)

      # Assert
      assert H5.source_path(webkit_path) != webkit_path
      assert H5.source_path(adoption_path) != adoption_path

      for {data, count} <- webkit_cases do
        assert webkit_src =~ "#data\n#{data}\n#spec\n#{citation}\n#errors\n"
        assert_text_errors(webkit_tests, data, count)
      end

      adoption_data = "<nobr><table><marquee></table><nobr>"
      assert adoption_src =~ "#data\n#{adoption_data}\n#spec\n#{citation}\n#errors\n"
      test = assert_text_errors(adoption_tests, adoption_data, 4)
      refute Enum.any?(test.errors, &String.contains?(&1, "end-tag-too-early-named"))
    end
  end

  defp assert_text_errors(tests, data, count) do
    test = Enum.find(tests, &(&1.data == data))
    assert test, "missing fixture with #data #{inspect(data)}"
    assert length(test.errors) == count
    assert Enum.all?(test.errors, &String.starts_with?(&1, "text:"))
    test
  end
end
