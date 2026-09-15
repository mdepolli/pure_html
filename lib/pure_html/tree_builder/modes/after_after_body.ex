defmodule PureHTML.TreeBuilder.Modes.AfterAfterBody do
  @moduledoc """
  HTML5 "after after body" insertion mode.

  This mode is entered after the closing </html> tag.

  Per HTML5 spec:
  - Comment: Insert as last child of the Document object
  - DOCTYPE: Parse error, ignore
  - Whitespace: Process using "in body" rules
  - <html> start tag: Process using "in body" rules
  - Anything else: Parse error, switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-after-after-body-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

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

  # "Process the token using the rules for the in body insertion mode": a parse
  # error and an attribute merge onto the html element, with no mode change.
  def process({:start_tag, "html", _attrs, _self_closing} = token, state) do
    process_in_body(state, token)
  end

  # EOF: stop parsing
  def process(:eof, state) do
    ok(state)
  end

  def process(_token, state) do
    state
    |> parse_error()
    |> set_mode(:in_body)
    |> reprocess()
  end

  defp handle_characters("", _text, state) do
    state
    |> parse_error()
    |> set_mode(:in_body)
    |> reprocess()
  end

  # Whitespace: "Process the token using the rules for the in body insertion
  # mode", which reconstructs the active formatting elements before inserting.
  defp handle_characters(text, text, state), do: process_in_body(state, {:character, text})
end
