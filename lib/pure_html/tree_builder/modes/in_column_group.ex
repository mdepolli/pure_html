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

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incolgroup
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [
      add_text_to_stack: 2,
      add_child_to_stack: 2,
      pop_element: 1,
      current_tag: 1,
      split_whitespace: 1,
      parse_error: 1,
      parse_error: 2
    ]

  @impl true
  def process({:character, text}, state) do
    {ws, rest} = split_whitespace(text)
    handle_characters(ws, rest, current_tag(state), state)
  end

  # Comments: insert
  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, parse_error(state)}
  end

  def process({:start_tag, "html", _, _}, state) do
    html_start(current_tag(state), state)
  end

  # Start tag: col - insert void element
  def process({:start_tag, "col", attrs, _}, state) do
    {:ok, add_child_to_stack(state, {"col", attrs, []})}
  end

  # Start tag: template - process using in_head rules
  def process({:start_tag, "template", _, _}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:start_tag, _, _, _}, state) do
    close_colgroup_or_ignore(current_tag(state), state)
  end

  def process({:end_tag, "colgroup"}, state) do
    end_colgroup(current_tag(state), state)
  end

  # End tag: col - parse error, ignore
  def process({:end_tag, "col"}, state) do
    {:ok, parse_error(state)}
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, _}, state) do
    close_colgroup_or_ignore(current_tag(state), state)
  end

  # EOF: process using "in body" rules
  def process(:eof, state) do
    {:reprocess, %{state | mode: :in_body}}
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp handle_characters(ws, "", _tag, state) do
    {:ok, add_text_to_stack(state, ws)}
  end

  defp handle_characters("", _rest, "colgroup", state) do
    {:reprocess, pop_colgroup(state)}
  end

  defp handle_characters(ws, _rest, "colgroup", state) do
    state = add_text_to_stack(state, ws)
    {:reprocess, pop_colgroup(state)}
  end

  defp handle_characters("", rest, _tag, state) do
    {:ok, parse_error(state, String.length(rest))}
  end

  defp handle_characters(ws, rest, _tag, state) do
    state = add_text_to_stack(state, ws)
    {:ok, parse_error(state, String.length(rest))}
  end

  defp html_start("colgroup", state) do
    {:reprocess, %{state | mode: :in_body}}
  end

  defp html_start(_tag, state) do
    {:ok, parse_error(state)}
  end

  defp end_colgroup("colgroup", state) do
    {:ok, pop_colgroup(state)}
  end

  defp end_colgroup(_tag, state) do
    {:ok, parse_error(state)}
  end

  defp close_colgroup_or_ignore("colgroup", state) do
    {:reprocess, pop_colgroup(state)}
  end

  defp close_colgroup_or_ignore(_tag, state) do
    {:ok, parse_error(state)}
  end

  defp pop_colgroup(state) do
    state
    |> pop_element()
    |> Map.put(:mode, :in_table)
  end
end
