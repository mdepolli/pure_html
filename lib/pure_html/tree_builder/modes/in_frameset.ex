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

  @impl true
  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  # Comments: insert
  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    state |> parse_error() |> ok()
  end

  # Start tag: html - process using in_body rules (merge attrs)
  def process({:start_tag, "html", _attrs, _}, state) do
    state |> set_mode(:in_body) |> reprocess()
  end

  # Start tag: frameset
  def process({:start_tag, "frameset", attrs, _}, state) do
    state |> push_element("frameset", attrs) |> ok()
  end

  # Start tag: frame (void element)
  def process({:start_tag, "frame", attrs, _}, state) do
    {:ok, add_child_to_stack(state, {"frame", attrs, []})}
  end

  # Start tag: noframes - process using in_head rules
  # Set original_mode so text mode returns here after noframes closes
  def process({:start_tag, "noframes", _attrs, _}, state) do
    state |> Map.put(:original_mode, :in_frameset) |> set_mode(:in_head) |> reprocess()
  end

  # Other start tags: parse error, ignore
  def process({:start_tag, _tag, _attrs, _}, state) do
    state |> parse_error() |> ok()
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
    state |> parse_error() |> ok()
  end

  def process(:eof, state) do
    state
    |> current_tag()
    |> eof(state)
  end

  defp handle_characters("", text, state) do
    state |> parse_error(String.length(text)) |> ok()
  end

  defp handle_characters(ws, ws, state) do
    state |> add_text_to_stack(ws) |> ok()
  end

  defp handle_characters(whitespace, text, state) do
    n = String.length(text) - String.length(whitespace)
    state = parse_error(state, n)
    state |> add_text_to_stack(whitespace) |> ok()
  end

  defp eof("html", state), do: {:ok, state}
  defp eof(_tag, state), do: state |> parse_error() |> ok()

  defp end_frameset("html", state), do: state |> parse_error() |> ok()

  defp end_frameset("frameset", state) do
    state
    |> pop_element()
    |> after_pop_frameset()
  end

  defp end_frameset(_tag, state), do: {:ok, state}

  defp after_pop_frameset(state) do
    state
    |> current_tag()
    |> frameset_mode_after_pop(state)
  end

  defp frameset_mode_after_pop("frameset", state), do: {:ok, %{state | mode: :in_frameset}}
  defp frameset_mode_after_pop(_tag, state), do: {:ok, %{state | mode: :after_frameset}}
end
