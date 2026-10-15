defmodule PureHTML.Query.Selector.AttributeSelector do
  @moduledoc false
  # Represents an attribute selector like `[href]` or `[href^="https"]`.

  # HTML, case-sensitivity of selectors: the name part is ASCII lowercased
  # before it is compared to the attributes of an HTML element, and compared
  # as written to those of any other element. "Attribute selectors on an HTML
  # element in an HTML document must treat the values of attributes with the
  # following names as ASCII case-insensitive". Both forms are kept, so a
  # selector meets either kind of element without lowercasing again.
  defstruct name: nil,
            html_name: nil,
            value: nil,
            html_value: nil,
            match_type: :exists,
            case_insensitive: false

  @case_insensitive_attributes ~w(
    accept accept-charset align alink axis bgcolor charset checked clear
    codetype color compact declare defer dir direction disabled enctype face
    frame hreflang http-equiv lang language link media method multiple nohref
    noresize noshade nowrap readonly rel rev rules scope scrolling selected
    shape target text type valign valuetype vlink
  )

  @type match_type :: :exists | :equal | :prefix | :suffix | :substring

  @type t :: %__MODULE__{
          name: String.t(),
          html_name: String.t(),
          value: String.t() | nil,
          html_value: String.t() | nil,
          match_type: match_type(),
          case_insensitive: boolean()
        }

  @doc """
  Builds an attribute selector from its name, operator, and value as written.
  """
  @spec new(String.t(), match_type(), String.t() | nil) :: t()
  def new(name, match_type, value) do
    fold_listed_value(%__MODULE__{
      name: name,
      html_name: String.downcase(name, :ascii),
      value: value,
      html_value: value,
      match_type: match_type
    })
  end

  defp fold_listed_value(%__MODULE__{html_name: name, value: value} = selector)
       when name in @case_insensitive_attributes,
       do: %{selector | html_value: ascii_downcase(value), case_insensitive: true}

  defp fold_listed_value(selector), do: selector

  @doc """
  Checks the value of an HTML element's attribute, found by `html_name`.
  """
  @spec match_html?(String.t() | nil, t()) :: boolean()
  def match_html?(value, %__MODULE__{
        case_insensitive: true,
        match_type: match_type,
        html_value: expected
      }) do
    value
    |> ascii_downcase()
    |> compare(match_type, expected)
  end

  def match_html?(value, %__MODULE__{match_type: match_type, html_value: expected}),
    do: compare(value, match_type, expected)

  @doc """
  Checks the value of a foreign element's attribute, found by `name`.
  """
  @spec match_foreign?(String.t() | nil, t()) :: boolean()
  def match_foreign?(value, %__MODULE__{match_type: match_type, value: expected}),
    do: compare(value, match_type, expected)

  defp compare(value, :exists, _expected), do: value != nil

  # Selectors 4: a substring matching attribute selector whose value is the
  # empty string "does not represent anything".
  defp compare(_value, match_type, "") when match_type in [:prefix, :suffix, :substring],
    do: false

  defp compare(value, :equal, expected), do: value == expected
  defp compare(nil, _match_type, _expected), do: false
  defp compare(value, :prefix, prefix), do: String.starts_with?(value, prefix)
  defp compare(value, :suffix, suffix), do: String.ends_with?(value, suffix)
  defp compare(value, :substring, substring), do: String.contains?(value, substring)

  defp ascii_downcase(nil), do: nil
  defp ascii_downcase(string), do: String.downcase(string, :ascii)
end
