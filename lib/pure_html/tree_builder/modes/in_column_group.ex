defmodule PureHTML.TreeBuilder.Modes.InColumnGroup do
  @moduledoc """
  HTML5 "in column group" insertion mode.

  This mode handles content inside a <colgroup> element within a table.

  Per HTML5 spec:
  - Character tokens:
    - Whitespace: insert
    - Anything else: close colgroup, reprocess in "in table"
  - Comments: insert
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules
    - col: insert void element
    - template: process using "in head" rules
    - Anything else: close colgroup, reprocess in "in table"
  - End tags:
    - colgroup: pop colgroup, switch to "in table"
    - col: parse error, ignore
    - template: process using "in head" rules
    - Anything else: close colgroup, reprocess in "in table"
  - EOF: process using "in body" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incolgroup
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InHead

  @impl true
  def process({:character, text}, state) do
    {ws, rest} = split_whitespace(text)

    state
    |> current_tag()
    |> handle_characters(ws, rest, state)
  end

  # Comments: insert
  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: html - process using in_body rules
  def process({:start_tag, "html", _, _} = token, state), do: process_in_body(state, token)

  # Start tag: col - insert void element
  def process({:start_tag, "col", attrs, _}, state) do
    state
    |> add_child_to_stack({"col", attrs, []})
    |> ok()
  end

  # Start tag: template - process using in_head rules
  def process({:start_tag, "template", _, _} = token, state) do
    InHead.process(token, state)
  end

  def process({:start_tag, _, _, _}, state) do
    state
    |> current_tag()
    |> close_colgroup_or_ignore(state)
  end

  def process({:end_tag, "colgroup"}, state) do
    state
    |> current_tag()
    |> end_colgroup(state)
  end

  # End tag: col - parse error, ignore
  def process({:end_tag, "col"}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"} = token, state) do
    InHead.process(token, state)
  end

  def process({:end_tag, _}, state) do
    state
    |> current_tag()
    |> close_colgroup_or_ignore(state)
  end

  # EOF: process using "in body" rules
  def process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp handle_characters(_tag, ws, "", state) do
    state
    |> add_text_to_stack(ws)
    |> ok()
  end

  defp handle_characters("colgroup", "", _rest, state) do
    state
    |> pop_colgroup()
    |> reprocess()
  end

  defp handle_characters("colgroup", ws, _rest, state) do
    state
    |> add_text_to_stack(ws)
    |> pop_colgroup()
    |> reprocess()
  end

  defp handle_characters(_tag, "", rest, state) do
    state
    |> parse_error(String.length(rest))
    |> ok()
  end

  defp handle_characters(_tag, ws, rest, state) do
    state
    |> add_text_to_stack(ws)
    |> parse_error(String.length(rest))
    |> ok()
  end

  defp end_colgroup("colgroup", state) do
    state
    |> pop_colgroup()
    |> ok()
  end

  defp end_colgroup(_tag, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp close_colgroup_or_ignore("colgroup", state) do
    state
    |> pop_colgroup()
    |> reprocess()
  end

  defp close_colgroup_or_ignore(_tag, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp pop_colgroup(state) do
    state
    |> pop_element()
    |> set_mode(:in_table)
  end
end
