defmodule PureHTML.Query.Selector do
  @moduledoc false
  # Represents a parsed CSS selector and provides matching functionality.

  alias PureHTML.Query.Selector.AttributeSelector

  defstruct type: nil, id: nil, classes: [], attributes: []

  @type t :: %__MODULE__{
          type: String.t() | nil,
          id: String.t() | nil,
          classes: [String.t()],
          attributes: [AttributeSelector.t()]
        }

  # HTML, case-sensitivity of selectors: "Attribute selectors on an HTML
  # element in an HTML document must treat the values of attributes with the
  # following names as ASCII case-insensitive".
  @case_insensitive_attributes ~w(
    accept accept-charset align alink axis bgcolor charset checked clear
    codetype color compact declare defer dir direction disabled enctype face
    frame hreflang http-equiv lang language link media method multiple nohref
    noresize noshade nowrap readonly rel rev rules scope scrolling selected
    shape target text type valign valuetype vlink
  )

  @doc """
  Checks if a node matches this selector.

  ## Examples

      iex> selector = %PureHTML.Query.Selector{type: "div"}
      iex> PureHTML.Query.Selector.match?({"div", [], []}, selector)
      true

      iex> selector = %PureHTML.Query.Selector{type: "div"}
      iex> PureHTML.Query.Selector.match?({"p", [], []}, selector)
      false

  """
  @spec match?(term(), t()) :: boolean()
  def match?(node, %__MODULE__{} = selector) do
    element?(node) and
      type_matches?(node, selector.type) and
      id_matches?(node, selector.id) and
      classes_match?(node, selector.classes) and
      attributes_match?(node, selector.attributes)
  end

  defp element?({tag, attrs, _children}) when is_binary(tag) and is_list(attrs), do: true

  defp element?({{_ns, tag}, attrs, _children}) when is_binary(tag) and is_list(attrs),
    do: true

  defp element?(_), do: false

  # HTML, case-sensitivity of selectors: a type selector is ASCII lowercased
  # before it is compared to the name of an HTML element, and compared as
  # written to the name of any other element.
  defp type_matches?(_node, nil), do: true
  defp type_matches?(_node, "*"), do: true
  defp type_matches?({{_ns, tag}, _, _}, type), do: tag == type
  defp type_matches?({tag, _, _}, type), do: tag == String.downcase(type, :ascii)

  defp id_matches?(_node, nil), do: true

  defp id_matches?(node, id) do
    attr_value(node, "id") == id
  end

  defp classes_match?(_node, []), do: true

  defp classes_match?(node, required_classes) do
    node_classes =
      node
      |> attr_value("class")
      |> case do
        nil -> MapSet.new()
        class_str -> class_str |> String.split() |> MapSet.new()
      end

    Enum.all?(required_classes, &MapSet.member?(node_classes, &1))
  end

  defp attributes_match?(_node, []), do: true

  defp attributes_match?(node, attr_selectors) do
    Enum.all?(attr_selectors, &attribute_matches?(node, &1))
  end

  # HTML, case-sensitivity of selectors: the name part of an attribute
  # selector is ASCII lowercased before it is compared to the attributes of an
  # HTML element, and compared as written to those of any other element.
  defp attribute_matches?({{_ns, _tag}, _attrs, _children} = node, attribute) do
    node
    |> attr_value(attribute.name)
    |> AttributeSelector.match?(attribute)
  end

  defp attribute_matches?(node, attribute) do
    name = String.downcase(attribute.name, :ascii)

    node
    |> attr_value(name)
    |> html_attribute_matches?(name, attribute)
  end

  defp html_attribute_matches?(value, name, attribute)
       when name in @case_insensitive_attributes do
    value
    |> ascii_downcase()
    |> AttributeSelector.match?(%{attribute | value: ascii_downcase(attribute.value)})
  end

  defp html_attribute_matches?(value, _name, attribute),
    do: AttributeSelector.match?(value, attribute)

  defp ascii_downcase(nil), do: nil
  defp ascii_downcase(string), do: String.downcase(string, :ascii)

  # A namespaced attribute's name is a {namespace, name} tuple, so a plain
  # name never finds it.
  defp attr_value({_tag, attrs, _children}, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
