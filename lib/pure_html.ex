defmodule PureHTML do
  @moduledoc """
  A pure Elixir HTML5 parser with CSS selector querying.

  PureHTML parses HTML strings into a tree of nodes and provides functions
  to query, traverse, and serialize them back to HTML.

  ## Parsing

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}]

  ## Querying

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")
      iex> PureHTML.query(html, ".intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

  ## Serializing

      iex> [{"p", [], ["Hello"]}] |> PureHTML.to_html()
      "<p>Hello</p>"

  ## Node Format

  Nodes are represented as tuples compatible with [Floki](https://hex.pm/packages/floki):

  - `{tag, attrs, children}` - Element with tag name, attribute list, and children
  - `{:doctype, name, public_id, system_id}` - DOCTYPE declaration
  - `{:comment, text}` - HTML comment
  - `"text"` - Text content (binary string)

  Attributes are lists of `{name, value}` tuples, sorted alphabetically.
  """

  alias PureHTML.{Query, Serializer, Tokenizer, TreeBuilder}

  @doc """
  Parses an HTML string into a list of nodes.

  Returns a list of nodes where each node is one of:
  - `{:doctype, name, public_id, system_id}` - DOCTYPE declaration (if present, always first)
  - `{:comment, text}` - HTML comment
  - `{tag, attrs, children}` - Element with tag name, attributes list, and child nodes
  - `text` - Text content (binary)

  Attributes are represented as a list of `{name, value}` tuples, sorted alphabetically.

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}]

      iex> PureHTML.parse("<!DOCTYPE html><html></html>")
      [{:doctype, "html", nil, nil}, {"html", [], [{"head", [], []}, {"body", [], []}]}]

  """
  @spec parse(String.t()) :: [term()]
  def parse(html) when is_binary(html) do
    html
    |> Tokenizer.new()
    |> TreeBuilder.build()
  end

  @doc """
  Converts parsed HTML nodes back to an HTML string.

  ## Options

  - `:quote_char` - Force `"'"` or `"\""` for attribute quotes (default: smart quoting)
  - `:minimize_boolean_attributes` - Output `disabled` vs `disabled=disabled` (default: true)
  - `:use_trailing_solidus` - Output `<br />` vs `<br>` (default: false)
  - `:escape_lt_in_attrs` - Escape `<` in attribute values (default: false)
  - `:escape_rcdata` - Escape content in script/style (default: false)
  - `:strip_whitespace` - Collapse whitespace in text nodes (default: false)

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>") |> PureHTML.to_html()
      "<html><head></head><body><p>Hello</p></body></html>"

      iex> PureHTML.to_html([{"div", [{"class", "foo"}], ["text"]}])
      "<div class=foo>text</div>"

      iex> PureHTML.to_html([{"br", [], []}], use_trailing_solidus: true)
      "<br />"

  """
  @spec to_html([term()], keyword()) :: String.t()
  def to_html(nodes, opts \\ []) when is_list(nodes) do
    Serializer.serialize(nodes, opts)
  end

  @doc """
  Finds all nodes matching the CSS selector.

  ## Supported Selectors

  - Tag: `div`, `p`, `a`
  - Universal: `*`
  - Class: `.class`
  - ID: `#id`
  - Attribute: `[attr]`, `[attr=value]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`
  - Selector list: `.a, .b`

  ## Examples

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")
      iex> PureHTML.query(html, "p.intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

      iex> html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      iex> PureHTML.query(html, "li")
      [{"li", [], ["A"]}, {"li", [], ["B"]}]

  """
  defdelegate query(html, selector), to: Query, as: :find

  @doc """
  Returns the immediate children of a node.

  ## Options

  - `:include_text` - Include text nodes (default: true)

  ## Examples

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.children(node)
      [{"p", [], ["Hello"]}, "Some text"]

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.children(node, include_text: false)
      [{"p", [], ["Hello"]}]

  """
  defdelegate children(node, opts \\ []), to: Query
end
