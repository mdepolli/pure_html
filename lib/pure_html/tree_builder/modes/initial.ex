defmodule PureHTML.TreeBuilder.Modes.Initial do
  @moduledoc false
  # HTML5 "initial" insertion mode.
  #
  # This is the starting mode before any content is processed.
  #
  # Per HTML5 spec:
  # - DOCTYPE token: Create DOCTYPE, switch to "before html"
  # - Comment token: Insert as child of Document
  # - Whitespace: Ignore
  # - Anything else: Switch to "before html" and reprocess
  #
  # See: https://html.spec.whatwg.org/multipage/parsing.html#the-initial-insertion-mode

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Quirks

  @impl true
  def process({:character, text}, state) do
    text
    |> split_whitespace()
    |> initial_characters(state)
  end

  def process({:comment, text}, state) do
    state
    |> add_document_child({:comment, text})
    |> ok()
  end

  def process({:pi, target, data}, state) do
    state
    |> add_document_child({:pi, target, data})
    |> ok()
  end

  # "If the DOCTYPE token's name is not "html", or the token's public
  # identifier is not missing, or the token's system identifier is neither
  # missing nor "about:legacy-compat", then there is a parse error."
  # The force-quirks flag is not part of the condition: a token that has it
  # set already got its error from the tokenizer.
  def process({:doctype, name, public_id, system_id, force_quirks}, state) do
    state
    |> doctype_parse_error(name, public_id, system_id)
    |> set_doctype(name, public_id, system_id)
    |> set_quirks_mode(Quirks.mode(name, public_id, system_id, force_quirks) == :quirks)
    |> set_mode(:before_html)
    |> ok()
  end

  def process(_token, state) do
    # Any other token without DOCTYPE: parse error, set quirks mode
    state
    |> parse_error()
    |> set_quirks_mode(true)
    |> set_mode(:before_html)
    |> reprocess()
  end

  defp doctype_parse_error(state, "html", nil, nil), do: state
  defp doctype_parse_error(state, "html", nil, "about:legacy-compat"), do: state
  defp doctype_parse_error(state, _name, _public_id, _system_id), do: parse_error(state)

  # "A character token that is ASCII whitespace: Ignore the token."
  defp initial_characters({_whitespace, ""}, state), do: ok(state)

  # Anything else with no DOCTYPE seen: parse error, quirks mode, before html.
  # The leading whitespace was ignored; the rest is reprocessed.
  defp initial_characters({_whitespace, rest}, state) do
    state
    |> parse_error()
    |> set_quirks_mode(true)
    |> set_mode(:before_html)
    |> reprocess_with({:character, rest})
  end
end
