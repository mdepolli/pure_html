defmodule PureHTML.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "parser robustness" do
    property "parsing never crashes on arbitrary strings" do
      check all(html <- string(:printable, max_length: 1000)) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end

    property "parsing is deterministic" do
      check all(html <- string(:printable, max_length: 500)) do
        assert PureHTML.parse(html) == PureHTML.parse(html)
      end
    end

    # NOTE: The parser currently crashes on invalid UTF-8 sequences.
    # This is a known limitation - HTML5 spec assumes valid encoding.

    property "parsing handles unicode strings" do
      check all(text <- string(:printable, max_length: 500)) do
        html = "<div>#{text}</div>"
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end
  end

  describe "parser output structure" do
    property "result is always a list of valid nodes" do
      check all(html <- html_fragment()) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
        assert Enum.all?(nodes, &valid_node?/1)
      end
    end
  end

  defp valid_node?({tag, attrs, children}) when is_binary(tag) and is_list(attrs) do
    is_list(children) and Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?(text) when is_binary(text), do: true
  defp valid_node?({:comment, _}), do: true
  defp valid_node?({:doctype, _, _, _}), do: true
  defp valid_node?(_), do: false

  # Custom generator for HTML-like fragments
  defp html_fragment do
    gen all(parts <- list_of(html_part(), max_length: 10)) do
      Enum.join(parts)
    end
  end

  defp html_part do
    one_of([
      # Plain text
      string(:alphanumeric, max_length: 20),
      # Simple tags
      gen_tag(),
      # Whitespace
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
