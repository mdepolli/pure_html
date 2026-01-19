defmodule PureHTML.Serializer do
  @moduledoc """
  Converts parsed HTML nodes back to HTML strings.

  This module implements HTML5 serialization with html5lib-compliant
  attribute quoting and various output options.

  ## Options

  - `:quote_char` - Force `"'"` or `"\""` for attribute quotes (default: smart quoting)
  - `:minimize_boolean_attributes` - Output `disabled` vs `disabled=disabled` (default: true)
  - `:use_trailing_solidus` - Output `<br />` vs `<br>` (default: false)
  - `:escape_lt_in_attrs` - Escape `<` in attribute values (default: false)
  - `:escape_rcdata` - Escape content in script/style (default: false)
  - `:strip_whitespace` - Collapse whitespace in text nodes (default: false)
  """

  @void_elements ~w(area base basefont bgsound br col embed hr img input
                    keygen link meta param source track wbr)

  @raw_text_elements ~w(script style xmp iframe noembed noframes plaintext)

  @whitespace_preserving ~w(pre textarea script style)

  # Characters that require quoting in attribute values
  # Per html5lib tests:
  # - < is allowed unquoted (browser will parse correctly)
  # - > requires quoting
  # - Only ASCII whitespace (space, tab, LF, CR, FF) requires quoting
  # - Vertical tab (U+000B) is allowed unquoted
  @unquoted_attr_regex ~r/^[^ \t\n\r\f"'=>`]+$/

  @doc """
  Serializes a list of parsed HTML nodes to an HTML string.

  ## Examples

      iex> PureHTML.Serializer.serialize([{"p", [], ["Hello"]}])
      "<p>Hello</p>"

      iex> PureHTML.Serializer.serialize([{"br", [], []}])
      "<br>"

      iex> PureHTML.Serializer.serialize([{"br", [], []}], use_trailing_solidus: true)
      "<br />"

  """
  @spec serialize([term()], keyword()) :: String.t()
  def serialize(nodes, opts \\ [])

  def serialize(nodes, opts) when is_list(nodes) do
    nodes
    |> Enum.map(&serialize_node(&1, nil, opts))
    |> IO.iodata_to_binary()
  end

  # DOCTYPE
  defp serialize_node({:doctype, name, public_id, system_id}, _context, _opts) do
    serialize_doctype(name, public_id, system_id)
  end

  # Comment
  defp serialize_node({:comment, text}, _context, _opts) do
    ["<!--", text, "-->"]
  end

  # Template content wrapper - unwrap and serialize children
  defp serialize_node({:content, children}, context, opts) do
    Enum.map(children, &serialize_node(&1, context, opts))
  end

  # Text
  defp serialize_node(text, context, opts) when is_binary(text) do
    escape_rcdata = Keyword.get(opts, :escape_rcdata, false)
    strip_whitespace = Keyword.get(opts, :strip_whitespace, false)

    text =
      if strip_whitespace and context not in @whitespace_preserving do
        strip_ws(text)
      else
        text
      end

    if context in @raw_text_elements and not escape_rcdata do
      text
    else
      escape_text(text)
    end
  end

  # Foreign element (SVG/MathML)
  defp serialize_node({{_ns, tag}, attrs, children}, _context, opts) do
    serialize_element(tag, attrs, children, opts)
  end

  # HTML element
  defp serialize_node({tag, attrs, children}, _context, opts) when is_binary(tag) do
    serialize_element(tag, attrs, children, opts)
  end

  defp serialize_element(tag, attrs, children, opts) do
    opening = serialize_opening_tag(tag, attrs, opts)

    cond do
      tag in @void_elements ->
        opening

      tag in @raw_text_elements ->
        content = Enum.map(children, &serialize_node(&1, tag, opts))
        [opening, content, "</", tag, ">"]

      true ->
        content = Enum.map(children, &serialize_node(&1, tag, opts))
        [opening, content, "</", tag, ">"]
    end
  end

  defp serialize_opening_tag(tag, attrs, opts) when attrs == [] do
    if tag in @void_elements and Keyword.get(opts, :use_trailing_solidus, false) do
      ["<", tag, " />"]
    else
      ["<", tag, ">"]
    end
  end

  defp serialize_opening_tag(tag, attrs, opts) do
    attr_string = serialize_attrs(attrs, opts)

    if tag in @void_elements and Keyword.get(opts, :use_trailing_solidus, false) do
      ["<", tag, " ", attr_string, " />"]
    else
      ["<", tag, " ", attr_string, ">"]
    end
  end

  defp serialize_attrs(attrs, opts) do
    attrs
    |> Enum.map(fn {name, value} -> serialize_attr(name, value, opts) end)
    |> Enum.intersperse(" ")
  end

  defp serialize_attr(name, value, opts) do
    quote_char = Keyword.get(opts, :quote_char)
    minimize = Keyword.get(opts, :minimize_boolean_attributes, true)
    escape_lt = Keyword.get(opts, :escape_lt_in_attrs, false)

    case determine_quote_style(name, value, quote_char, minimize) do
      :empty_quoted -> [name, "=\"\""]
      :minimized -> name
      :single -> [name, "='", escape_attr_single(value, escape_lt), "'"]
      :double -> [name, "=\"", escape_attr_double(value, escape_lt), "\""]
      :unquoted -> [name, "=", value]
    end
  end

  defp determine_quote_style(_name, "", _quote_char, false), do: :empty_quoted
  defp determine_quote_style(_name, "", _quote_char, _minimize), do: :minimized
  defp determine_quote_style(name, name, _quote_char, true), do: :minimized
  defp determine_quote_style(_name, _value, "'", _minimize), do: :single
  defp determine_quote_style(_name, _value, "\"", _minimize), do: :double

  defp determine_quote_style(_name, value, _quote_char, _minimize) do
    cond do
      Regex.match?(@unquoted_attr_regex, value) ->
        :unquoted

      String.contains?(value, "\"") and not String.contains?(value, "'") ->
        :single

      true ->
        :double
    end
  end

  defp escape_attr_single(value, escape_lt) do
    value = String.replace(value, "&", "&amp;")
    value = String.replace(value, "'", "&#39;")

    if escape_lt do
      String.replace(value, "<", "&lt;")
    else
      value
    end
  end

  defp escape_attr_double(value, escape_lt) do
    value =
      value
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")

    if escape_lt do
      String.replace(value, "<", "&lt;")
    else
      value
    end
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Collapse whitespace: replace sequences of whitespace chars with single space
  defp strip_ws(text) do
    text
    |> String.replace(~r/[\t\r\n\f]+/, " ")
    |> String.replace(~r/  +/, " ")
  end

  # DOCTYPE serialization
  defp serialize_doctype(name, nil, nil) do
    ["<!DOCTYPE ", name, ">"]
  end

  defp serialize_doctype(name, "", system_id) when is_binary(system_id) do
    ["<!DOCTYPE ", name, " SYSTEM \"", system_id, "\">"]
  end

  defp serialize_doctype(name, public_id, nil) when is_binary(public_id) do
    ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\">"]
  end

  defp serialize_doctype(name, public_id, system_id)
       when is_binary(public_id) and is_binary(system_id) do
    ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\" \"", system_id, "\">"]
  end
end
