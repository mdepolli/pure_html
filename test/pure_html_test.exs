defmodule PureHTMLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "parse/2" do
    property "never crashes on arbitrary strings" do
      check all(html <- string(:printable, max_length: 1000)) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end

    property "is deterministic" do
      check all(html <- string(:printable, max_length: 500)) do
        assert PureHTML.parse(html) == PureHTML.parse(html)
      end
    end

    # The parser currently crashes on invalid UTF-8. HTML5 assumes valid encoding.
    property "handles unicode strings" do
      check all(text <- string(:printable, max_length: 500)) do
        html = "<div>#{text}</div>"
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end

    property "returns a list of valid nodes" do
      check all(html <- html_fragment()) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
        assert Enum.all?(nodes, &valid_node?/1)
      end
    end
  end

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

    test "counts an HTML start tag in SVG foreign content as a parse error" do
      # Arrange
      html = "<p>"

      # Act
      {_nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg svg")

      # Assert
      assert error_count == 1
    end

    test "counts an unknown named character reference as a parse error" do
      # Arrange
      html = "<!DOCTYPE html><html><body>&AMp;</body></html>"

      # Act
      {_nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert error_count == 1
    end

    test "counts a stray SVG end tag in an SVG fragment as a parse error" do
      # Arrange
      html = "</svg>X"

      # Act
      {_nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg svg")

      # Assert
      assert error_count == 1
    end
  end

  describe "query/2" do
    test "delegates to Query.find/2" do
      # Arrange
      html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")

      # Act
      result = PureHTML.query(html, ".intro")

      # Assert
      assert result == [{"p", [{"class", "intro"}], ["Hello"]}]
    end
  end

  describe "query_one/2" do
    test "delegates to Query.find_one/2" do
      # Arrange
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")

      # Act
      result = PureHTML.query_one(html, "li")

      # Assert
      assert result == {"li", [], ["A"]}
    end

    test "returns nil when no match" do
      # Arrange
      html = PureHTML.parse("<div><p>Hello</p></div>")

      # Act
      result = PureHTML.query_one(html, ".missing")

      # Assert
      assert result == nil
    end
  end

  describe "children/2" do
    test "delegates to Query.children/2" do
      # Arrange
      node = {"div", [], [{"p", [], ["Hello"]}]}

      # Act
      result = PureHTML.children(node)

      # Assert
      assert result == [{"p", [], ["Hello"]}]
    end
  end

  describe "text/2" do
    test "delegates to Query.text/2" do
      # Arrange
      html = PureHTML.parse("<p>Hello <strong>World</strong></p>")

      # Act
      result = PureHTML.text(html)

      # Assert
      assert result == "Hello World"
    end

    test "delegates with options" do
      # Arrange
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")

      # Act
      result = PureHTML.text(html, separator: ", ")

      # Assert
      assert result == "A, B"
    end
  end

  describe "attr/2" do
    test "delegates to Query.attr/2" do
      # Arrange
      node = {"a", [{"href", "/home"}], ["Home"]}

      # Act
      result = PureHTML.attr(node, "href")

      # Assert
      assert result == "/home"
    end
  end

  describe "attribute/2" do
    test "delegates to Query.attribute/2" do
      # Arrange
      nodes = [{"a", [{"href", "/one"}], []}, {"a", [{"href", "/two"}], []}]

      # Act
      result = PureHTML.attribute(nodes, "href")

      # Assert
      assert result == ["/one", "/two"]
    end
  end

  describe "attribute/3" do
    test "delegates to Query.attribute/3" do
      # Arrange
      html = PureHTML.parse("<div><a href='/link'>Link</a></div>")

      # Act
      result = PureHTML.attribute(html, "a", "href")

      # Assert
      assert result == ["/link"]
    end
  end

  defp valid_node?({tag, attrs, children}) when is_binary(tag) and is_list(attrs) do
    is_list(children) and Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?(text) when is_binary(text), do: true
  defp valid_node?({:comment, _}), do: true
  defp valid_node?({:doctype, _, _, _}), do: true
  defp valid_node?(_), do: false

  defp html_fragment do
    gen all(parts <- list_of(html_part(), max_length: 10)) do
      Enum.join(parts)
    end
  end

  defp html_part do
    one_of([
      string(:alphanumeric, max_length: 20),
      gen_tag(),
      constant(" "),
      constant("\n")
    ])
  end

  defp gen_tag do
    tags = ~w(div span p a b i em strong ul li table tr td th br hr img input)

    gen all(
          tag <- member_of(tags),
          has_close <- boolean()
        ) do
      if has_close do
        "<#{tag}></#{tag}>"
      else
        "<#{tag}>"
      end
    end
  end
end
