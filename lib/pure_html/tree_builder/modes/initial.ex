defmodule PureHTML.TreeBuilder.Modes.Initial do
  @moduledoc """
  HTML5 "initial" insertion mode.

  This is the starting mode before any content is processed.

  Per HTML5 spec:
  - DOCTYPE token: Create DOCTYPE, switch to "before html"
  - Comment token: Insert as child of Document
  - Whitespace: Ignore
  - Anything else: Switch to "before html" and reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-initial-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  @impl true
  def process({:character, text}, state) do
    text
    |> split_whitespace()
    |> initial_characters(state)
  end

  def process({:comment, _text}, state) do
    # Comments in initial mode are inserted as children of the Document
    # This is handled at the document level in TreeBuilder.process_token
    # The mode module just needs to not change mode
    ok(state)
  end

  def process({:pi, _target, _data}, state), do: ok(state)

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # DOCTYPE handling is done at process_token level
    # Valid DOCTYPE -> not quirks mode (quirks_mode stays false)
    state
    |> set_mode(:before_html)
    |> ok()
  end

  def process(_token, state) do
    # Any other token without DOCTYPE: parse error, set quirks mode
    state
    |> parse_error()
    |> Map.put(:quirks_mode, true)
    |> set_mode(:before_html)
    |> reprocess()
  end

  # "A character token that is ASCII whitespace: Ignore the token."
  defp initial_characters({_whitespace, ""}, state), do: ok(state)

  # Anything else with no DOCTYPE seen: parse error, quirks mode, before html.
  # The leading whitespace was ignored; the rest is reprocessed.
  defp initial_characters({_whitespace, rest}, state) do
    state
    |> parse_error()
    |> Map.put(:quirks_mode, true)
    |> set_mode(:before_html)
    |> reprocess_with({:character, rest})
  end
end
