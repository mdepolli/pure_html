defmodule PureHTML.ParseTest do
  use ExUnit.Case, async: true

  describe "parse_with_errors/2" do
    test "counts a missing doctype as a parse error" do
      # Arrange
      html = "<p>hello</p>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["hello"]}]}]}] = nodes
      assert error_count == 1
    end

    test "returns zero errors for a complete HTML5 document" do
      # Arrange
      html = "<!DOCTYPE html><html><head></head><body><p>hello</p></body></html>"

      # Act
      {_nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert error_count == 0
    end

    test "counts errors in fragment parsing" do
      # Arrange
      html = "</div>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "div")

      # Assert
      assert nodes == []
      assert error_count >= 1
    end
  end
end
