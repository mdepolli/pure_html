defmodule PureHTML.Query.Selector.Parser do
  @moduledoc """
  Parses CSS selector tokens into Selector structs.
  """

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector
  alias PureHTML.Query.Selector.Tokenizer

  @type combinator :: nil | :descendant | :child | :adjacent_sibling | :general_sibling
  @type selector_chain :: [{combinator(), Selector.t()}]

  @doc """
  Parses a CSS selector string into a list of selector chains.

  Each chain is a list of `{combinator, selector}` tuples where combinator
  indicates the relationship to the previous selector in the chain.

  ## Combinators

  - `nil` - First selector in chain (no combinator)
  - `:descendant` - Descendant combinator (space)
  - `:child` - Child combinator (>)
  - `:adjacent_sibling` - Adjacent sibling combinator (+)
  - `:general_sibling` - General sibling combinator (~)

  ## Examples

      iex> PureHTML.Query.Selector.Parser.parse("div")
      [[{nil, %PureHTML.Query.Selector{type: "div"}}]]

      iex> PureHTML.Query.Selector.Parser.parse("div > p")
      [[{nil, %PureHTML.Query.Selector{type: "div"}}, {:child, %PureHTML.Query.Selector{type: "p"}}]]

      iex> PureHTML.Query.Selector.Parser.parse("div p")
      [[{nil, %PureHTML.Query.Selector{type: "div"}}, {:descendant, %PureHTML.Query.Selector{type: "p"}}]]

      iex> PureHTML.Query.Selector.Parser.parse(".a, .b")
      [[{nil, %PureHTML.Query.Selector{classes: ["a"]}}], [{nil, %PureHTML.Query.Selector{classes: ["b"]}}]]

  """
  @spec parse(String.t()) :: [selector_chain()]
  def parse(selector_string) when is_binary(selector_string) do
    selector_string
    |> Tokenizer.tokenize()
    |> normalize_combinators()
    |> do_parse([])
    |> Enum.reverse()
  end

  # Normalize combinator tokens:
  # - Remove whitespace around explicit combinators (>, +, ~)
  # - Remove whitespace around commas
  # - Convert remaining whitespace to :descendant
  defp normalize_combinators(tokens) do
    tokens
    |> collapse_whitespace_around_combinators([])
    |> Enum.reverse()
  end

  @explicit_combinators [:child, :adjacent_sibling, :general_sibling]

  # Process tokens, collapsing whitespace around explicit combinators
  defp collapse_whitespace_around_combinators([], acc), do: acc

  # Whitespace followed by explicit combinator - skip the whitespace
  defp collapse_whitespace_around_combinators([:whitespace, combinator | rest], acc)
       when combinator in @explicit_combinators do
    collapse_whitespace_around_combinators([combinator | rest], acc)
  end

  # Whitespace followed by comma - skip the whitespace
  defp collapse_whitespace_around_combinators([:whitespace, :comma | rest], acc) do
    collapse_whitespace_around_combinators([:comma | rest], acc)
  end

  # Explicit combinator followed by whitespace - keep combinator, skip whitespace
  defp collapse_whitespace_around_combinators([combinator, :whitespace | rest], acc)
       when combinator in @explicit_combinators do
    collapse_whitespace_around_combinators(rest, [combinator | acc])
  end

  # Comma followed by whitespace - keep comma, skip whitespace
  defp collapse_whitespace_around_combinators([:comma, :whitespace | rest], acc) do
    collapse_whitespace_around_combinators(rest, [:comma | acc])
  end

  # Standalone whitespace becomes descendant combinator
  defp collapse_whitespace_around_combinators([:whitespace | rest], acc) do
    collapse_whitespace_around_combinators(rest, [:descendant | acc])
  end

  # Any other token - keep it
  defp collapse_whitespace_around_combinators([token | rest], acc) do
    collapse_whitespace_around_combinators(rest, [token | acc])
  end

  # Parse selector chains separated by commas
  defp do_parse([], acc), do: acc

  defp do_parse(tokens, acc) do
    {chain, rest} = parse_selector_chain(tokens, [])

    case rest do
      [] ->
        [Enum.reverse(chain) | acc]

      [:comma | rest] ->
        do_parse(rest, [Enum.reverse(chain) | acc])

      [unexpected | _] ->
        raise ArgumentError, "Unexpected token: #{inspect(unexpected)}"
    end
  end

  # Parse a selector chain (compound selectors connected by combinators)
  defp parse_selector_chain([], chain), do: {chain, []}

  defp parse_selector_chain([:comma | _] = tokens, chain), do: {chain, tokens}

  defp parse_selector_chain(tokens, []) do
    # First selector in chain - no combinator
    {selector, rest} = parse_compound_selector(tokens, %Selector{})
    parse_selector_chain(rest, [{nil, selector}])
  end

  defp parse_selector_chain([combinator | rest], chain)
       when combinator in [:descendant, :child, :adjacent_sibling, :general_sibling] do
    {selector, rest} = parse_compound_selector(rest, %Selector{})
    parse_selector_chain(rest, [{combinator, selector} | chain])
  end

  defp parse_selector_chain(tokens, chain), do: {chain, tokens}

  # Parse a compound selector (e.g., div.class#id[attr])
  defp parse_compound_selector([], selector), do: {selector, []}

  defp parse_compound_selector([:comma | _] = tokens, selector), do: {selector, tokens}

  defp parse_compound_selector([combinator | _] = tokens, selector)
       when combinator in [:descendant, :child, :adjacent_sibling, :general_sibling] do
    {selector, tokens}
  end

  defp parse_compound_selector([{:ident, tag} | rest], selector) do
    parse_compound_selector(rest, %{selector | type: tag})
  end

  defp parse_compound_selector([:star | rest], selector) do
    parse_compound_selector(rest, %{selector | type: "*"})
  end

  defp parse_compound_selector([{:class, class} | rest], selector) do
    parse_compound_selector(rest, %{selector | classes: selector.classes ++ [class]})
  end

  defp parse_compound_selector([{:id, id} | rest], selector) do
    parse_compound_selector(rest, %{selector | id: id})
  end

  defp parse_compound_selector([:open_bracket | rest], selector) do
    {attr_selector, rest} = parse_attribute_selector(rest)

    parse_compound_selector(rest, %{selector | attributes: selector.attributes ++ [attr_selector]})
  end

  defp parse_compound_selector(tokens, selector), do: {selector, tokens}

  # Parse attribute selector content (after opening bracket)
  defp parse_attribute_selector([{:ident, name} | rest]) do
    parse_attribute_operator(rest, name)
  end

  defp parse_attribute_selector(tokens) do
    raise ArgumentError, "Expected attribute name, got: #{inspect(tokens)}"
  end

  # Parse the operator and value (if any)
  defp parse_attribute_operator([:close_bracket | rest], name) do
    # Existence check: [attr]
    {%AttributeSelector{name: name, match_type: :exists}, rest}
  end

  defp parse_attribute_operator([:equal | rest], name) do
    {value, rest} = parse_attribute_value(rest)
    expect_close_bracket(rest, %AttributeSelector{name: name, value: value, match_type: :equal})
  end

  defp parse_attribute_operator([:prefix_match | rest], name) do
    {value, rest} = parse_attribute_value(rest)
    expect_close_bracket(rest, %AttributeSelector{name: name, value: value, match_type: :prefix})
  end

  defp parse_attribute_operator([:suffix_match | rest], name) do
    {value, rest} = parse_attribute_value(rest)
    expect_close_bracket(rest, %AttributeSelector{name: name, value: value, match_type: :suffix})
  end

  defp parse_attribute_operator([:substring_match | rest], name) do
    {value, rest} = parse_attribute_value(rest)

    expect_close_bracket(rest, %AttributeSelector{
      name: name,
      value: value,
      match_type: :substring
    })
  end

  defp parse_attribute_operator(tokens, _name) do
    raise ArgumentError, "Expected attribute operator or ']', got: #{inspect(tokens)}"
  end

  # Parse the attribute value (quoted string or identifier)
  defp parse_attribute_value([{:string, value} | rest]), do: {value, rest}
  defp parse_attribute_value([{:ident, value} | rest]), do: {value, rest}

  defp parse_attribute_value(tokens) do
    raise ArgumentError, "Expected attribute value, got: #{inspect(tokens)}"
  end

  # Expect closing bracket
  defp expect_close_bracket([:close_bracket | rest], attr_selector) do
    {attr_selector, rest}
  end

  defp expect_close_bracket(tokens, _attr_selector) do
    raise ArgumentError, "Expected ']', got: #{inspect(tokens)}"
  end
end
