defmodule PureHTML.TreeBuilder.Modes.InHeadNoscript do
  @moduledoc """
  HTML5 "in head noscript" insertion mode.

  This mode handles content inside a <noscript> element within <head>.

  Per HTML5 spec:
  - Character tokens (whitespace): process using "in head" rules
  - Comments: process using "in head" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules
    - basefont, bgsound, link, meta, noframes, style: process using "in head" rules
    - head, noscript: parse error, ignore
    - Anything else: parse error, pop noscript, switch to "in head", reprocess
  - End tags:
    - noscript: pop noscript, switch to "in head"
    - br: parse error, pop noscript, switch to "in head", reprocess
    - Anything else: parse error, ignore
  - EOF: anything else (parse error, pop noscript, switch to "in head", reprocess)

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inheadnoscript
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Modes.InHead

  # Start tags processed using "in head" rules
  @in_head_start_tags ~w(basefont bgsound link meta noframes style)

  # Start tags that are parse errors and ignored
  @ignored_start_tags ~w(head noscript)

  @impl true
  def process({:character, text}, state) do
    text
    |> split_whitespace()
    |> noscript_characters(state)
  end

  # Comments: process using "in head" rules
  def process({:comment, _} = token, state) do
    InHead.process(token, state)
  end

  def process({:pi, _, _} = token, state) do
    InHead.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: html - process using "in body" rules
  def process({:start_tag, "html", _, _} = token, state) do
    InBody.process(token, state)
  end

  # Start tags processed using "in head" rules
  def process({:start_tag, tag, _, _} = token, state) when tag in @in_head_start_tags do
    InHead.process(token, state)
  end

  # Start tags that are parse errors and ignored
  def process({:start_tag, tag, _, _}, state) when tag in @ignored_start_tags do
    state
    |> parse_error()
    |> ok()
  end

  # Any other start tag: parse error, pop noscript, switch to in_head, reprocess
  def process({:start_tag, _, _, _}, state) do
    state
    |> parse_error()
    |> pop_noscript()
    |> reprocess()
  end

  # End tag: noscript - pop noscript, switch to "in head"
  def process({:end_tag, "noscript"}, state) do
    state
    |> pop_noscript()
    |> ok()
  end

  # End tag: br - parse error, pop noscript, switch to in_head, reprocess
  def process({:end_tag, "br"}, state) do
    state
    |> parse_error()
    |> pop_noscript()
    |> reprocess()
  end

  # Any other end tag: parse error, ignore
  def process({:end_tag, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # EOF is not an entry of its own: anything else
  def process(:eof, state) do
    state
    |> parse_error()
    |> pop_noscript()
    |> reprocess()
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # ASCII whitespace uses the in head rules, which insert it. Anything else is
  # a parse error that pops the noscript and is reprocessed in head, so the
  # whitespace ahead of it goes in first.
  defp noscript_characters({whitespace, ""}, state) do
    state
    |> add_text_to_stack(whitespace)
    |> ok()
  end

  defp noscript_characters({"", rest}, state) do
    state
    |> parse_error()
    |> pop_noscript()
    |> reprocess_with({:character, rest})
  end

  defp noscript_characters({whitespace, rest}, state) do
    state
    |> add_text_to_stack(whitespace)
    |> parse_error()
    |> pop_noscript()
    |> reprocess_with({:character, rest})
  end

  # "Pop the current node (which will be a noscript element) off the stack of
  # open elements. Switch the insertion mode to 'in head'."
  defp pop_noscript(state) do
    state
    |> pop_element()
    |> set_mode(:in_head)
  end
end
