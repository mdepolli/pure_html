defmodule PureHTML.Query.Selector.Tokenizer do
  @moduledoc false
  # Tokenizes CSS selector strings into a stream of tokens.
  #
  # Comments, identifiers, escapes, and strings follow CSS Syntax Level 3,
  # except that any code point from U+0080 up is an ident code point, as in
  # Blink, WebKit, and Gecko (ADR 1). An ident-start code point is a letter, an
  # underscore, or a non-ASCII code point; an ident code point is also a
  # digit or a hyphen. A class, an ID, an unquoted attribute value, and a
  # type selector each need input that would start an ident sequence, so
  # none starts with a digit.
  #
  # A selector feature PureHTML does not support is invalid, and its error
  # names the feature.
  #
  # ## Token Types
  #
  # - `{:ident, value}` - Identifier (tag name, attribute name/value)
  # - `{:class, value}` - Class selector (.class)
  # - `{:id, value}` - ID selector (#id)
  # - `:star` - Universal selector (*)
  # - `:open_bracket` - Opening bracket for attribute selector
  # - `:close_bracket` - Closing bracket for attribute selector
  # - `:equal` - Exact match (=)
  # - `:prefix_match` - Prefix match (^=)
  # - `:suffix_match` - Suffix match ($=)
  # - `:substring_match` - Substring match (*=)
  # - `:comma` - Selector list separator
  # - `{:string, value}` - Quoted string
  # - `:child` - Child combinator (>)
  # - `:adjacent_sibling` - Adjacent sibling combinator (+)
  # - `:general_sibling` - General sibling combinator (~)
  # - `:whitespace` - Whitespace (potential descendant combinator)

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
  defguardp is_hex_digit(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # After preprocessing, CR and FF are newlines.
  defguardp is_whitespace(c) when c in ~c[ \t\n]

  @attribute_operators [:equal, :prefix_match, :suffix_match, :substring_match]

  # The tokens after which a compound selector starts.
  @compound_starts [:whitespace, :comma, :child, :adjacent_sibling, :general_sibling]

  # Selectors 4: "The <pseudo-class-selector> production excludes the
  # <legacy-pseudo-element-selector> production", so these are never
  # pseudo-classes.
  @legacy_pseudo_elements ~w(before after first-line first-letter)

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
      {:error, {:invalid_selector, "expected an identifier after \".\""}}

  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, error()}
  def tokenize(input) when is_binary(input) do
    if String.valid?(input) do
      input
      |> preprocess()
      |> do_tokenize([], false)
      |> in_order()
    else
      invalid("invalid UTF-8")
    end
  end

  # CSS Syntax 3, preprocessing the input stream. A valid UTF-8 string holds
  # no surrogates.
  defp preprocess(input) do
    input
    |> String.replace(["\r\n", "\r", "\f"], "\n")
    |> String.replace("\0", "\u{FFFD}")
  end

  defp in_order({:ok, tokens}), do: {:ok, Enum.reverse(tokens)}
  defp in_order({:error, _reason} = error), do: error

  # CSS Syntax 3, consume a simple block: the end of the input closes an open
  # attribute selector.
  defp do_tokenize("", acc, true), do: {:ok, [:close_bracket | acc]}

  # Whitespace outside brackets is a potential descendant combinator: one
  # token for a run, and none at either end of the selector.
  defp do_tokenize("", [:whitespace | acc], false), do: {:ok, acc}
  defp do_tokenize("", acc, false), do: {:ok, acc}

  # CSS Syntax 3, consume comments: a comment is not whitespace, and one still
  # open at the end runs to the end.
  defp do_tokenize(<<"/*", rest::binary>>, acc, in_bracket),
    do: do_tokenize(skip_comment(rest), acc, in_bracket)

  # Inside brackets, whitespace may separate the name, the operator, the
  # value, and the flag, and is dropped. Selectors 4 forbids it "between any
  # of the components of a <wq-name>", so a "|" after it and a name is
  # unexpected.
  defp do_tokenize(<<c, rest::binary>>, acc, true) when is_whitespace(c) do
    rest
    |> skip_whitespace()
    |> after_bracket_whitespace(acc)
  end

  defp do_tokenize(<<c, rest::binary>>, [], false) when is_whitespace(c),
    do: do_tokenize(rest, [], false)

  defp do_tokenize(<<c, rest::binary>>, [:whitespace | _] = acc, false) when is_whitespace(c),
    do: do_tokenize(rest, acc, false)

  defp do_tokenize(<<c, rest::binary>>, acc, false) when is_whitespace(c),
    do: do_tokenize(rest, [:whitespace | acc], false)

  defp do_tokenize(<<">", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:child | acc], false)

  defp do_tokenize(<<"+", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:adjacent_sibling | acc], false)

  defp do_tokenize(<<"~", rest::binary>>, acc, false),
    do: do_tokenize(rest, [:general_sibling | acc], false)

  defp do_tokenize(<<"*=", rest::binary>>, acc, in_bracket),
    do: do_tokenize(rest, [:substring_match | acc], in_bracket)

  defp do_tokenize(<<"~=", _::binary>>, [{:ident, _}, :open_bracket | _], true),
    do: invalid("the ~= operator is not supported")

  defp do_tokenize(<<"|=", _::binary>>, [{:ident, _}, :open_bracket | _], true),
    do: invalid("the |= operator is not supported")

  defp do_tokenize(<<"||", _::binary>>, _acc, false),
    do: invalid("the column combinator is not supported")

  # Selectors 4: a namespace prefix is an identifier, "*", or nothing, then
  # "|" and a name, at the start of a compound selector or an attribute
  # name. "A simple selector containing an undeclared namespace prefix is
  # invalid", and a query declares no prefixes; the *| and bare | forms are
  # valid but not supported. A "|" anywhere else is unexpected.
  defp do_tokenize(<<"*|", rest::binary>> = input, [:open_bracket | _] = acc, true),
    do: namespaced_name(rest, input, acc, true)

  defp do_tokenize(<<"|", rest::binary>> = input, acc, in_bracket),
    do: namespaced_name(rest, input, acc, in_bracket)

  # An HTML element keeps a colon in an attribute name as part of the name,
  # and an escaped colon reaches it.
  defp do_tokenize(<<":", _::binary>>, [{:ident, _}, :open_bracket | _], true),
    do: invalid(~S(a colon is not part of an attribute name; escape it, as in [xml\:lang]))

  defp do_tokenize(<<"::", rest::binary>>, _acc, false), do: pseudo(rest, :element)
  defp do_tokenize(<<":", rest::binary>>, _acc, false), do: pseudo(rest, :class)

  defp do_tokenize(<<"*", rest::binary>>, acc, false), do: do_tokenize(rest, [:star | acc], false)

  # A "." is a <delim-token>, so the token after it starts at "-->", a
  # <CDC-token>.
  defp do_tokenize(<<".-->", _::binary>>, _acc, false), do: invalid(~s(unexpected "-->"))

  defp do_tokenize(<<".", rest::binary>>, acc, false),
    do: tokenize_ident(rest, :class, acc, false)

  # A hash token is an ID selector only when its name would start an ident
  # sequence.
  defp do_tokenize(<<"#", rest::binary>>, acc, false), do: tokenize_ident(rest, :id, acc, false)

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
      {:error, _reason} = error -> error
    end
  end

  # CSS Syntax 3, consume a token: "-->" is a <CDC-token>, which no selector
  # holds, and it is checked before an identifier.
  defp do_tokenize(<<"-->", _::binary>>, _acc, _in_bracket), do: invalid(~s(unexpected "-->"))

  defp do_tokenize(input, acc, in_bracket), do: tokenize_ident(input, :ident, acc, in_bracket)

  defp skip_whitespace(<<c, rest::binary>>) when is_whitespace(c), do: skip_whitespace(rest)
  defp skip_whitespace(input), do: input

  defp after_bracket_whitespace(<<"|=", _::binary>> = input, acc),
    do: do_tokenize(input, acc, true)

  defp after_bracket_whitespace(<<"|", _::binary>> = input, [{:ident, _} | _] = acc),
    do: ident_expected(:ident, input, acc)

  defp after_bracket_whitespace(input, acc), do: do_tokenize(input, acc, true)

  defp namespaced_name(rest, input, acc, in_bracket) do
    if name_follows?(rest, in_bracket) do
      namespace_prefix(acc, input, in_bracket)
    else
      ident_expected(:ident, input, acc)
    end
  end

  # After the "|" comes an element's name or "*", or an attribute's name.
  defp name_follows?(<<"*", _::binary>>, false), do: true
  defp name_follows?(rest, _in_bracket), do: would_start_ident?(rest)

  defp namespace_prefix([{:ident, prefix}, :open_bracket | _], _input, true),
    do: undeclared_prefix(prefix)

  defp namespace_prefix([:open_bracket | _], _input, true), do: unsupported_namespace_form()
  defp namespace_prefix([{:ident, prefix} | _], _input, false), do: undeclared_prefix(prefix)
  defp namespace_prefix([], _input, false), do: unsupported_namespace_form()

  defp namespace_prefix([token | _], _input, false)
       when token == :star or token in @compound_starts,
       do: unsupported_namespace_form()

  defp namespace_prefix(acc, input, _in_bracket), do: ident_expected(:ident, input, acc)

  defp undeclared_prefix(prefix), do: invalid("undeclared namespace prefix #{inspect(prefix)}")

  defp unsupported_namespace_form, do: invalid("the *| and | namespace forms are not supported")

  # Selectors 4: a pseudo-class or a pseudo-element is a colon and then an
  # <ident-token> or a <function-token>, with no whitespace between them.
  defp pseudo(input, kind) do
    if would_start_ident?(input) do
      {name, rest} = consume_ident_sequence(input, [])
      unsupported_pseudo(kind, String.downcase(name, :ascii), rest)
    else
      invalid(~s(expected an identifier after ":"))
    end
  end

  defp unsupported_pseudo(:element, _name, _rest),
    do: invalid("pseudo-elements are not supported")

  # A name and "(" are a <function-token>, so :before( is a functional
  # pseudo-class.
  defp unsupported_pseudo(:class, _name, <<"(", _::binary>>),
    do: invalid("pseudo-classes are not supported")

  defp unsupported_pseudo(:class, name, _rest) when name in @legacy_pseudo_elements,
    do: invalid("pseudo-elements are not supported")

  defp unsupported_pseudo(:class, _name, _rest), do: invalid("pseudo-classes are not supported")

  defp skip_comment(input) do
    case :binary.split(input, "*/") do
      [_comment, rest] -> rest
      [_unterminated] -> ""
    end
  end

  defp tokenize_ident(input, tag, acc, in_bracket) do
    if would_start_ident?(input) do
      {ident, rest} = consume_ident_sequence(input, [])
      do_tokenize(rest, [{tag, ident} | acc], in_bracket)
    else
      ident_expected(tag, input, acc)
    end
  end

  # The errors name the fix for the selectors 0.5.0 accepted: an unquoted
  # value that is not an identifier, and a name that starts with a digit, or
  # with a hyphen and a digit. After an attribute selector's operator, or the
  # identifier that follows it, a character that cannot be part of an
  # identifier needs quotes.
  defp ident_expected(:ident, <<c::utf8, _::binary>>, [operator | _])
       when operator in @attribute_operators,
       do: unquoted_value(c)

  defp ident_expected(:ident, <<c::utf8, _::binary>>, [{:ident, _}, operator | _])
       when operator in @attribute_operators,
       do: unquoted_value(c)

  defp ident_expected(tag, <<c, _::binary>>, _acc) when c in ?0..?9, do: leading_digit(tag)
  defp ident_expected(tag, <<?-, c, _::binary>>, _acc) when c in ?0..?9, do: leading_digit(tag)
  defp ident_expected(:class, _input, _acc), do: invalid(~s(expected an identifier after "."))
  defp ident_expected(:id, _input, _acc), do: invalid(~s(expected an identifier after "#"))

  defp ident_expected(:ident, <<c::utf8, _::binary>>, _acc),
    do: invalid("unexpected character #{inspect(<<c::utf8>>)}")

  defp unquoted_value(c) do
    invalid(
      "unexpected character #{inspect(<<c::utf8>>)}; quote an attribute value that is not an identifier"
    )
  end

  defp leading_digit(:class),
    do: invalid(~S(expected an identifier after "."; escape the digit, as in .\31 0))

  defp leading_digit(:id) do
    invalid(
      ~S(expected an identifier after "#"; escape the digit, as in #\31 0, or use [id="10"])
    )
  end

  defp leading_digit(:ident),
    do: invalid(~S(expected an identifier; escape the digit, as in \31 0))

  # CSS Syntax 3, check if three code points would start an ident sequence.
  defp would_start_ident?(<<"-", c::utf8, _::binary>>) when is_ident_start(c) or c == ?-,
    do: true

  defp would_start_ident?(<<"-", rest::binary>>), do: valid_escape?(rest)
  defp would_start_ident?(<<c::utf8, _::binary>>) when is_ident_start(c), do: true
  defp would_start_ident?(input), do: valid_escape?(input)

  # CSS Syntax 3, check if two code points are a valid escape.
  defp valid_escape?(<<"\\\n", _::binary>>), do: false
  defp valid_escape?(<<"\\", _::binary>>), do: true
  defp valid_escape?(_input), do: false

  # CSS Syntax 3, consume an ident sequence. A backslash before a newline is
  # not a valid escape, so it ends the sequence.
  defp consume_ident_sequence(<<c::utf8, rest::binary>>, acc) when is_ident_char(c),
    do: consume_ident_sequence(rest, [<<c::utf8>> | acc])

  defp consume_ident_sequence(<<"\\\n", _::binary>> = rest, acc), do: {joined(acc), rest}

  defp consume_ident_sequence(<<"\\", rest::binary>>, acc) do
    {code_point, rest} = consume_escape(rest)
    consume_ident_sequence(rest, [code_point | acc])
  end

  defp consume_ident_sequence(rest, acc), do: {joined(acc), rest}

  # CSS Syntax 3, consume a string token, after the opening quote. A newline
  # makes a bad string, and a selector holding one is invalid. The end of the
  # input ends the string, and a backslash just before it does nothing.
  defp consume_string(<<q, rest::binary>>, q, acc), do: {:ok, joined(acc), rest}
  defp consume_string(<<"\n", _::binary>>, _q, _acc), do: invalid("newline in a string")
  defp consume_string(<<"\\\n", rest::binary>>, q, acc), do: consume_string(rest, q, acc)
  defp consume_string("\\", _q, acc), do: {:ok, joined(acc), ""}

  defp consume_string(<<"\\", rest::binary>>, q, acc) do
    {code_point, rest} = consume_escape(rest)
    consume_string(rest, q, [code_point | acc])
  end

  defp consume_string(<<c::utf8, rest::binary>>, q, acc),
    do: consume_string(rest, q, [<<c::utf8>> | acc])

  defp consume_string("", _q, acc), do: {:ok, joined(acc), ""}

  # CSS Syntax 3, consume an escaped code point, after the backslash.
  defp consume_escape(""), do: {"\u{FFFD}", ""}

  defp consume_escape(<<c, _::binary>> = input) when is_hex_digit(c),
    do: consume_hex_escape(input, "")

  defp consume_escape(<<c::utf8, rest::binary>>), do: {<<c::utf8>>, rest}

  # One to six hex digits, then one whitespace.
  defp consume_hex_escape(<<c, rest::binary>>, digits)
       when is_hex_digit(c) and byte_size(digits) < 6,
       do: consume_hex_escape(rest, digits <> <<c>>)

  defp consume_hex_escape(rest, digits) do
    code_point =
      digits
      |> String.to_integer(16)
      |> escaped_code_point()

    {code_point, consume_one_whitespace(rest)}
  end

  defp escaped_code_point(code) when code == 0 or code in 0xD800..0xDFFF or code > 0x10FFFF,
    do: "\u{FFFD}"

  defp escaped_code_point(code), do: <<code::utf8>>

  defp consume_one_whitespace(<<c, rest::binary>>) when is_whitespace(c), do: rest
  defp consume_one_whitespace(rest), do: rest

  defp joined(reversed_parts) do
    reversed_parts
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp invalid(reason), do: {:error, {:invalid_selector, reason}}
end
