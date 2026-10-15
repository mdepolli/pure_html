defmodule PureHTML.Query.Selector do
  @moduledoc false
  # Represents a parsed CSS selector and provides matching functionality.

  alias PureHTML.Query.Selector.AttributeSelector

  defstruct type: nil, html_type: nil, ids: [], classes: [], attributes: []

  @type t :: %__MODULE__{
          type: String.t() | :universal | nil,
          html_type: String.t() | :universal | nil,
          ids: [String.t()],
          classes: [String.t()],
          attributes: [AttributeSelector.t()]
        }

  @ascii_whitespace [" ", "\t", "\n", "\f", "\r"]

  @doc """
  Checks if a node matches this selector.

  ## Examples

      iex> selector = PureHTML.Query.Selector.put_type(%PureHTML.Query.Selector{}, "div")
      iex> PureHTML.Query.Selector.match?({"div", [], []}, selector)
      true

      iex> selector = PureHTML.Query.Selector.put_type(%PureHTML.Query.Selector{}, "div")
      iex> PureHTML.Query.Selector.match?({"p", [], []}, selector)
      false

  """
  @spec match?(term(), t()) :: boolean()
  def match?(node, %__MODULE__{} = selector) do
    element?(node) and
      type_matches?(node, selector) and
      ids_match?(node, selector.ids) and
      classes_match?(node, selector.classes) and
      attributes_match?(node, selector.attributes)
  end

  @doc """
  Checks if a node is an element: an HTML element or a foreign one.
  """
  @spec element?(term()) :: boolean()
  def element?({tag, attrs, _children}) when is_binary(tag) and is_list(attrs), do: true

  def element?({{_ns, tag}, attrs, _children}) when is_binary(tag) and is_list(attrs),
    do: true

  def element?(_), do: false

  @doc """
  Sets the type selector of a compound: `:universal`, or a name.

  HTML, case-sensitivity of selectors: a type selector is ASCII lowercased
  before it is compared to the name of an HTML element, and compared as
  written to the name of any other element. Both forms are kept, so a
  selector meets either kind of element without lowercasing again.
  """
  @spec put_type(t(), String.t() | :universal) :: t()
  def put_type(selector, :universal), do: %{selector | type: :universal, html_type: :universal}

  def put_type(selector, type),
    do: %{selector | type: type, html_type: String.downcase(type, :ascii)}

  defp type_matches?(_node, %__MODULE__{type: nil}), do: true
  defp type_matches?(_node, %__MODULE__{type: :universal}), do: true
  defp type_matches?({{_ns, tag}, _, _}, %__MODULE__{type: type}), do: tag == type
  defp type_matches?({tag, _, _}, %__MODULE__{html_type: type}), do: tag == type

  defp ids_match?(_node, []), do: true

  # An element has one ID, so every ID selector of a compound must name it.
  defp ids_match?(node, ids) do
    id = attr_value(node, "id")
    Enum.all?(ids, &(&1 == id))
  end

  defp classes_match?(_node, []), do: true

  defp classes_match?(node, required_classes) do
    class_names =
      node
      |> attr_value("class")
      |> split_class_names()

    Enum.all?(required_classes, &(&1 in class_names))
  end

  # The class attribute is a set of space-separated tokens, split on ASCII
  # whitespace.
  defp split_class_names(nil), do: []
  defp split_class_names(value), do: String.split(value, @ascii_whitespace, trim: true)

  defp attributes_match?(_node, []), do: true

  defp attributes_match?(node, attr_selectors) do
    Enum.all?(attr_selectors, &attribute_matches?(node, &1))
  end

  defp attribute_matches?(
         {{_ns, _tag}, _attrs, _children} = node,
         %AttributeSelector{name: name} = attribute
       ) do
    node
    |> attr_value(name)
    |> AttributeSelector.match_foreign?(attribute)
  end

  defp attribute_matches?(node, %AttributeSelector{html_name: name} = attribute) do
    node
    |> attr_value(name)
    |> AttributeSelector.match_html?(attribute)
  end

  # A namespaced attribute's name is a {namespace, name} tuple, so a plain
  # name never finds it.
  defp attr_value({_tag, attrs, _children}, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
