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

  alias PureHTML.TreeBuilder.Modes.InHead

  @impl true
  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  # Process using "in body" rules
  def process({:start_tag, "html", _, _} = token, state), do: process_in_body(state, token)

  # Process using "in head" rules
  def process({:start_tag, "noframes", _, _} = token, state) do
    InHead.process(token, state)
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after frameset"
    state
    |> set_mode(:after_after_frameset)
    |> ok()
  end

  # EOF: stop parsing
  def process(:eof, state) do
    ok(state)
  end

  def process(_token, state) do
    state
    |> parse_error()
    |> ok()
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
end
