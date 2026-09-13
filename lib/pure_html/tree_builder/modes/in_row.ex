defmodule PureHTML.TreeBuilder.Modes.InRow do
  @moduledoc """
  HTML5 "in row" insertion mode.

  This mode handles content inside a <tr> element.

  Per HTML5 spec:
  - Character tokens: process using "in table" rules
  - Comments: process using "in table" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - th, td: clear to table row context, insert element, switch to "in cell"
    - caption, col, colgroup, tbody, tfoot, thead, tr: close row, reprocess
    - Anything else: process using "in table" rules
  - End tags:
    - tr: close row, switch to "in table body"
    - table: close row, reprocess
    - tbody, tfoot, thead: close row if in scope, reprocess
    - body, caption, col, colgroup, html, td, th: parse error, ignore
    - Anything else: process using "in table" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intr
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  # Start tags that close the row
  @row_closing_start_tags ~w(caption col colgroup tbody tfoot thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html td th)

  # Table body end tags that close row if in scope
  @table_body_end_tags ~w(tbody tfoot thead)

  # Table row context tags
  @table_row_context ~w(tr template html)

  @impl true
  # Character tokens: process using in_table rules
  def process({:character, _}, state) do
    # Delegate to in_table mode (handles foster parenting)
    # Set original_mode so in_table_text returns to in_row after text handling
    state
    |> Map.put(:original_mode, :in_row)
    |> set_mode(:in_table)
    |> reprocess()
  end

  # Comments: process using in_table rules
  def process({:comment, _}, state) do
    state
    |> set_mode(:in_table)
    |> reprocess()
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: th, td - insert cell, switch to in_cell
  def process({:start_tag, tag, attrs, _}, state) when tag in ["th", "td"] do
    state
    |> clear_to_table_row_context()
    |> push_element(tag, attrs)
    |> push_af_marker()
    |> set_mode(:in_cell)
    |> ok()
  end

  # Row-closing start tags: close row, reprocess
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:start_tag, tag, _, _}, state) when tag in @row_closing_start_tags do
    if in_scope?(state, "tr", :table) do
      state
      |> close_row()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Other start tags: per spec, process the token using the rules for the
  # "in table" insertion mode.
  def process({:start_tag, _, _, _} = token, state) do
    process_in_table(state, token, :in_row)
  end

  # End tag: tr - close row, switch to in_table_body
  # Per spec: "If not in scope, parse error; ignore."
  def process({:end_tag, "tr"}, state) do
    if in_scope?(state, "tr", :table) do
      state
      |> close_row()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: table - close row, reprocess
  # Per spec: "If not in scope, parse error; ignore."
  def process({:end_tag, "table"}, state) do
    if in_scope?(state, "tr", :table) do
      state
      |> close_row()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Table body end tags: close row if in scope, reprocess
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:end_tag, tag}, state) when tag in @table_body_end_tags do
    if in_scope?(state, tag, :table) and in_scope?(state, "tr", :table) do
      state
      |> close_row()
      |> reprocess()
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

  # Other end tags: per spec, process the token using the rules for the
  # "in table" insertion mode.
  def process({:end_tag, _} = token, state) do
    process_in_table(state, token, :in_row)
  end

  # EOF: reprocess in in_body
  def process(:eof, state) do
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Clear stack to table row context (tr, template, html)
  defp clear_to_table_row_context(state) do
    pop_until_one_of(state, @table_row_context)
  end

  # Close the current row (tr). Caller guarantees a tr is in table scope.
  defp close_row(state) do
    state
    |> pop_until_tag("tr")
    |> after_pop_row()
  end

  defp after_pop_row({:ok, state}), do: set_mode(state, :in_table_body)
end
