defmodule PureHTML.Serializer do
  @moduledoc """
  Converts parsed HTML nodes back to HTML strings.

  Implements the HTML fragment serialization algorithm.

  ## Options

  - `:scripting` — whether scripting is enabled (default: `true`).

    `to_html/2` is usually called on a tree `parse/2` built. Parse's scripting
    flag decides whether noscript children are a text node or elements. With
    the default parse (scripting on), noscript holds one text node that must
    be emitted literally, so the serializer default is `true`. If the tree was
    parsed with scripting off, noscript holds elements and this flag does not
    affect them.
  """

  @void_elements ~w(area base basefont bgsound br col embed frame hr img input
                    keygen link meta param source track wbr)

  @raw_text_elements ~w(script style xmp iframe noembed noframes plaintext)

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

  defp serialize_node({:doctype, name, public_id, system_id}, _parent, _scripting) do
    serialize_doctype(name, public_id, system_id)
  end

  defp serialize_node({:comment, text}, _parent, _scripting) do
    ["<!--", text, "-->"]
  end

  defp serialize_node({:pi, target, data}, _parent, _scripting) do
    ["<?", target, " ", data, "?>"]
  end

  defp serialize_node({:content, children}, parent, scripting) do
    Enum.map(children, &serialize_node(&1, parent, scripting))
  end

  defp serialize_node(text, parent, scripting) when is_binary(text) do
    if raw_text?(parent, scripting) do
      text
    else
      escape_string(text, :text)
    end
  end

  defp serialize_node({{ns, tag}, attrs, children}, _parent, scripting) do
    serialize_element(ns, tag, attrs, children, scripting)
  end

  defp serialize_node({tag, attrs, children}, _parent, scripting) when is_binary(tag) do
    serialize_element(:html, tag, attrs, children, scripting)
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

  defp serialize_attrs(attrs) do
    Enum.map(attrs, fn {name, value} -> serialize_attr(name, value) end)
  end

  defp serialize_attr(name, value) do
    [" ", attr_name_to_string(name), "=\"", escape_string(value, :attribute), "\""]
  end

  defp attr_name_to_string({:xlink, local}), do: "xlink:" <> local
  defp attr_name_to_string({:xml, local}), do: "xml:" <> local
  defp attr_name_to_string({:xmlns, "xmlns"}), do: "xmlns"
  defp attr_name_to_string({:xmlns, local}), do: "xmlns:" <> local
  defp attr_name_to_string(name) when is_binary(name), do: name

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
  defp serialize_doctype(name, _public_id, _system_id) do
    ["<!DOCTYPE ", name || "", ">"]
  end
end
