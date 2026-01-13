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

  import PureHTML.TreeBuilder.Helpers, only: [extract_whitespace: 1, add_text_to_stack: 2]

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
        # Non-whitespace: parse error, ignore
        {:ok, state}

      ^text ->
        # All whitespace: process using "in body" rules (insert to body)
        {:ok, add_text_to_stack(state, text)}
    end
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:start_tag, "noframes", _attrs, _self_closing}, state) do
    # Process using "in head" rules, preserve original mode to return here after text mode
    {:reprocess, %{state | original_mode: :after_after_frameset, mode: :in_head}}
  end

  def process(_token, state) do
    # Anything else: parse error, ignore
    {:ok, state}
  end
end
