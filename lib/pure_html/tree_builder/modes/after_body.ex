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

  import PureHTML.TreeBuilder.Helpers

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  # Whitespace: process using "in body" rules but stay in after_body mode
  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  def process({:comment, text}, state) do
    # Insert comment as last child of the first element (html)
    state
    |> add_comment_to_html(text)
    |> ok()
  end

  def process({:pi, target, data}, state) do
    state
    |> add_node_to_html({:pi, target, data})
    |> ok()
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  # "Process the token using the rules for the in body insertion mode": a parse
  # error and an attribute merge onto the html element, with no mode change.
  def process({:start_tag, "html", _attrs, _self_closing} = token, state) do
    process_in_body(state, token)
  end

  def process({:end_tag, "html"}, %{context_element: ctx} = state) when ctx != nil do
    state
    |> parse_error()
    |> ok()
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after body" mode
    state
    |> set_mode(:after_after_body)
    |> ok()
  end

  # EOF: stop parsing
  def process(:eof, state) do
    ok(state)
  end

  def process(_token, state) do
    # Anything else: parse error, switch to "in body", reprocess
    state
    |> parse_error()
    |> set_mode(:in_body)
    |> reprocess()
  end

  # Whitespace: "Process the token using the rules for the in body insertion
  # mode", which reconstructs the active formatting elements before inserting.
  defp handle_characters(ws, ws, state), do: process_in_body(state, {:character, ws})

  # Non-whitespace: parse error, switch to in_body and reprocess
  defp handle_characters(_whitespace, _text, state) do
    state
    |> parse_error()
    |> set_mode(:in_body)
    |> reprocess()
  end

  # Add comment as last child of html element.
  defp add_comment_to_html(state, text), do: add_node_to_html(state, {:comment, text})

  defp add_node_to_html(state, node) do
    state
    |> find_ref("html")
    |> append_node_to_html(state, node)
  end

  defp append_node_to_html(nil, state, _node), do: state

  defp append_node_to_html(ref, %{elements: elements} = state, node) do
    html_elem = elements[ref]
    updated_html = %{html_elem | children: [node | html_elem.children]}
    %{state | elements: Map.put(elements, ref, updated_html)}
  end
end
