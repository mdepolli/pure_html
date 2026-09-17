defmodule PureHTML.TreeBuilder.Modes.InCell do
  @moduledoc """
  HTML5 "in cell" insertion mode.

  This mode handles content inside a <td> or <th> element.

  Per HTML5 spec:
  - Character tokens: process using "in body" rules
  - Comments: process using "in body" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption, col, colgroup, tbody, td, tfoot, th, thead, tr: close cell, reprocess
    - Anything else: process using "in body" rules
  - End tags:
    - td, th: close cell, switch to "in row"
    - body, caption, col, colgroup, html: parse error, ignore
    - table, tbody, tfoot, thead, tr: close cell if in scope, reprocess
    - Anything else: process using "in body" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incell
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InBody

  # Start tags that close the cell
  @cell_closing_start_tags ~w(caption col colgroup tbody td tfoot th thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html)

  # End tags that close the cell if in scope
  @cell_closing_end_tags ~w(table tbody tfoot thead tr)

  @cell_tags ~w(td th)

  @impl true
  # Character tokens: process using in_body rules
  def process({:character, _} = token, state) do
    InBody.process(token, state)
  end

  # Comments: process using in_body rules
  def process({:comment, _} = token, state) do
    InBody.process(token, state)
  end

  def process({:pi, _, _} = token, state) do
    InBody.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Cell-closing start tags: close cell, reprocess
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:start_tag, tag, _, _}, state) when tag in @cell_closing_start_tags do
    @cell_tags
    |> Enum.find(&in_scope?(state, &1, :table))
    |> close_cell_or_error(state)
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: td or th - close cell, switch to in_row
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:end_tag, tag}, state) when tag in ["td", "th"] do
    if in_scope?(state, tag, :table) do
      state
      |> close_cell(tag)
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # Cell-closing end tags: close cell if TARGET tag is in table scope, reprocess
  def process({:end_tag, tag}, state) when tag in @cell_closing_end_tags do
    # Per spec: only close cell if the end tag's target is in table scope
    if in_scope?(state, tag, :table) do
      @cell_tags
      |> Enum.find(&in_scope?(state, &1, :table))
      |> close_cell_or_ignore(state)
    else
      # Per spec: "parse error; ignore."
      state
      |> parse_error()
      |> ok()
    end
  end

  # Other end tags: process using in_body rules
  def process({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # EOF: process using in_body rules
  def process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp close_cell_or_error(nil, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp close_cell_or_error(tag, state) do
    state
    |> close_cell(tag)
    |> reprocess()
  end

  defp close_cell_or_ignore(nil, state), do: ok(state)

  defp close_cell_or_ignore(tag, state) do
    state
    |> close_cell(tag)
    |> reprocess()
  end

  # Close the td or th cell. Caller guarantees `tag` is in table scope.
  defp close_cell(state, tag) do
    state
    |> generate_implied_end_tags()
    |> parse_error_unless_current(tag)
    |> pop_cell(tag)
  end

  defp pop_cell(state, tag) do
    state
    |> pop_until_tag(tag)
    |> after_pop_cell()
  end

  defp after_pop_cell({:ok, state}) do
    state
    |> set_mode(:in_row)
    |> clear_af_to_marker()
  end
end
