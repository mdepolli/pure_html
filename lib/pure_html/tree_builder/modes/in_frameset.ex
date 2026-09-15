defmodule PureHTML.TreeBuilder.Modes.InFrameset do
  @moduledoc """
  HTML5 "in frameset" insertion mode.

  This mode handles content inside a <frameset> element.

  Per HTML5 spec:
  - Whitespace characters: insert
  - Non-whitespace: parse error, ignore
  - Comments: insert
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules (merge attrs)
    - frameset: insert element
    - frame: insert void element
    - noframes: process using "in head" rules
  - End tag frameset: pop frameset, switch to "after frameset"
  - Anything else: parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inframeset
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InHead

  @impl true
  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  # Comments: insert
  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  def process({:pi, target, data}, state) do
    state
    |> insert_pi(target, data)
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: html - process using in_body rules
  def process({:start_tag, "html", _, _} = token, state), do: process_in_body(state, token)

  # Start tag: frameset
  def process({:start_tag, "frameset", attrs, _}, state) do
    state
    |> push_element("frameset", attrs)
    |> ok()
  end

  # Start tag: frame (void element)
  def process({:start_tag, "frame", attrs, _}, state) do
    state
    |> add_child_to_stack({"frame", attrs, []})
    |> ok()
  end

  # Start tag: noframes - process using in_head rules
  def process({:start_tag, "noframes", _, _} = token, state) do
    InHead.process(token, state)
  end

  # Other start tags: parse error, ignore
  def process({:start_tag, _tag, _attrs, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # End tag: frameset
  # Per spec: If current node is root html element, ignore. Otherwise pop frameset.
  # If not fragment parsing and current node is no longer frameset, switch to after frameset.
  def process({:end_tag, "frameset"}, state) do
    state
    |> current_tag()
    |> end_frameset(state)
  end

  # Other end tags: parse error, ignore
  def process({:end_tag, _tag}, state) do
    state
    |> parse_error()
    |> ok()
  end

  def process(:eof, state) do
    state
    |> current_tag()
    |> eof(state)
  end

  defp handle_characters("", text, state) do
    state
    |> parse_error(String.length(text))
    |> ok()
  end

  defp handle_characters(ws, ws, state) do
    state
    |> add_text_to_stack(ws)
    |> ok()
  end

  defp handle_characters(whitespace, text, state) do
    n = String.length(text) - String.length(whitespace)

    state
    |> parse_error(n)
    |> add_text_to_stack(whitespace)
    |> ok()
  end

  defp eof("html", state), do: ok(state)

  defp eof(_tag, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp end_frameset("html", state) do
    state
    |> parse_error()
    |> ok()
  end

  defp end_frameset("frameset", state) do
    state
    |> pop_element()
    |> after_pop_frameset()
  end

  defp end_frameset(_tag, state), do: ok(state)

  defp after_pop_frameset(state) do
    state
    |> current_tag()
    |> frameset_mode_after_pop(state)
  end

  # "If the parser's fragment context element is null and the current node is
  # no longer a frameset element, then switch the insertion mode to after
  # frameset."
  defp frameset_mode_after_pop("frameset", state), do: ok(state)

  defp frameset_mode_after_pop(_tag, %{context_element: nil} = state) do
    state
    |> set_mode(:after_frameset)
    |> ok()
  end

  defp frameset_mode_after_pop(_tag, state), do: ok(state)
end
