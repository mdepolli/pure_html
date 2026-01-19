defmodule PureHTML.Query.Selector do
  @moduledoc """
  Represents a parsed CSS selector and provides matching functionality.
  """

  alias PureHTML.Query.Selector.AttributeSelector

  defstruct type: nil, id: nil, classes: [], attributes: []

  @type t :: %__MODULE__{
          type: String.t() | nil,
          id: String.t() | nil,
          classes: [String.t()],
          attributes: [AttributeSelector.t()]
        }

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
    is_element?(node) and
      type_matches?(node, selector.type) and
      id_matches?(node, selector.id) and
      classes_match?(node, selector.classes) and
      attributes_match?(node, selector.attributes)
  end

  defp is_element?({tag, attrs, _children}) when is_binary(tag) and is_list(attrs), do: true

  defp is_element?({{_ns, tag}, attrs, _children}) when is_binary(tag) and is_list(attrs),
    do: true

  defp is_element?(_), do: false

  defp type_matches?(_node, nil), do: true
  defp type_matches?(_node, "*"), do: true
  defp type_matches?({{_ns, tag}, _, _}, type), do: tag == type
  defp type_matches?({tag, _, _}, type) when is_binary(tag), do: tag == type

  defp id_matches?(_node, nil), do: true

  defp id_matches?(node, id) do
    get_attr(node, "id") == id
  end

  defp classes_match?(_node, []), do: true

  defp classes_match?(node, required_classes) do
    node_classes =
      node
      |> get_attr("class")
      |> case do
        nil -> MapSet.new()
        class_str -> class_str |> String.split() |> MapSet.new()
      end

    Enum.all?(required_classes, &MapSet.member?(node_classes, &1))
  end

  defp attributes_match?(_node, []), do: true

  defp attributes_match?(node, attr_selectors) do
    Enum.all?(attr_selectors, fn attr_sel ->
      value = get_attr(node, attr_sel.name)
      AttributeSelector.match?(value, attr_sel)
    end)
  end

  defp get_attr({{_ns, _tag}, attrs, _children}, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp get_attr({_tag, attrs, _children}, name) when is_list(attrs) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end

defmodule PureHTML.Query.Selector.AttributeSelector do
  @moduledoc """
  Represents an attribute selector like `[href]` or `[href^="https"]`.
  """

  defstruct name: nil, value: nil, match_type: :exists

  @type match_type :: :exists | :equal | :prefix | :suffix | :substring

  @type t :: %__MODULE__{
          name: String.t(),
          value: String.t() | nil,
          match_type: match_type()
        }

  @doc """
  Checks if an attribute value matches this selector.
  """
  @spec match?(String.t() | nil, t()) :: boolean()
  def match?(value, %__MODULE__{match_type: :exists}) do
    value != nil
  end

  def match?(value, %__MODULE__{match_type: :equal, value: expected}) do
    value == expected
  end

  def match?(value, %__MODULE__{match_type: :prefix, value: prefix}) do
    value != nil and String.starts_with?(value, prefix)
  end

  def match?(value, %__MODULE__{match_type: :suffix, value: suffix}) do
    value != nil and String.ends_with?(value, suffix)
  end

  def match?(value, %__MODULE__{match_type: :substring, value: substr}) do
    value != nil and String.contains?(value, substr)
  end
end
