defmodule PureHTML.Query.Selector.Tokenizer do
  @moduledoc """
  Tokenizes CSS selector strings into a stream of tokens.

  Identifiers follow CSS Syntax Level 3: an ident-start code point is a
  letter, an underscore, or any non-ASCII code point; an ident code point is
  also a digit or a hyphen.

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
  - `:child` - Child combinator (>)
  - `:adjacent_sibling` - Adjacent sibling combinator (+)
  - `:general_sibling` - General sibling combinator (~)
  - `:whitespace` - Whitespace (potential descendant combinator)
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
          | :child
          | :adjacent_sibling
          | :general_sibling
          | :whitespace

  @type error :: {:invalid_selector, String.t()}

  defguardp is_ident_start(c) when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80
  defguardp is_ident_char(c) when is_ident_start(c) or c in ?0..?9 or c == ?-
  defguardp is_attr_value_char(c) when is_ident_char(c) or c in ~c[./:]
  defguardp is_whitespace(c) when c in ~c[ \t\n\r\f]

  @doc """
  Tokenizes a CSS selector string.

  Returns `{:ok, tokens}` with leading and trailing whitespace removed, or
  `{:error, {:invalid_selector, reason}}`.

  ## Examples

      iex> PureHTML.Query.Selector.Tokenizer.tokenize("div")
      {:ok, [{:ident, "div"}]}

      iex> PureHTML.Query.Selector.Tokenizer.tokenize("div.foo#bar")
      {:ok, [{:ident, "div"}, {:class, "foo"}, {:id, "bar"}]}

      iex> PureHTML.Query.Selector.Tokenizer.tokenize(".")
      {:error, {:invalid_selector, "expected an identifier after '.'"}}

  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, error()}
  def tokenize(input) when is_binary(input) do
    input
    |> trim_whitespace()
    |> do_tokenize([], false)
    |> in_order()
  end

  # Whitespace at either end of a selector is not a combinator.
  defp trim_whitespace(input) do
    input
    |> trim_leading_whitespace()
    |> String.reverse()
    |> trim_leading_whitespace()
    |> String.reverse()
  end

  defp in_order({:ok, tokens}), do: {:ok, Enum.reverse(tokens)}
  defp in_order({:error, _reason} = error), do: error

  defp do_tokenize("", acc, _in_bracket), do: {:ok, acc}

  # Whitespace outside brackets is a potential descendant combinator; inside
  # brackets it separates nothing.
  defp do_tokenize(<<c, rest::binary>>, acc, false) when is_whitespace(c) do
    do_tokenize(trim_leading_whitespace(rest), [:whitespace | acc], false)
  end

  defp do_tokenize(<<c, rest::binary>>, acc, true) when is_whitespace(c) do
    do_tokenize(trim_leading_whitespace(rest), acc, true)
  end

  defp do_tokenize(<<">", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:child | acc], false)

  defp do_tokenize(<<"+", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:adjacent_sibling | acc], false)

  defp do_tokenize(<<"~", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:general_sibling | acc], false)

  defp do_tokenize(<<"*=", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:substring_match | acc], in_bracket)

  defp do_tokenize(<<"*", rest::binary>>, acc, false), do: do_tokenize(rest, [:star | acc], false)

  defp do_tokenize(<<".", rest::binary>>, acc, false) do
    case consume_ident(rest) do
      {"", _rest} -> {:error, {:invalid_selector, "expected an identifier after '.'"}}
      {ident, rest} -> do_tokenize(rest, [{:class, ident} | acc], false)
    end
  end

  defp do_tokenize(<<"#", rest::binary>>, acc, false) do
    case consume_ident(rest) do
      {"", _rest} -> {:error, {:invalid_selector, "expected an identifier after '#'"}}
      {ident, rest} -> do_tokenize(rest, [{:id, ident} | acc], false)
    end
  end

  defp do_tokenize(<<"[", rest::binary>>, acc, _in_bracket),
    do: do_tokenize(rest, [:open_bracket | acc], true)

  defp do_tokenize(<<"]", rest::binary>>, acc, _in_bracket),
    do: do_tokenize(rest, [:close_bracket | acc], false)

  defp do_tokenize(<<"^=", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:prefix_match | acc], in_bracket)

  defp do_tokenize(<<"$=", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:suffix_match | acc], in_bracket)

  defp do_tokenize(<<"=", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:equal | acc], in_bracket)

  defp do_tokenize(<<",", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:comma | acc], in_bracket)

  defp do_tokenize(<<q, rest::binary>>, acc, in_bracket) when q in [?", ?'] do
    case consume_string(rest, q, []) do
      {:ok, string, rest} -> do_tokenize(rest, [{:string, string} | acc], in_bracket)
      :unterminated -> {:error, {:invalid_selector, "unterminated string"}}
    end
  end

  # An unquoted attribute value may also hold dots, slashes, and colons.
  defp do_tokenize(<<c::utf8, _::binary>> = input, acc, true) when is_attr_value_char(c) do
    {value, rest} = consume_attr_value(input)
    do_tokenize(rest, [{:ident, value} | acc], true)
  end

  defp do_tokenize(<<c::utf8, _::binary>> = input, acc, false) when is_ident_char(c) do
    {ident, rest} = consume_ident(input)
    do_tokenize(rest, [{:ident, ident} | acc], false)
  end

  defp do_tokenize(<<c::utf8, _::binary>>, _acc, _in_bracket) do
    {:error, {:invalid_selector, "unexpected character #{inspect(<<c::utf8>>)}"}}
  end

  defp do_tokenize(<<_byte, _::binary>>, _acc, _in_bracket) do
    {:error, {:invalid_selector, "invalid UTF-8"}}
  end

  defp consume_ident(input), do: consume_ident(input, [])

  defp consume_ident(<<c::utf8, rest::binary>>, acc) when is_ident_char(c),
    do: consume_ident(rest, [<<c::utf8>> | acc])

  defp consume_ident(rest, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_attr_value(input), do: consume_attr_value(input, [])

  defp consume_attr_value(<<c::utf8, rest::binary>>, acc) when is_attr_value_char(c),
    do: consume_attr_value(rest, [<<c::utf8>> | acc])

  defp consume_attr_value(rest, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_string(<<q, rest::binary>>, q, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_string(<<"\\", c::utf8, rest::binary>>, q, acc),
    do: consume_string(rest, q, [<<c::utf8>> | acc])

  defp consume_string(<<c::utf8, rest::binary>>, q, acc),
    do: consume_string(rest, q, [<<c::utf8>> | acc])

  defp consume_string(_input, _q, _acc), do: :unterminated

  defp trim_leading_whitespace(<<c, rest::binary>>) when is_whitespace(c),
    do: trim_leading_whitespace(rest)

  defp trim_leading_whitespace(rest), do: rest
end
