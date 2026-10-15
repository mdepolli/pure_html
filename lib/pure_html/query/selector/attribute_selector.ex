defmodule PureHTML.Query.Selector.AttributeSelector do
  @moduledoc false
  # Represents an attribute selector like `[href]` or `[href^="https"]`.

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
