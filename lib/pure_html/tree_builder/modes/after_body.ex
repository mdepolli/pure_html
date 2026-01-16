defmodule PureHTML.TreeBuilder.Modes.AfterBody do
  @moduledoc """
  HTML5 "after body" insertion mode.

  This mode is entered after the body element is closed.

  Per HTML5 spec:
  - Whitespace: Process using "in body" rules
  - Comment: Insert as last child of the first element (html)
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - </html> end tag: Switch to "after after body" (we stay in after_body)
  - Anything else: Parse error, switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-afterbody
  """

  import PureHTML.TreeBuilder.Helpers, only: [add_text_to_stack: 2, find_ref: 2]

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  # Whitespace: process using "in body" rules but stay in after_body mode
  def process({:character, text}, state) do
    if String.match?(text, ~r/^[\t\n\f\r ]*$/) do
      {:ok, add_text_to_stack(state, text)}
    else
      # Non-whitespace: parse error, switch to in_body and reprocess
      {:reprocess, %{state | mode: :in_body}}
    end
  end

  def process({:comment, text}, state) do
    # Insert comment as last child of the first element (html)
    {:ok, add_comment_to_html(state, text)}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after body" mode
    {:ok, %{state | mode: :after_after_body}}
  end

  def process(_token, state) do
    # Anything else: parse error, switch to "in body", reprocess
    {:reprocess, %{state | mode: :in_body}}
  end

  # Add comment as last child of html element.
  defp add_comment_to_html(%{elements: elements} = state, text) do
    case find_ref(state, "html") do
      nil ->
        state

      ref ->
        html_elem = elements[ref]
        updated_html = %{html_elem | children: [{:comment, text} | html_elem.children]}
        %{state | elements: Map.put(elements, ref, updated_html)}
    end
  end
end
