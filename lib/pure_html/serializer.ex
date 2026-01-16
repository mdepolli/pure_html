defmodule PureHTML.Serializer do
  @moduledoc """
  Converts parsed HTML nodes back to HTML strings.

  This module implements HTML5 serialization with html5lib-compliant
  attribute quoting.
  """

  @void_elements ~w(area base basefont bgsound br col embed hr img input
                    keygen link meta param source track wbr)

  @raw_text_elements ~w(script style xmp iframe noembed noframes plaintext)

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

      iex> PureHTML.Serializer.serialize([{"p", %{}, ["Hello"]}])
      "<p>Hello</p>"

      iex> PureHTML.Serializer.serialize([{"br", %{}, []}])
      "<br>"

  """
  @spec serialize([term()]) :: String.t()
  def serialize(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&serialize_node/1)
    |> IO.iodata_to_binary()
  end

  # DOCTYPE
  defp serialize_node({:doctype, name, public_id, system_id}) do
    serialize_doctype(name, public_id, system_id)
  end

  # Comment
  defp serialize_node({:comment, text}) do
    ["<!--", text, "-->"]
  end

  # Template content wrapper - unwrap and serialize children
  defp serialize_node({:content, children}) do
    Enum.map(children, &serialize_node/1)
  end

  # Text
  defp serialize_node(text) when is_binary(text) do
    escape_text(text)
  end

  # Foreign element (SVG/MathML)
  defp serialize_node({{_ns, tag}, attrs, children}) do
    serialize_element(tag, attrs, children)
  end

  # HTML element
  defp serialize_node({tag, attrs, children}) when is_binary(tag) do
    serialize_element(tag, attrs, children)
  end

  defp serialize_element(tag, attrs, children) do
    opening = serialize_opening_tag(tag, attrs)

    cond do
      tag in @void_elements ->
        opening

      tag in @raw_text_elements ->
        content = Enum.map(children, &serialize_raw_node/1)
        [opening, content, "</", tag, ">"]

      true ->
        content = Enum.map(children, &serialize_node/1)
        [opening, content, "</", tag, ">"]
    end
  end

  defp serialize_opening_tag(tag, attrs) when map_size(attrs) == 0 do
    ["<", tag, ">"]
  end

  defp serialize_opening_tag(tag, attrs) do
    attr_string = serialize_attrs(attrs)
    ["<", tag, " ", attr_string, ">"]
  end

  defp serialize_attrs(attrs) do
    attrs
    |> Enum.map(fn {name, value} -> serialize_attr(name, value) end)
    |> Enum.intersperse(" ")
  end

  defp serialize_attr(name, value) do
    cond do
      # Empty value - just the attribute name
      value == "" ->
        name

      # Unquoted: safe chars only
      Regex.match?(@unquoted_attr_regex, value) ->
        [name, "=", value]

      # Single quotes: contains " but not '
      String.contains?(value, "\"") and not String.contains?(value, "'") ->
        escaped = escape_attr_single(value)
        [name, "='", escaped, "'"]

      # Double quotes: default (contains ' or both or neither)
      true ->
        escaped = escape_attr_double(value)
        [name, "=\"", escaped, "\""]
    end
  end

  defp escape_attr_single(value) do
    String.replace(value, "&", "&amp;")
  end

  defp escape_attr_double(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
  end

  # Raw text nodes (for script, style, etc.) - no escaping
  defp serialize_raw_node(text) when is_binary(text), do: text
  defp serialize_raw_node({:comment, text}), do: ["<!--", text, "-->"]
  defp serialize_raw_node(other), do: serialize_node(other)

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
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
