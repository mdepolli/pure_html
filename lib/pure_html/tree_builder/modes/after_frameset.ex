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

  import PureHTML.TreeBuilder.Helpers,
    only: [add_child_to_stack: 2, add_text_to_stack: 2, extract_whitespace: 1]

  @impl true
  def process({:character, text}, state) do
    # Only whitespace is inserted, non-whitespace is ignored
    case extract_whitespace(text) do
      "" ->
        {:ok, state}

      whitespace ->
        {:ok, add_text_to_stack(state, whitespace)}
    end
  end

  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:start_tag, "noframes", _attrs, _self_closing}, state) do
    # Process using "in head" rules, preserve original mode to return here after text mode
    {:reprocess, %{state | original_mode: :after_frameset, mode: :in_head}}
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after frameset"
    {:ok, %{state | mode: :after_after_frameset}}
  end

  def process(_token, state) do
    # Anything else: parse error, ignore
    {:ok, state}
  end
end
