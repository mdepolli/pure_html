defmodule PureHTML.TreeBuilder.Modes.AfterFrameset do
  @moduledoc """
  HTML5 "after frameset" insertion mode.

  This mode is entered after the frameset element is closed.

  Per HTML5 spec:
  - Whitespace: Insert the character
  - Comment: Insert a comment
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - </html> end tag: Switch to "after after frameset" (we stay in after_frameset)
  - <noframes> start tag: Process using "in head" rules
  - Anything else: Parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-afterframeset
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  @impl true
  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state |> parse_error() |> ok()
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    state |> set_mode(:in_body) |> reprocess()
  end

  def process({:start_tag, "noframes", _attrs, _self_closing}, state) do
    # Process using "in head" rules, preserve original mode to return here after text mode
    state |> Map.put(:original_mode, :after_frameset) |> set_mode(:in_head) |> reprocess()
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after frameset"
    {:ok, %{state | mode: :after_after_frameset}}
  end

  # EOF: stop parsing
  def process(:eof, state) do
    {:ok, state}
  end

  def process(_token, state) do
    state |> parse_error() |> ok()
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
end
