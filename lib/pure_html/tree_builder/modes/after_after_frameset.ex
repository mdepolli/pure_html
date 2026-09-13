defmodule PureHTML.TreeBuilder.Modes.AfterAfterFrameset do
  @moduledoc """
  HTML5 "after after frameset" insertion mode.

  This mode is entered after the closing </html> tag in a frameset document.

  Per HTML5 spec:
  - Comment: Insert as last child of the Document object
  - DOCTYPE: Parse error, ignore
  - Whitespace: Process using "in body" rules
  - <html> start tag: Process using "in body" rules
  - <noframes> start tag: Process using "in head" rules
  - Anything else: Parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-after-after-frameset-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InHead

  @impl true
  def process({:comment, text}, state) do
    # Insert comment as child of the Document (sibling of html, stored in post_html_nodes)
    ok(%{state | post_html_nodes: [{:comment, text} | state.post_html_nodes]})
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  def process({:character, text}, state) do
    text
    |> extract_whitespace()
    |> handle_characters(text, state)
  end

  # Process using "in body" rules
  def process({:start_tag, "html", _, _} = token, state), do: process_in_body(state, token)

  # Process using "in head" rules
  def process({:start_tag, "noframes", _, _} = token, state) do
    InHead.process(token, state)
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
