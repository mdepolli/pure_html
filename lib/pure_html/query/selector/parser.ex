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
      {:ok, [[{nil, %PureHTML.Query.Selector{type: "div"}}]]}

      iex> PureHTML.Query.Selector.Parser.parse("div > p")
      {:ok, [[{nil, %PureHTML.Query.Selector{type: "div"}}, {:child, %PureHTML.Query.Selector{type: "p"}}]]}

      iex> PureHTML.Query.Selector.Parser.parse(".a, .b")
      {:ok, [[{nil, %PureHTML.Query.Selector{classes: ["a"]}}], [{nil, %PureHTML.Query.Selector{classes: ["b"]}}]]}

      iex> PureHTML.Query.Selector.Parser.parse("div >")
      {:error, {:invalid_selector, "expected a compound selector"}}

  """
  @type error :: {:invalid_selector, String.t()}

  @spec parse(String.t()) :: {:ok, [selector_chain()]} | {:error, error()}
  def parse(selector_string) when is_binary(selector_string) do
    with {:ok, tokens} <- Tokenizer.tokenize(selector_string),
         {:ok, chains} <- parse_list(normalize_combinators(tokens), []) do
      {:ok, Enum.reverse(chains)}
    end
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
  @combinators [:descendant | @explicit_combinators]

  @attribute_operators %{
    equal: :equal,
    prefix_match: :prefix,
    suffix_match: :suffix,
    substring_match: :substring
  }

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

  # A selector list: complex selectors separated by commas. "An empty
  # selector, i.e. one that contains no compound selector, is invalid", and "a
  # selector list containing an invalid selector is invalid".
  defp parse_list(tokens, acc) do
    with {:ok, chain, rest} <- parse_complex_selector(tokens) do
      case rest do
        [] -> {:ok, [chain | acc]}
        [:comma | rest] -> parse_list(rest, [chain | acc])
      end
    end
  end

  # A complex selector: compound selectors joined by combinators, every
  # combinator followed by a compound selector.
  defp parse_complex_selector(tokens) do
    with {:ok, selector, rest} <- parse_compound_selector(tokens) do
      parse_combinators(rest, [{nil, selector}])
    end
  end

  defp parse_combinators([combinator | rest], chain) when combinator in @combinators do
    with {:ok, selector, rest} <- parse_compound_selector(rest) do
      parse_combinators(rest, [{combinator, selector} | chain])
    end
  end

  defp parse_combinators(rest, chain), do: {:ok, Enum.reverse(chain), rest}

  # A compound selector: at least one simple selector, with a type or
  # universal selector first if present.
  defp parse_compound_selector(tokens) do
    case parse_simple_selectors(tokens, %Selector{}, 0) do
      {:ok, _selector, 0, _rest} -> invalid("expected a compound selector")
      {:ok, selector, _count, rest} -> {:ok, selector, rest}
      {:error, _reason} = error -> error
    end
  end

  defp parse_simple_selectors([{:ident, tag} | rest], %Selector{type: nil} = selector, 0),
    do: parse_simple_selectors(rest, %{selector | type: tag}, 1)

  defp parse_simple_selectors([:star | rest], %Selector{type: nil} = selector, 0),
    do: parse_simple_selectors(rest, %{selector | type: "*"}, 1)

  defp parse_simple_selectors([{:class, class} | rest], selector, n),
    do: parse_simple_selectors(rest, %{selector | classes: selector.classes ++ [class]}, n + 1)

  defp parse_simple_selectors([{:id, id} | rest], selector, n),
    do: parse_simple_selectors(rest, %{selector | id: id}, n + 1)

  defp parse_simple_selectors([:open_bracket | rest], selector, n) do
    with {:ok, attribute, rest} <- parse_attribute_selector(rest) do
      attributes = selector.attributes ++ [attribute]
      parse_simple_selectors(rest, %{selector | attributes: attributes}, n + 1)
    end
  end

  defp parse_simple_selectors([token | _] = tokens, selector, n)
       when token == :comma or token in @combinators,
       do: {:ok, selector, n, tokens}

  defp parse_simple_selectors([], selector, n), do: {:ok, selector, n, []}

  defp parse_simple_selectors([token | _], _selector, _n),
    do: invalid("unexpected #{inspect(token)}")

  # An attribute selector after its opening bracket: a name, then either the
  # closing bracket or an operator, a value, and the closing bracket.
  defp parse_attribute_selector([{:ident, name}, :close_bracket | rest]),
    do: {:ok, %AttributeSelector{name: name, match_type: :exists}, rest}

  defp parse_attribute_selector([{:ident, name}, operator, value, :close_bracket | rest])
       when is_map_key(@attribute_operators, operator) and
              (elem(value, 0) == :string or elem(value, 0) == :ident) do
    match_type = Map.fetch!(@attribute_operators, operator)
    {:ok, %AttributeSelector{name: name, value: elem(value, 1), match_type: match_type}, rest}
  end

  defp parse_attribute_selector(_tokens), do: invalid("malformed attribute selector")

  defp invalid(reason), do: {:error, {:invalid_selector, reason}}
end
