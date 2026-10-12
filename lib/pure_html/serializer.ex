defmodule PureHTML.Serializer do
  @moduledoc false
  # Converts parsed HTML nodes back to HTML strings.
  #
  # Implements the HTML fragment serialization algorithm.
  #
  # `PureHTML.to_html/2` documents the `:scripting` option.

  @void_elements ~w(area base basefont bgsound br col embed frame hr img input
                    keygen link meta param source track wbr)

  @raw_text_elements ~w(script style xmp iframe noembed noframes plaintext)

  defguardp string_or_nil(value) when is_binary(value) or is_nil(value)

  @doc """
  Serializes a list of parsed HTML nodes to an HTML string.

  ## Examples

      iex> PureHTML.Serializer.serialize([{"p", [], ["Hello"]}])
      "<p>Hello</p>"

      iex> PureHTML.Serializer.serialize([{"br", [], []}])
      "<br>"

      iex> PureHTML.Serializer.serialize([{"span", [{"title", "foo"}], []}])
      "<span title=\\"foo\\"></span>"

  """
  @spec serialize([PureHTML.html_node()], keyword()) :: String.t()
  def serialize(nodes, opts \\ []) when is_list(nodes) do
    scripting = Keyword.get(opts, :scripting, true)

    nodes
    |> Enum.map(&serialize_node(&1, nil, scripting))
    |> IO.iodata_to_binary()
  end

  @doc "True for the HTML void elements, which serialize as a start tag only."
  @spec void_element?(String.t()) :: boolean()
  def void_element?(tag), do: tag in @void_elements

  defp serialize_node({:doctype, name, public_id, system_id}, _parent, _scripting)
       when string_or_nil(name) and string_or_nil(public_id) and string_or_nil(system_id) do
    serialize_doctype(name)
  end

  defp serialize_node({:comment, text}, _parent, _scripting) when is_binary(text) do
    ["<!--", text, "-->"]
  end

  defp serialize_node({:pi, target, data}, _parent, _scripting)
       when is_binary(target) and is_binary(data) do
    ["<?", target, " ", data, "?>"]
  end

  defp serialize_node({:content, children}, parent, scripting) when is_list(children) do
    Enum.map(children, &serialize_node(&1, parent, scripting))
  end

  defp serialize_node(text, parent, scripting) when is_binary(text) do
    if raw_text?(parent, scripting) do
      text
    else
      escape_string(text, :text)
    end
  end

  defp serialize_node({{ns, tag}, attrs, children}, _parent, scripting)
       when ns in [:svg, :math] and is_binary(tag) and is_list(attrs) and is_list(children) do
    serialize_element(ns, tag, attrs, children, scripting)
  end

  defp serialize_node({tag, attrs, children}, _parent, scripting)
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    serialize_element(:html, tag, attrs, children, scripting)
  end

  defp serialize_node(node, _parent, _scripting) do
    raise ArgumentError, "not an html_node: #{inspect(node)}"
  end

  defp serialize_element(ns, tag, attrs, children, scripting) do
    opening = serialize_opening_tag(tag, attrs)

    if serializes_as_void?(ns, tag) do
      opening
    else
      parent = {ns, tag}
      content = Enum.map(children, &serialize_node(&1, parent, scripting))
      [opening, content, "</", tag, ">"]
    end
  end

  defp serializes_as_void?(:html, tag), do: tag in @void_elements
  defp serializes_as_void?(_ns, _tag), do: false

  defp raw_text?({:html, tag}, _scripting) when tag in @raw_text_elements, do: true
  defp raw_text?({:html, "noscript"}, true), do: true
  defp raw_text?(_parent, _scripting), do: false

  defp serialize_opening_tag(tag, []), do: ["<", tag, ">"]

  defp serialize_opening_tag(tag, attrs) do
    ["<", tag, serialize_attrs(attrs), ">"]
  end

  defp serialize_attrs(attrs), do: Enum.map(attrs, &serialize_attr/1)

  defp serialize_attr({name, value} = attr) when is_binary(value) do
    [" ", attr_name_to_string(name, attr), "=\"", escape_string(value, :attribute), "\""]
  end

  defp serialize_attr(attr), do: raise_invalid_attr(attr)

  defp attr_name_to_string({:xlink, local}, _attr) when is_binary(local), do: "xlink:" <> local
  defp attr_name_to_string({:xml, local}, _attr) when is_binary(local), do: "xml:" <> local
  defp attr_name_to_string({:xmlns, "xmlns"}, _attr), do: "xmlns"
  defp attr_name_to_string({:xmlns, local}, _attr) when is_binary(local), do: "xmlns:" <> local
  defp attr_name_to_string(name, _attr) when is_binary(name), do: name
  defp attr_name_to_string(_name, attr), do: raise_invalid_attr(attr)

  defp raise_invalid_attr(attr) do
    raise ArgumentError, "not an attribute: #{inspect(attr)}"
  end

  defp escape_string(text, :text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("\u00A0", "&nbsp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_string(text, :attribute) do
    text
    |> escape_string(:text)
    |> String.replace("\"", "&quot;")
  end

  # HTML fragment serialization: "<!DOCTYPE ", the name, ">". A missing
  # name is the empty string, so the space stays.
  defp serialize_doctype(name) do
    ["<!DOCTYPE ", name || "", ">"]
  end
end
