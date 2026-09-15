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
  end
end
