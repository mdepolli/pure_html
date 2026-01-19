defmodule PureHTML.Query.Selector.Parser do
  @moduledoc """
  Parses CSS selector tokens into Selector structs.
  """

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector
  alias PureHTML.Query.Selector.Tokenizer

  @doc """
  Parses a CSS selector string into a list of Selector structs.

  Returns a list because selectors can be comma-separated (e.g., ".a, .b").

  ## Examples

      iex> PureHTML.Query.Selector.Parser.parse("div")
      [%PureHTML.Query.Selector{type: "div"}]

      iex> PureHTML.Query.Selector.Parser.parse(".foo")
      [%PureHTML.Query.Selector{classes: ["foo"]}]

      iex> PureHTML.Query.Selector.Parser.parse("div.foo#bar")
      [%PureHTML.Query.Selector{type: "div", id: "bar", classes: ["foo"]}]

      iex> PureHTML.Query.Selector.Parser.parse(".a, .b")
      [%PureHTML.Query.Selector{classes: ["a"]}, %PureHTML.Query.Selector{classes: ["b"]}]

  """
  @spec parse(String.t()) :: [Selector.t()]
  def parse(selector_string) when is_binary(selector_string) do
    selector_string
    |> Tokenizer.tokenize()
    |> do_parse([])
    |> Enum.reverse()
  end

  # End of tokens - return current selector if any
  defp do_parse([], acc) do
    acc
  end

  # Start parsing a new selector or continue current one
  defp do_parse(tokens, acc) do
    {selector, rest} = parse_compound_selector(tokens, %Selector{})

    case rest do
      [] ->
        [selector | acc]

      [:comma | rest] ->
        do_parse(rest, [selector | acc])

      [unexpected | _] ->
        raise ArgumentError, "Unexpected token: #{inspect(unexpected)}"
    end
  end

  # Parse a compound selector (e.g., div.class#id[attr])
  defp parse_compound_selector([], selector), do: {selector, []}

  defp parse_compound_selector([:comma | _] = tokens, selector), do: {selector, tokens}

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
