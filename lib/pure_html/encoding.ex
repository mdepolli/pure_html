defmodule PureHTML.Encoding do
  @moduledoc """
  WHATWG encoding sniffing for HTML byte streams.

  Detects the character encoding of an HTML document by examining:
  1. BOM (Byte Order Mark)
  2. `<meta charset>` declarations
  3. `<meta http-equiv="content-type">` declarations

  Uses binary pattern matching for efficient byte-level scanning.
  """

  # ASCII whitespace bytes
  @ws [?\t, ?\n, ?\f, ?\r, ?\s]

  @doc """
  Sniffs the encoding of an HTML byte stream.

  Returns the detected encoding name as a lowercase string.
  Defaults to "windows-1252" if no encoding is detected.

  ## Options

  - `:transport_encoding` - encoding from HTTP Content-Type header (takes precedence)

  ## Examples

      iex> PureHTML.Encoding.sniff(<<0xEF, 0xBB, 0xBF, "<html>">>)
      "utf-8"

      iex> PureHTML.Encoding.sniff("<meta charset='utf-8'>")
      "utf-8"

      iex> PureHTML.Encoding.sniff("<html>")
      "windows-1252"

  """
  @spec sniff(binary(), keyword()) :: String.t()
  def sniff(bytes, opts \\ []) when is_binary(bytes) do
    transport = Keyword.get(opts, :transport_encoding)

    normalize_label(transport) ||
      bom_encoding(bytes) ||
      meta_encoding(bytes) ||
      "windows-1252"
  end

  # BOM detection via binary pattern matching
  defp bom_encoding(<<0xEF, 0xBB, 0xBF, _::binary>>), do: "utf-8"
  defp bom_encoding(<<0xFF, 0xFE, _::binary>>), do: "utf-16le"
  defp bom_encoding(<<0xFE, 0xFF, _::binary>>), do: "utf-16be"
  defp bom_encoding(_), do: nil

  # Meta charset prescan - scans first 1024 bytes of non-comment content
  defp meta_encoding(bytes) do
    prescan(bytes, 0, 0)
  end

  # Prescan state machine
  # Args: bytes, position, non_comment_bytes_seen
  # Stop after 1024 non-comment bytes

  defp prescan(_bytes, _pos, seen) when seen >= 1024, do: nil
  defp prescan(bytes, pos, _seen) when pos >= byte_size(bytes), do: nil

  defp prescan(bytes, pos, seen) do
    case bytes do
      # Comment: <!--
      <<_::binary-size(^pos), "<!--", rest::binary>> ->
        case :binary.match(rest, "-->") do
          {end_pos, 3} -> prescan(bytes, pos + 4 + end_pos + 3, seen)
          :nomatch -> nil
        end

      # Meta tag (case insensitive)
      <<_::binary-size(^pos), ?<, c, rest::binary>> when c in [?m, ?M] ->
        if meta_tag?(rest) do
          handle_meta_tag(bytes, pos + 2, rest, seen)
        else
          prescan(bytes, pos + 1, seen + 1)
        end

      # Other tag - skip to >
      <<_::binary-size(^pos), ?<, _::binary>> ->
        skip_tag(bytes, pos + 1, seen + 1)

      # Regular byte
      _ ->
        prescan(bytes, pos + 1, seen + 1)
    end
  end

  # Check if we have "eta" (case insensitive) followed by whitespace or >
  defp meta_tag?(<<c1, c2, c3, c4, _::binary>>)
       when c1 in [?e, ?E] and c2 in [?t, ?T] and c3 in [?a, ?A] and c4 in @ws,
       do: true

  defp meta_tag?(<<c1, c2, c3, ?>, _::binary>>)
       when c1 in [?e, ?E] and c2 in [?t, ?T] and c3 in [?a, ?A],
       do: true

  defp meta_tag?(_), do: false

  # Skip past closing > of a tag
  defp skip_tag(bytes, pos, _seen) when pos >= byte_size(bytes), do: nil
  defp skip_tag(_bytes, _pos, seen) when seen >= 1024, do: nil

  defp skip_tag(bytes, pos, seen) do
    case bytes do
      <<_::binary-size(^pos), ?>, _::binary>> ->
        prescan(bytes, pos + 1, seen + 1)

      # Handle quoted attribute values
      <<_::binary-size(^pos), q, _::binary>> when q in [?", ?'] ->
        skip_quoted(bytes, pos + 1, q, seen + 1)

      _ ->
        skip_tag(bytes, pos + 1, seen + 1)
    end
  end

  defp skip_quoted(bytes, pos, _q, _seen) when pos >= byte_size(bytes), do: nil
  defp skip_quoted(_bytes, _pos, _q, seen) when seen >= 1024, do: nil

  defp skip_quoted(bytes, pos, q, seen) do
    case bytes do
      <<_::binary-size(^pos), ^q, _::binary>> ->
        skip_tag(bytes, pos + 1, seen + 1)

      _ ->
        skip_quoted(bytes, pos + 1, q, seen + 1)
    end
  end

  # Handle meta tag - parse attributes looking for charset
  # Returns encoding if found, or continues scanning if not
  defp handle_meta_tag(bytes, pos, _rest, seen) do
    # Skip "eta" and find attributes
    pos = pos + 3
    parse_meta_attrs(bytes, pos, seen, nil, nil, nil, false)
  end

  # Parse meta tag attributes
  # Track: charset, http_equiv, content, saw_gt (whether we saw closing >)
  defp parse_meta_attrs(bytes, pos, seen, charset, http_equiv, content, saw_gt)
       when seen >= 1024 do
    finalize_meta(bytes, pos, seen, charset, http_equiv, content, saw_gt)
  end

  defp parse_meta_attrs(bytes, pos, _seen, _charset, _http_equiv, _content, _saw_gt)
       when pos >= byte_size(bytes) do
    # Incomplete tag (no >) - don't accept, return nil
    nil
  end

  defp parse_meta_attrs(bytes, pos, seen, charset, http_equiv, content, _saw_gt) do
    case bytes do
      # End of tag - mark that we saw >
      <<_::binary-size(^pos), ?>, _::binary>> ->
        finalize_meta(bytes, pos + 1, seen + 1, charset, http_equiv, content, true)

      # Another < means malformed, restart scan
      <<_::binary-size(^pos), ?<, _::binary>> ->
        prescan(bytes, pos, seen)

      # Skip whitespace and /
      <<_::binary-size(^pos), c, _::binary>> when c in @ws or c == ?/ ->
        parse_meta_attrs(bytes, pos + 1, seen + 1, charset, http_equiv, content, false)

      # Start of attribute
      _ ->
        {attr_name, attr_value, new_pos, new_seen} = parse_attribute(bytes, pos, seen)

        {charset, http_equiv, content} =
          case String.downcase(attr_name) do
            "charset" -> {attr_value, http_equiv, content}
            "http-equiv" -> {charset, attr_value, content}
            "content" -> {charset, http_equiv, attr_value}
            _ -> {charset, http_equiv, content}
          end

        parse_meta_attrs(bytes, new_pos, new_seen, charset, http_equiv, content, false)
    end
  end

  # Parse a single attribute name[=value]
  defp parse_attribute(bytes, pos, seen) do
    {name, pos, seen} = parse_attr_name(bytes, pos, seen, [])
    {value, pos, seen} = maybe_parse_attr_value(bytes, pos, seen)
    {IO.iodata_to_binary(name), value, pos, seen}
  end

  defp parse_attr_name(bytes, pos, seen, acc) when pos >= byte_size(bytes) do
    {Enum.reverse(acc), pos, seen}
  end

  defp parse_attr_name(bytes, pos, seen, acc) do
    case bytes do
      <<_::binary-size(^pos), c, _::binary>> when c in @ws or c in [?=, ?>, ?/] ->
        {Enum.reverse(acc), pos, seen}

      <<_::binary-size(^pos), c, _::binary>> ->
        parse_attr_name(bytes, pos + 1, seen + 1, [c | acc])
    end
  end

  defp maybe_parse_attr_value(bytes, pos, seen) do
    # Skip whitespace before =
    {pos, seen} = skip_ws(bytes, pos, seen)

    if pos < byte_size(bytes) do
      case bytes do
        <<_::binary-size(^pos), ?=, _::binary>> ->
          pos = pos + 1
          {pos, seen} = skip_ws(bytes, pos, seen + 1)
          parse_attr_value(bytes, pos, seen)

        _ ->
          {nil, pos, seen}
      end
    else
      {nil, pos, seen}
    end
  end

  defp skip_ws(bytes, pos, seen) when pos >= byte_size(bytes), do: {pos, seen}

  defp skip_ws(bytes, pos, seen) do
    case bytes do
      <<_::binary-size(^pos), c, _::binary>> when c in @ws ->
        skip_ws(bytes, pos + 1, seen + 1)

      _ ->
        {pos, seen}
    end
  end

  defp parse_attr_value(bytes, pos, seen) when pos >= byte_size(bytes), do: {nil, pos, seen}

  defp parse_attr_value(bytes, pos, seen) do
    case bytes do
      # Quoted value
      <<_::binary-size(^pos), q, _::binary>> when q in [?", ?'] ->
        parse_quoted_value(bytes, pos + 1, seen + 1, q, [])

      # Unquoted value
      _ ->
        parse_unquoted_value(bytes, pos, seen, [])
    end
  end

  defp parse_quoted_value(bytes, pos, seen, _q, acc) when pos >= byte_size(bytes) do
    {IO.iodata_to_binary(Enum.reverse(acc)), pos, seen}
  end

  defp parse_quoted_value(bytes, pos, seen, q, acc) do
    case bytes do
      <<_::binary-size(^pos), ^q, _::binary>> ->
        {IO.iodata_to_binary(Enum.reverse(acc)), pos + 1, seen + 1}

      <<_::binary-size(^pos), c, _::binary>> ->
        parse_quoted_value(bytes, pos + 1, seen + 1, q, [c | acc])
    end
  end

  defp parse_unquoted_value(bytes, pos, seen, acc) when pos >= byte_size(bytes) do
    {IO.iodata_to_binary(Enum.reverse(acc)), pos, seen}
  end

  defp parse_unquoted_value(bytes, pos, seen, acc) do
    case bytes do
      <<_::binary-size(^pos), c, _::binary>> when c in @ws or c in [?>, ?/] ->
        {IO.iodata_to_binary(Enum.reverse(acc)), pos, seen}

      <<_::binary-size(^pos), c, _::binary>> ->
        parse_unquoted_value(bytes, pos + 1, seen + 1, [c | acc])
    end
  end

  # Finalize meta tag - check for charset or extract from content
  # If encoding found, return it; otherwise continue scanning

  # Incomplete tag (no >) - continue scanning
  defp finalize_meta(bytes, pos, seen, _charset, _http_equiv, _content, false) do
    prescan(bytes, pos, seen)
  end

  # Complete tag with charset attribute
  defp finalize_meta(bytes, pos, seen, charset, _http_equiv, _content, true)
       when charset != nil do
    normalize_meta_encoding(charset) || prescan(bytes, pos, seen)
  end

  # Complete tag with http-equiv="content-type" and content attribute
  defp finalize_meta(bytes, pos, seen, nil, http_equiv, content, true)
       when http_equiv != nil and content != nil do
    encoding =
      if String.downcase(http_equiv) == "content-type" do
        charset_from_content(content)
      end

    encoding || prescan(bytes, pos, seen)
  end

  # No charset found - continue scanning
  defp finalize_meta(bytes, pos, seen, _charset, _http_equiv, _content, true) do
    prescan(bytes, pos, seen)
  end

  # Extract charset from content="text/html; charset=utf-8"
  defp charset_from_content(content) do
    content = String.downcase(content)

    case :binary.match(content, "charset") do
      {pos, 7} ->
        rest = binary_part(content, pos + 7, byte_size(content) - pos - 7)
        extract_charset_value(rest)

      :nomatch ->
        nil
    end
  end

  defp extract_charset_value(<<c, rest::binary>>) when c in @ws do
    extract_charset_value(rest)
  end

  defp extract_charset_value(<<?=, rest::binary>>) do
    extract_charset_value(rest)
  end

  defp extract_charset_value(<<c, rest::binary>>) when c in @ws do
    extract_charset_value(rest)
  end

  defp extract_charset_value(<<?", rest::binary>>) do
    # Quoted value - must find closing quote
    extract_quoted(rest, ?")
  end

  defp extract_charset_value(<<?', rest::binary>>) do
    # Quoted value - must find closing quote
    extract_quoted(rest, ?')
  end

  defp extract_charset_value(<<rest::binary>>) do
    extract_until(rest, @ws ++ [?;])
  end

  # Extract quoted value - returns nil if closing quote not found
  defp extract_quoted(bytes, quote, acc \\ [])
  # Unclosed quote
  defp extract_quoted(<<>>, _quote, _acc), do: nil

  defp extract_quoted(<<c, _rest::binary>>, quote, acc) when c == quote do
    normalize_meta_encoding(IO.iodata_to_binary(Enum.reverse(acc)))
  end

  defp extract_quoted(<<c, rest::binary>>, quote, acc) do
    extract_quoted(rest, quote, [c | acc])
  end

  defp extract_until(bytes, terminators, acc \\ [])

  defp extract_until(<<>>, _terminators, acc),
    do: normalize_meta_encoding(IO.iodata_to_binary(Enum.reverse(acc)))

  defp extract_until(<<c, rest::binary>>, terminators, acc) do
    if c in terminators do
      normalize_meta_encoding(IO.iodata_to_binary(Enum.reverse(acc)))
    else
      extract_until(rest, terminators, [c | acc])
    end
  end

  # Normalize encoding from meta tag (special handling for utf-16 -> utf-8)
  defp normalize_meta_encoding(nil), do: nil
  defp normalize_meta_encoding(""), do: nil

  defp normalize_meta_encoding(label) do
    enc = normalize_label(label)

    # Per HTML spec: UTF-16 in meta charset is treated as UTF-8
    case enc do
      "utf-16" <> _ -> "utf-8"
      other -> other
    end
  end

  # Normalize encoding labels to canonical names
  defp normalize_label(nil), do: nil
  defp normalize_label(""), do: nil

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.trim()
    |> do_normalize_label()
  end

  # WHATWG encoding label normalization
  # https://encoding.spec.whatwg.org/#names-and-labels
  defp do_normalize_label("utf-8"), do: "utf-8"
  defp do_normalize_label("utf8"), do: "utf-8"
  defp do_normalize_label("unicode-1-1-utf-8"), do: "utf-8"

  # ISO-8859-1 and related -> windows-1252
  defp do_normalize_label("iso-8859-1"), do: "windows-1252"
  defp do_normalize_label("iso8859-1"), do: "windows-1252"
  defp do_normalize_label("iso88591"), do: "windows-1252"
  defp do_normalize_label("latin1"), do: "windows-1252"
  defp do_normalize_label("latin-1"), do: "windows-1252"
  defp do_normalize_label("l1"), do: "windows-1252"
  defp do_normalize_label("ascii"), do: "windows-1252"
  defp do_normalize_label("us-ascii"), do: "windows-1252"
  defp do_normalize_label("cp819"), do: "windows-1252"
  defp do_normalize_label("ibm819"), do: "windows-1252"
  defp do_normalize_label("csisolatin1"), do: "windows-1252"

  # Windows-1252
  defp do_normalize_label("windows-1252"), do: "windows-1252"
  defp do_normalize_label("windows1252"), do: "windows-1252"
  defp do_normalize_label("cp1252"), do: "windows-1252"
  defp do_normalize_label("x-cp1252"), do: "windows-1252"

  # ISO-8859-2
  defp do_normalize_label("iso-8859-2"), do: "iso-8859-2"
  defp do_normalize_label("iso8859-2"), do: "iso-8859-2"
  defp do_normalize_label("iso88592"), do: "iso-8859-2"
  defp do_normalize_label("latin2"), do: "iso-8859-2"
  defp do_normalize_label("latin-2"), do: "iso-8859-2"
  defp do_normalize_label("l2"), do: "iso-8859-2"
  defp do_normalize_label("csisolatin2"), do: "iso-8859-2"

  # EUC-JP
  defp do_normalize_label("euc-jp"), do: "euc-jp"
  defp do_normalize_label("eucjp"), do: "euc-jp"
  defp do_normalize_label("x-euc-jp"), do: "euc-jp"
  defp do_normalize_label("cseucpkdfmtjapanese"), do: "euc-jp"

  # UTF-16
  defp do_normalize_label("utf-16"), do: "utf-16"
  defp do_normalize_label("utf16"), do: "utf-16"
  defp do_normalize_label("utf-16le"), do: "utf-16le"
  defp do_normalize_label("utf16le"), do: "utf-16le"
  defp do_normalize_label("utf-16be"), do: "utf-16be"
  defp do_normalize_label("utf16be"), do: "utf-16be"

  # Unknown - return nil
  defp do_normalize_label(_), do: nil
end
