defmodule PureHTML.Html5libDatParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

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
