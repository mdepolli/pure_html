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

  import PureHTML.TreeBuilder.Helpers, only: [extract_whitespace: 1]

  @impl true
  def process({:comment, text}, state) do
    # Insert comment as child of the Document (sibling of html, stored in post_html_nodes)
    {:ok, %{state | post_html_nodes: [{:comment, text} | state.post_html_nodes]}}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:character, text}, state) do
    case extract_whitespace(text) do
      "" ->
        # Non-whitespace: parse error, switch to in_body, reprocess
        {:reprocess, %{state | mode: :in_body}}

      ^text ->
        # All whitespace: process using "in body" rules
        {:reprocess, %{state | mode: :in_body}}
    end
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process(_token, state) do
    # Anything else: parse error, switch to "in body", reprocess
    {:reprocess, %{state | mode: :in_body}}
  end
end
