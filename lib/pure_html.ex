defmodule PureHTML do
  @moduledoc """
  HTML parsing library.
  """

  alias PureHTML.{Tokenizer, TreeBuilder}

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
end
