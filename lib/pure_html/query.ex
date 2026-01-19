defmodule PureHTML.Query do
  @moduledoc """
  CSS selector querying for PureHTML documents.

  Provides functions for finding and traversing HTML nodes using CSS selectors.
  """

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.Parser

  @type html_tree :: [html_node()]
  @type html_node ::
          {String.t(), [{String.t(), String.t()}], [html_node() | String.t()]}
          | String.t()
          | {:comment, String.t()}
          | {:doctype, String.t(), String.t() | nil, String.t() | nil}

  @doc """
  Finds all nodes matching the CSS selector.

  ## Examples

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")
      iex> PureHTML.Query.find(html, "p.intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

      iex> html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      iex> PureHTML.Query.find(html, "li")
      [{"li", [], ["A"]}, {"li", [], ["B"]}]

  """
  @spec find(html_tree() | html_node(), String.t() | [Selector.t()]) :: html_tree()
  def find(html, selector) when is_binary(selector) do
    selectors = Parser.parse(selector)
    find(html, selectors)
  end

  def find(html, selectors) when is_list(selectors) do
    html
    |> List.wrap()
    |> do_find(selectors, [])
    |> Enum.reverse()
  end

  defp do_find([], _selectors, acc), do: acc

  defp do_find([node | rest], selectors, acc) do
    acc =
      if any_selector_matches?(node, selectors) do
        [node | acc]
      else
        acc
      end

    children = get_element_children(node)
    acc = do_find(children, selectors, acc)
    do_find(rest, selectors, acc)
  end

  defp any_selector_matches?(node, selectors) do
    Enum.any?(selectors, &Selector.match?(node, &1))
  end

  defp get_element_children({{_ns, _tag}, _attrs, children}), do: children
  defp get_element_children({_tag, _attrs, children}) when is_list(children), do: children
  defp get_element_children(_), do: []

  @doc """
  Returns the immediate children of a node.

  ## Options

  - `:include_text` - Include text nodes (default: true)

  ## Examples

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.Query.children(node)
      [{"p", [], ["Hello"]}, "Some text"]

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.Query.children(node, include_text: false)
      [{"p", [], ["Hello"]}]

  """
  @spec children(html_node(), keyword()) :: html_tree() | nil
  def children(node, opts \\ [])

  def children({{_ns, _tag}, _attrs, children}, opts) do
    filter_children(children, opts)
  end

  def children({_tag, _attrs, children}, opts) when is_list(children) do
    filter_children(children, opts)
  end

  def children(_non_element, _opts), do: nil

  defp filter_children(children, opts) do
    include_text = Keyword.get(opts, :include_text, true)

    if include_text do
      children
    else
      Enum.filter(children, &element?/1)
    end
  end

  defp element?({tag, attrs, _children}) when is_binary(tag) and is_list(attrs), do: true

  defp element?({{_ns, tag}, attrs, _children}) when is_binary(tag) and is_list(attrs),
    do: true

  defp element?(_), do: false
end
