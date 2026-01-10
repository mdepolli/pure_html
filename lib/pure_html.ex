defmodule PureHTML do
  @moduledoc """
  HTML parsing library.
  """

  alias PureHTML.{Tokenizer, TreeBuilder}

  @doc """
  Parses an HTML string into a document tree.

  Returns `{doctype, nodes}` where:
  - `doctype` is `nil` or a doctype tuple
  - `nodes` is a list of `{tag, attrs, children}` tuples

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>")
      {nil, [{"html", %{}, [{"head", %{}, []}, {"body", %{}, [{"p", %{}, ["Hello"]}]}]}]}

  """
  def parse(html) when is_binary(html) do
    html
    |> Tokenizer.new()
    |> TreeBuilder.build()
  end
end
