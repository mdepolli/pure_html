defmodule PureHTML.Query.Selector.Tokenizer do
  @moduledoc """
  Tokenizes CSS selector strings into a stream of tokens.

  ## Token Types

  - `{:ident, value}` - Identifier (tag name, attribute name/value)
  - `{:class, value}` - Class selector (.class)
  - `{:id, value}` - ID selector (#id)
  - `:star` - Universal selector (*)
  - `:open_bracket` - Opening bracket for attribute selector
  - `:close_bracket` - Closing bracket for attribute selector
  - `:equal` - Exact match (=)
  - `:prefix_match` - Prefix match (^=)
  - `:suffix_match` - Suffix match ($=)
  - `:substring_match` - Substring match (*=)
  - `:comma` - Selector list separator
  - `{:string, value}` - Quoted string
  """

  @type token ::
          {:ident, String.t()}
          | {:class, String.t()}
          | {:id, String.t()}
          | :star
          | :open_bracket
          | :close_bracket
          | :equal
          | :prefix_match
          | :suffix_match
          | :substring_match
          | :comma
          | {:string, String.t()}

  @doc """
  Tokenizes a CSS selector string into a list of tokens.

  ## Examples

      iex> PureHTML.Query.Selector.Tokenizer.tokenize("div")
      [{:ident, "div"}]

      iex> PureHTML.Query.Selector.Tokenizer.tokenize(".class")
      [{:class, "class"}]

      iex> PureHTML.Query.Selector.Tokenizer.tokenize("#id")
      [{:id, "id"}]

      iex> PureHTML.Query.Selector.Tokenizer.tokenize("div.foo#bar")
      [{:ident, "div"}, {:class, "foo"}, {:id, "bar"}]

  """
  @spec tokenize(String.t()) :: [token()]
  def tokenize(input) when is_binary(input) do
    input
    |> String.trim()
    |> do_tokenize([], false)
    |> Enum.reverse()
  end

  # End of input
  defp do_tokenize("", acc, _in_bracket), do: acc

  # Skip whitespace (for now - combinators would use this)
  defp do_tokenize(<<c, rest::binary>>, acc, in_bracket) when c in ~c[ \t\n\r\f] do
    do_tokenize(skip_whitespace(rest), acc, in_bracket)
  end

  # Substring match (*=) - must come before universal selector
  defp do_tokenize(<<"*=", rest::binary>>, acc, in_bracket) do
    do_tokenize(rest, [:substring_match | acc], in_bracket)
  end

  # Universal selector (only outside brackets)
  defp do_tokenize(<<"*", rest::binary>>, acc, false = in_bracket) do
    do_tokenize(rest, [:star | acc], in_bracket)
  end

  # Class selector (only outside brackets)
  defp do_tokenize(<<".", rest::binary>>, acc, false = in_bracket) do
    {ident, rest} = consume_ident(rest)

    if ident == "" do
      raise ArgumentError, "Expected identifier after '.'"
    end

    do_tokenize(rest, [{:class, ident} | acc], in_bracket)
  end

  # ID selector (only outside brackets)
  defp do_tokenize(<<"#", rest::binary>>, acc, false = in_bracket) do
    {ident, rest} = consume_ident(rest)

    if ident == "" do
      raise ArgumentError, "Expected identifier after '#'"
    end

    do_tokenize(rest, [{:id, ident} | acc], in_bracket)
  end

  # Attribute selector opening
  defp do_tokenize(<<"[", rest::binary>>, acc, _in_bracket) do
    do_tokenize(rest, [:open_bracket | acc], true)
  end

  # Attribute selector closing
  defp do_tokenize(<<"]", rest::binary>>, acc, _in_bracket) do
    do_tokenize(rest, [:close_bracket | acc], false)
  end

  # Prefix match (^=)
  defp do_tokenize(<<"^=", rest::binary>>, acc, in_bracket) do
    do_tokenize(rest, [:prefix_match | acc], in_bracket)
  end

  # Suffix match ($=)
  defp do_tokenize(<<"$=", rest::binary>>, acc, in_bracket) do
    do_tokenize(rest, [:suffix_match | acc], in_bracket)
  end

  # Exact match (=)
  defp do_tokenize(<<"=", rest::binary>>, acc, in_bracket) do
    do_tokenize(rest, [:equal | acc], in_bracket)
  end

  # Comma (selector list)
  defp do_tokenize(<<",", rest::binary>>, acc, in_bracket) do
    do_tokenize(rest, [:comma | acc], in_bracket)
  end

  # Double-quoted string
  defp do_tokenize(<<"\"", rest::binary>>, acc, in_bracket) do
    {string, rest} = consume_string(rest, ?")
    do_tokenize(rest, [{:string, string} | acc], in_bracket)
  end

  # Single-quoted string
  defp do_tokenize(<<"'", rest::binary>>, acc, in_bracket) do
    {string, rest} = consume_string(rest, ?')
    do_tokenize(rest, [{:string, string} | acc], in_bracket)
  end

  # Unquoted attribute value (inside brackets, more permissive)
  defp do_tokenize(<<c, _::binary>> = input, acc, true = in_bracket)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?- or c in ?0..?9 or c == ?. do
    {value, rest} = consume_attr_value(input)
    do_tokenize(rest, [{:ident, value} | acc], in_bracket)
  end

  # Identifier (tag name, attribute name) - outside brackets
  defp do_tokenize(<<c, _::binary>> = input, acc, false = in_bracket)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?- or c in ?0..?9 do
    {ident, rest} = consume_ident(input)
    do_tokenize(rest, [{:ident, ident} | acc], in_bracket)
  end

  # Unknown character
  defp do_tokenize(<<c, _::binary>>, _acc, _in_bracket) do
    raise ArgumentError, "Unexpected character: #{<<c>>}"
  end

  # Consume an identifier (letters, digits, hyphens, underscores)
  defp consume_ident(input), do: consume_ident(input, [])

  defp consume_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?- do
    consume_ident(rest, [c | acc])
  end

  defp consume_ident(rest, acc) do
    {acc |> Enum.reverse() |> List.to_string(), rest}
  end

  # Consume an unquoted attribute value (more permissive, includes dots, etc.)
  defp consume_attr_value(input), do: consume_attr_value(input, [])

  defp consume_attr_value(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?- or c == ?. or c == ?/ or
              c == ?: do
    consume_attr_value(rest, [c | acc])
  end

  defp consume_attr_value(rest, acc) do
    {acc |> Enum.reverse() |> List.to_string(), rest}
  end

  # Consume a quoted string
  defp consume_string(input, quote_char), do: consume_string(input, quote_char, [])

  defp consume_string(<<c, rest::binary>>, quote_char, acc) when c == quote_char do
    {acc |> Enum.reverse() |> List.to_string(), rest}
  end

  defp consume_string(<<"\\", c, rest::binary>>, quote_char, acc) do
    # Handle escape sequences
    consume_string(rest, quote_char, [c | acc])
  end

  defp consume_string(<<c, rest::binary>>, quote_char, acc) do
    consume_string(rest, quote_char, [c | acc])
  end

  defp consume_string("", _quote_char, _acc) do
    raise ArgumentError, "Unterminated string"
  end

  # Skip whitespace
  defp skip_whitespace(<<c, rest::binary>>) when c in ~c[ \t\n\r\f] do
    skip_whitespace(rest)
  end

  defp skip_whitespace(rest), do: rest
end
