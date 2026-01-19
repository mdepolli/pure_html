defmodule PureHTML do
  @moduledoc """
  HTML parsing library.
  """

  alias PureHTML.{Serializer, Tokenizer, TreeBuilder}

  @doc """
  Parses an HTML string into a list of nodes.

  Returns a list of nodes where each node is one of:
  - `{:doctype, name, public_id, system_id}` - DOCTYPE declaration (if present, always first)
  - `{:comment, text}` - HTML comment
  - `{tag, attrs, children}` - Element with tag name, attributes map, and child nodes
  - `text` - Text content (binary)

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", %{}, [{"head", %{}, []}, {"body", %{}, [{"p", %{}, ["Hello"]}]}]}]

      iex> PureHTML.parse("<!DOCTYPE html><html></html>")
      [{:doctype, "html", nil, nil}, {"html", %{}, [{"head", %{}, []}, {"body", %{}, []}]}]

  """
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

      iex> PureHTML.to_html([{"div", %{"class" => "foo"}, ["text"]}])
      "<div class=foo>text</div>"

      iex> PureHTML.to_html([{"br", %{}, []}], use_trailing_solidus: true)
      "<br />"

  """
  @spec to_html([term()], keyword()) :: String.t()
  def to_html(nodes, opts \\ []) when is_list(nodes) do
    Serializer.serialize(nodes, opts)
  end
end
