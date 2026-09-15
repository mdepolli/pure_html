defmodule PureHTML.Encoding do
  @moduledoc """
  WHATWG encoding sniffing for HTML byte streams.

  Detects the character encoding of an HTML document by examining, in order:
  1. BOM (Byte Order Mark)
  2. A transport encoding (HTTP Content-Type), if it is a supported label
  3. A prescan of the byte stream (`<meta charset>`, `http-equiv`, XML declaration)

  The prescan runs to the end of the given binary, not the first 1024 bytes
  the standard encourages streaming user agents to stop at. The result is the
  Encoding Standard name of the encoding, lowercased.
  """

  # ASCII whitespace bytes (HTML and Encoding Standard)
  @ws [?\t, ?\n, ?\f, ?\r, ?\s]

  @doc """
  Sniffs the encoding of an HTML byte stream.

  Returns the detected encoding name as a lowercase string.
  Defaults to "windows-1252" if no encoding is detected.

  ## Options

  - `:transport_encoding` - encoding from HTTP Content-Type header. Used only
    when it is a supported Encoding Standard label, and only after a BOM.

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

    bom_sniff(bytes) ||
      get_encoding(transport) ||
      prescan(bytes) ||
      "windows-1252"
  end

  defp bom_sniff(<<0xEF, 0xBB, 0xBF, _::binary>>), do: "utf-8"
  defp bom_sniff(<<0xFF, 0xFE, _::binary>>), do: "utf-16le"
  defp bom_sniff(<<0xFE, 0xFF, _::binary>>), do: "utf-16be"
  defp bom_sniff(_), do: nil

  # Encoding Standard "get an encoding". Names are lowercased so remap
  # comparisons (utf-16le / utf-16be / x-user-defined) cannot miss.
  # 228 labels from https://encoding.spec.whatwg.org/encodings.json (2026-09-15).
  @labels %{
    "unicode-1-1-utf-8" => "utf-8",
    "unicode11utf8" => "utf-8",
    "unicode20utf8" => "utf-8",
    "utf-8" => "utf-8",
    "utf8" => "utf-8",
    "x-unicode20utf8" => "utf-8",
    "866" => "ibm866",
    "cp866" => "ibm866",
    "csibm866" => "ibm866",
    "ibm866" => "ibm866",
    "csisolatin2" => "iso-8859-2",
    "iso-8859-2" => "iso-8859-2",
    "iso-ir-101" => "iso-8859-2",
    "iso8859-2" => "iso-8859-2",
    "iso88592" => "iso-8859-2",
    "iso_8859-2" => "iso-8859-2",
    "iso_8859-2:1987" => "iso-8859-2",
    "l2" => "iso-8859-2",
    "latin2" => "iso-8859-2",
    "csisolatin3" => "iso-8859-3",
    "iso-8859-3" => "iso-8859-3",
    "iso-ir-109" => "iso-8859-3",
    "iso8859-3" => "iso-8859-3",
    "iso88593" => "iso-8859-3",
    "iso_8859-3" => "iso-8859-3",
    "iso_8859-3:1988" => "iso-8859-3",
    "l3" => "iso-8859-3",
    "latin3" => "iso-8859-3",
    "csisolatin4" => "iso-8859-4",
    "iso-8859-4" => "iso-8859-4",
    "iso-ir-110" => "iso-8859-4",
    "iso8859-4" => "iso-8859-4",
    "iso88594" => "iso-8859-4",
    "iso_8859-4" => "iso-8859-4",
    "iso_8859-4:1988" => "iso-8859-4",
    "l4" => "iso-8859-4",
    "latin4" => "iso-8859-4",
    "csisolatincyrillic" => "iso-8859-5",
    "cyrillic" => "iso-8859-5",
    "iso-8859-5" => "iso-8859-5",
    "iso-ir-144" => "iso-8859-5",
    "iso8859-5" => "iso-8859-5",
    "iso88595" => "iso-8859-5",
    "iso_8859-5" => "iso-8859-5",
    "iso_8859-5:1988" => "iso-8859-5",
    "arabic" => "iso-8859-6",
    "asmo-708" => "iso-8859-6",
    "csiso88596e" => "iso-8859-6",
    "csiso88596i" => "iso-8859-6",
    "csisolatinarabic" => "iso-8859-6",
    "ecma-114" => "iso-8859-6",
    "iso-8859-6" => "iso-8859-6",
    "iso-8859-6-e" => "iso-8859-6",
    "iso-8859-6-i" => "iso-8859-6",
    "iso-ir-127" => "iso-8859-6",
    "iso8859-6" => "iso-8859-6",
    "iso88596" => "iso-8859-6",
    "iso_8859-6" => "iso-8859-6",
    "iso_8859-6:1987" => "iso-8859-6",
    "csisolatingreek" => "iso-8859-7",
    "ecma-118" => "iso-8859-7",
    "elot_928" => "iso-8859-7",
    "greek" => "iso-8859-7",
    "greek8" => "iso-8859-7",
    "iso-8859-7" => "iso-8859-7",
    "iso-ir-126" => "iso-8859-7",
    "iso8859-7" => "iso-8859-7",
    "iso88597" => "iso-8859-7",
    "iso_8859-7" => "iso-8859-7",
    "iso_8859-7:1987" => "iso-8859-7",
    "sun_eu_greek" => "iso-8859-7",
    "csiso88598e" => "iso-8859-8",
    "csisolatinhebrew" => "iso-8859-8",
    "hebrew" => "iso-8859-8",
    "iso-8859-8" => "iso-8859-8",
    "iso-8859-8-e" => "iso-8859-8",
    "iso-ir-138" => "iso-8859-8",
    "iso8859-8" => "iso-8859-8",
    "iso88598" => "iso-8859-8",
    "iso_8859-8" => "iso-8859-8",
    "iso_8859-8:1988" => "iso-8859-8",
    "visual" => "iso-8859-8",
    "csiso88598i" => "iso-8859-8-i",
    "iso-8859-8-i" => "iso-8859-8-i",
    "logical" => "iso-8859-8-i",
    "csisolatin6" => "iso-8859-10",
    "iso-8859-10" => "iso-8859-10",
    "iso-ir-157" => "iso-8859-10",
    "iso8859-10" => "iso-8859-10",
    "iso885910" => "iso-8859-10",
    "l6" => "iso-8859-10",
    "latin6" => "iso-8859-10",
    "iso-8859-13" => "iso-8859-13",
    "iso8859-13" => "iso-8859-13",
    "iso885913" => "iso-8859-13",
    "iso-8859-14" => "iso-8859-14",
    "iso8859-14" => "iso-8859-14",
    "iso885914" => "iso-8859-14",
    "csisolatin9" => "iso-8859-15",
    "iso-8859-15" => "iso-8859-15",
    "iso8859-15" => "iso-8859-15",
    "iso885915" => "iso-8859-15",
    "iso_8859-15" => "iso-8859-15",
    "l9" => "iso-8859-15",
    "iso-8859-16" => "iso-8859-16",
    "cskoi8r" => "koi8-r",
    "koi" => "koi8-r",
    "koi8" => "koi8-r",
    "koi8-r" => "koi8-r",
    "koi8_r" => "koi8-r",
    "koi8-ru" => "koi8-u",
    "koi8-u" => "koi8-u",
    "csmacintosh" => "macintosh",
    "mac" => "macintosh",
    "macintosh" => "macintosh",
    "x-mac-roman" => "macintosh",
    "dos-874" => "windows-874",
    "iso-8859-11" => "windows-874",
    "iso8859-11" => "windows-874",
    "iso885911" => "windows-874",
    "tis-620" => "windows-874",
    "windows-874" => "windows-874",
    "cp1250" => "windows-1250",
    "windows-1250" => "windows-1250",
    "x-cp1250" => "windows-1250",
    "cp1251" => "windows-1251",
    "windows-1251" => "windows-1251",
    "x-cp1251" => "windows-1251",
    "ansi_x3.4-1968" => "windows-1252",
    "ascii" => "windows-1252",
    "cp1252" => "windows-1252",
    "cp819" => "windows-1252",
    "csisolatin1" => "windows-1252",
    "ibm819" => "windows-1252",
    "iso-8859-1" => "windows-1252",
    "iso-ir-100" => "windows-1252",
    "iso8859-1" => "windows-1252",
    "iso88591" => "windows-1252",
    "iso_8859-1" => "windows-1252",
    "iso_8859-1:1987" => "windows-1252",
    "l1" => "windows-1252",
    "latin1" => "windows-1252",
    "us-ascii" => "windows-1252",
    "windows-1252" => "windows-1252",
    "x-cp1252" => "windows-1252",
    "cp1253" => "windows-1253",
    "windows-1253" => "windows-1253",
    "x-cp1253" => "windows-1253",
    "cp1254" => "windows-1254",
    "csisolatin5" => "windows-1254",
    "iso-8859-9" => "windows-1254",
    "iso-ir-148" => "windows-1254",
    "iso8859-9" => "windows-1254",
    "iso88599" => "windows-1254",
    "iso_8859-9" => "windows-1254",
    "iso_8859-9:1989" => "windows-1254",
    "l5" => "windows-1254",
    "latin5" => "windows-1254",
    "windows-1254" => "windows-1254",
    "x-cp1254" => "windows-1254",
    "cp1255" => "windows-1255",
    "windows-1255" => "windows-1255",
    "x-cp1255" => "windows-1255",
    "cp1256" => "windows-1256",
    "windows-1256" => "windows-1256",
    "x-cp1256" => "windows-1256",
    "cp1257" => "windows-1257",
    "windows-1257" => "windows-1257",
    "x-cp1257" => "windows-1257",
    "cp1258" => "windows-1258",
    "windows-1258" => "windows-1258",
    "x-cp1258" => "windows-1258",
    "x-mac-cyrillic" => "x-mac-cyrillic",
    "x-mac-ukrainian" => "x-mac-cyrillic",
    "chinese" => "gbk",
    "csgb2312" => "gbk",
    "csiso58gb231280" => "gbk",
    "gb2312" => "gbk",
    "gb_2312" => "gbk",
    "gb_2312-80" => "gbk",
    "gbk" => "gbk",
    "iso-ir-58" => "gbk",
    "x-gbk" => "gbk",
    "gb18030" => "gb18030",
    "big5" => "big5",
    "big5-hkscs" => "big5",
    "cn-big5" => "big5",
    "csbig5" => "big5",
    "x-x-big5" => "big5",
    "cseucpkdfmtjapanese" => "euc-jp",
    "euc-jp" => "euc-jp",
    "x-euc-jp" => "euc-jp",
    "csiso2022jp" => "iso-2022-jp",
    "iso-2022-jp" => "iso-2022-jp",
    "csshiftjis" => "shift_jis",
    "ms932" => "shift_jis",
    "ms_kanji" => "shift_jis",
    "shift-jis" => "shift_jis",
    "shift_jis" => "shift_jis",
    "sjis" => "shift_jis",
    "windows-31j" => "shift_jis",
    "x-sjis" => "shift_jis",
    "cseuckr" => "euc-kr",
    "csksc56011987" => "euc-kr",
    "euc-kr" => "euc-kr",
    "iso-ir-149" => "euc-kr",
    "korean" => "euc-kr",
    "ks_c_5601-1987" => "euc-kr",
    "ks_c_5601-1989" => "euc-kr",
    "ksc5601" => "euc-kr",
    "ksc_5601" => "euc-kr",
    "windows-949" => "euc-kr",
    "csiso2022kr" => "replacement",
    "hz-gb-2312" => "replacement",
    "iso-2022-cn" => "replacement",
    "iso-2022-cn-ext" => "replacement",
    "iso-2022-kr" => "replacement",
    "replacement" => "replacement",
    "unicodefffe" => "utf-16be",
    "utf-16be" => "utf-16be",
    "csunicode" => "utf-16le",
    "iso-10646-ucs-2" => "utf-16le",
    "ucs-2" => "utf-16le",
    "unicode" => "utf-16le",
    "unicodefeff" => "utf-16le",
    "utf-16" => "utf-16le",
    "utf-16le" => "utf-16le",
    "x-user-defined" => "x-user-defined"
  }

  defp get_encoding(nil), do: nil

  defp get_encoding(label) when is_binary(label) do
    key = ascii_downcase(ascii_trim(label))
    Map.get(@labels, key)
  end

  # The prescan's processing step: "If charset is UTF-16BE/LE, then set
  # charset to UTF-8. If charset is x-user-defined, then set charset to
  # windows-1252." Get an XML encoding has only the first substitution.
  defp substitute_utf16("utf-16le"), do: "utf-8"
  defp substitute_utf16("utf-16be"), do: "utf-8"
  defp substitute_utf16(name), do: name

  defp substitute_meta("x-user-defined"), do: "windows-1252"
  defp substitute_meta(name), do: substitute_utf16(name)

  defp ascii_trim(s), do: ascii_rtrim(ascii_ltrim(s))

  defp ascii_ltrim(<<c, rest::binary>>) when c in @ws, do: ascii_ltrim(rest)
  defp ascii_ltrim(rest), do: rest

  defp ascii_rtrim(s), do: binary_part(s, 0, ascii_rtrim_size(s, byte_size(s)))
  defp ascii_rtrim_size(_s, 0), do: 0

  defp ascii_rtrim_size(s, size) do
    case binary_part(s, size - 1, 1) do
      <<c>> when c in @ws -> ascii_rtrim_size(s, size - 1)
      _ -> size
    end
  end

  defp ascii_downcase(s), do: ascii_downcase(s, [])

  defp ascii_downcase(<<c, rest::binary>>, acc) when c in ?A..?Z do
    ascii_downcase(rest, [c + 32 | acc])
  end

  defp ascii_downcase(<<c, rest::binary>>, acc) do
    ascii_downcase(rest, [c | acc])
  end

  defp ascii_downcase(<<>>, acc), do: acc_string(acc)

  defp acc_string(acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # "Prescan a byte stream to determine its encoding" with the end condition
  # being the end of the binary. Running out of bytes anywhere in the walk
  # aborts it, and the result is then "get an XML encoding" on the same bytes.
  defp prescan(bytes) do
    utf16_xml_prefix(bytes) || loop(bytes) || xml_encoding(bytes)
  end

  defp utf16_xml_prefix(<<0x3C, 0, 0x3F, 0, 0x78, 0, _::binary>>), do: "utf-16le"
  defp utf16_xml_prefix(<<0, 0x3C, 0, 0x3F, 0, 0x78, _::binary>>), do: "utf-16be"
  defp utf16_xml_prefix(_), do: nil

  defp loop(<<"<!--", rest::binary>>) do
    skip_comment(rest)
  end

  defp loop(<<"<", c1, c2, c3, c4, c5, rest::binary>>)
       when c1 in [?m, ?M] and c2 in [?e, ?E] and c3 in [?t, ?T] and c4 in [?a, ?A] and
              (c5 in @ws or c5 == ?/) do
    collect_meta_attrs(<<c5, rest::binary>>, [], false, nil, nil)
  end

  defp loop(<<"</", c, rest::binary>>) when c in ?A..?Z or c in ?a..?z do
    skip_to_ws_or_gt(rest)
  end

  defp loop(<<"<", c, rest::binary>>) when c in ?A..?Z or c in ?a..?z do
    skip_to_ws_or_gt(rest)
  end

  defp loop(<<"<!", rest::binary>>), do: skip_to_gt(rest)
  defp loop(<<"</", rest::binary>>), do: skip_to_gt(rest)
  defp loop(<<"<?", rest::binary>>), do: skip_to_gt(rest)
  defp loop(<<_, rest::binary>>), do: loop(rest)
  defp loop(<<>>), do: nil

  defp skip_comment(after_opener) do
    haystack = <<"--", after_opener::binary>>

    case :binary.match(haystack, "-->") do
      :nomatch ->
        nil

      {pos, 3} ->
        consumed = pos + 3 - 2
        rest = binary_part(after_opener, consumed, byte_size(after_opener) - consumed)
        loop(rest)
    end
  end

  # "Advance the position pointer so that it points at the first 0x3E byte";
  # the loop's "next byte" step then moves past it.
  defp skip_to_gt(<<?>, _::binary>> = rest), do: next_byte(rest)
  defp skip_to_gt(<<_, rest::binary>>), do: skip_to_gt(rest)
  defp skip_to_gt(<<>>), do: nil

  defp skip_to_ws_or_gt(<<c, _::binary>> = rest) when c in @ws or c == ?> do
    skip_attributes(rest)
  end

  defp skip_to_ws_or_gt(<<_, rest::binary>>), do: skip_to_ws_or_gt(rest)
  defp skip_to_ws_or_gt(<<>>), do: nil

  defp skip_attributes(rest) do
    case get_attribute(rest) do
      :abort -> nil
      {:none, rest} -> next_byte(rest)
      {:attr, _name, _value, rest} -> skip_attributes(rest)
    end
  end

  defp next_byte(<<_, rest::binary>>), do: loop(rest)
  defp next_byte(<<>>), do: nil

  defp collect_meta_attrs(rest, seen, got_pragma, need_pragma, charset) do
    case get_attribute(rest) do
      :abort ->
        nil

      {:none, rest} ->
        process_meta(rest, got_pragma, need_pragma, charset)

      {:attr, name, value, rest} ->
        add_meta_attr(name, value, rest, seen, got_pragma, need_pragma, charset)
    end
  end

  # "If the attribute's name is already in attribute list, then return to the
  # step labeled attributes": the first occurrence of a name wins.
  defp add_meta_attr(name, value, rest, seen, got, need, charset) do
    if name in seen do
      collect_meta_attrs(rest, seen, got, need, charset)
    else
      {got, need, charset} = apply_meta_attr(name, value, got, need, charset)
      collect_meta_attrs(rest, [name | seen], got, need, charset)
    end
  end

  defp process_meta(rest, got_pragma, need_pragma, charset) do
    cond do
      is_nil(need_pragma) -> next_byte(rest)
      need_pragma and not got_pragma -> next_byte(rest)
      charset in [nil, :failure] -> next_byte(rest)
      true -> substitute_meta(charset)
    end
  end

  defp apply_meta_attr("http-equiv", "content-type", _got, need, charset) do
    {true, need, charset}
  end

  defp apply_meta_attr("content", value, got, need, nil) do
    case charset_from_content(value) do
      nil -> {got, need, nil}
      encoding -> {got, true, encoding}
    end
  end

  defp apply_meta_attr("content", _value, got, need, charset) do
    {got, need, charset}
  end

  defp apply_meta_attr("charset", value, got, _need, _charset) do
    {got, false, get_encoding(value) || :failure}
  end

  defp apply_meta_attr(_name, _value, got, need, charset) do
    {got, need, charset}
  end

  # "Get an attribute": `{:attr, name, value, rest}` with `rest` at the byte
  # after the attribute, `{:none, rest}` with `rest` at the `>` that ends the
  # tag, or `:abort` when the bytes run out.
  defp get_attribute(<<c, rest::binary>>) when c in @ws or c == ?/ do
    get_attribute(rest)
  end

  defp get_attribute(<<?>, _::binary>> = rest), do: {:none, rest}
  defp get_attribute(<<>>), do: :abort

  defp get_attribute(rest), do: attr_name(rest, [])

  defp attr_name(<<?=, rest::binary>>, [_ | _] = name) do
    attr_value_start(rest, acc_string(name))
  end

  defp attr_name(<<c, rest::binary>>, name) when c in @ws do
    attr_name_spaces(rest, name)
  end

  defp attr_name(<<c, _::binary>> = rest, name) when c in [?/, ?>] do
    {:attr, acc_string(name), "", rest}
  end

  defp attr_name(<<c, rest::binary>>, name) when c in ?A..?Z do
    attr_name(rest, [c + 32 | name])
  end

  defp attr_name(<<c, rest::binary>>, name) do
    attr_name(rest, [c | name])
  end

  defp attr_name(<<>>, _name), do: :abort

  defp attr_name_spaces(<<c, rest::binary>>, name) when c in @ws do
    attr_name_spaces(rest, name)
  end

  defp attr_name_spaces(<<?=, rest::binary>>, name) do
    attr_value_start(rest, acc_string(name))
  end

  defp attr_name_spaces(<<>>, _name), do: :abort

  defp attr_name_spaces(rest, name) do
    {:attr, acc_string(name), "", rest}
  end

  defp attr_value_start(<<c, rest::binary>>, name) when c in @ws do
    attr_value_start(rest, name)
  end

  defp attr_value_start(<<?>, _::binary>> = rest, name) do
    {:attr, name, "", rest}
  end

  defp attr_value_start(<<q, rest::binary>>, name) when q in [?", ?'] do
    attr_quoted(rest, name, q, [])
  end

  defp attr_value_start(<<c, rest::binary>>, name) when c in ?A..?Z do
    attr_unquoted(rest, name, [c + 32])
  end

  defp attr_value_start(<<c, rest::binary>>, name) do
    attr_unquoted(rest, name, [c])
  end

  defp attr_value_start(<<>>, _name), do: :abort

  defp attr_quoted(<<q, rest::binary>>, name, q, acc) do
    {:attr, name, acc_string(acc), rest}
  end

  defp attr_quoted(<<c, rest::binary>>, name, q, acc) when c in ?A..?Z do
    attr_quoted(rest, name, q, [c + 32 | acc])
  end

  defp attr_quoted(<<c, rest::binary>>, name, q, acc) do
    attr_quoted(rest, name, q, [c | acc])
  end

  defp attr_quoted(<<>>, _name, _q, _acc), do: :abort

  defp attr_unquoted(<<c, _::binary>> = rest, name, acc) when c in @ws or c == ?> do
    {:attr, name, acc_string(acc), rest}
  end

  defp attr_unquoted(<<c, rest::binary>>, name, acc) when c in ?A..?Z do
    attr_unquoted(rest, name, [c + 32 | acc])
  end

  defp attr_unquoted(<<c, rest::binary>>, name, acc) do
    attr_unquoted(rest, name, [c | acc])
  end

  defp attr_unquoted(<<>>, _name, _acc), do: :abort

  # "Extracting a character encoding from a meta element": find "charset"
  # ASCII case-insensitively, skip whitespace, require "=", skip whitespace,
  # then a quoted value or one ending at whitespace or ";". Without the "=",
  # look for the next "charset" from where the search stopped.
  defp charset_from_content(<<c1, c2, c3, c4, c5, c6, c7, rest::binary>>)
       when c1 in [?c, ?C] and c2 in [?h, ?H] and c3 in [?a, ?A] and c4 in [?r, ?R] and
              c5 in [?s, ?S] and c6 in [?e, ?E] and c7 in [?t, ?T] do
    after_charset_keyword(ascii_ltrim(rest))
  end

  defp charset_from_content(<<_, rest::binary>>), do: charset_from_content(rest)
  defp charset_from_content(<<>>), do: nil

  defp after_charset_keyword(<<?=, rest::binary>>), do: charset_value(ascii_ltrim(rest))
  defp after_charset_keyword(rest), do: charset_from_content(rest)

  defp charset_value(<<q, rest::binary>>) when q in [?", ?'] do
    case :binary.split(rest, <<q>>) do
      [value, _tail] -> get_encoding(value)
      [_unterminated] -> nil
    end
  end

  defp charset_value(rest), do: get_encoding(unquoted_charset(rest, []))

  defp unquoted_charset(<<c, _::binary>>, acc) when c in @ws or c == ?;, do: acc_string(acc)
  defp unquoted_charset(<<c, rest::binary>>, acc), do: unquoted_charset(rest, [c | acc])
  defp unquoted_charset(<<>>, acc), do: acc_string(acc)

  # "Get an XML encoding": only at the start of the stream, only up to the
  # first ">", and only a quoted value after "encoding" and "=" with any run
  # of bytes at or below 0x20 skipped between them.
  defp xml_encoding(<<"<?xml", _::binary>> = bytes) do
    case :binary.split(bytes, ">") do
      [declaration, _rest] -> xml_declaration_encoding(declaration)
      [_no_close] -> nil
    end
  end

  defp xml_encoding(_bytes), do: nil

  defp xml_declaration_encoding(declaration) do
    case :binary.split(declaration, "encoding") do
      [_before, after_keyword] -> xml_encoding_equals(skip_controls(after_keyword))
      [_no_keyword] -> nil
    end
  end

  defp xml_encoding_equals(<<?=, rest::binary>>), do: xml_encoding_value(skip_controls(rest))
  defp xml_encoding_equals(_rest), do: nil

  defp xml_encoding_value(<<q, rest::binary>>) when q in [?", ?'] do
    case :binary.split(rest, <<q>>) do
      [value, _tail] -> xml_encoding_name(value)
      [_unterminated] -> nil
    end
  end

  defp xml_encoding_value(_rest), do: nil

  # "If the byte at encodingPosition is less than or equal to 0x20 ... return
  # failure": a value holding a space or control is not an encoding name.
  defp xml_encoding_name(value) do
    if control_free?(value), do: substitute_utf16(get_encoding(value)), else: nil
  end

  defp control_free?(<<c, _::binary>>) when c <= 0x20, do: false
  defp control_free?(<<_, rest::binary>>), do: control_free?(rest)
  defp control_free?(<<>>), do: true

  defp skip_controls(<<c, rest::binary>>) when c <= 0x20, do: skip_controls(rest)
  defp skip_controls(rest), do: rest
end
