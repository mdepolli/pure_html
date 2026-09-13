defmodule PureHTML.TreeBuilder.Modes.InTableBody do
  @moduledoc """
  HTML5 "in table body" insertion mode.

  This mode handles content inside tbody, thead, or tfoot elements.

  Per HTML5 spec:
  - Character tokens: process using "in table" rules
  - Comments: process using "in table" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - tr: clear to table body context, insert tr, switch to "in row"
    - th, td: parse error, insert tr, reprocess
    - caption, col, colgroup, tbody, tfoot, thead: close table body, reprocess
    - Anything else: process using "in table" rules
  - End tags:
    - tbody, tfoot, thead: close if in scope, switch to "in table"
    - table: close table body, reprocess
    - body, caption, col, colgroup, html, td, th, tr: parse error, ignore
    - Anything else: process using "in table" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  # Table body elements
  @table_body_tags ~w(tbody tfoot thead)

  # Start tags that close the table body
  @body_closing_start_tags ~w(caption col colgroup tbody tfoot thead)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html td th tr)

  # Table body context tags
  @table_body_context_tags ~w(tbody tfoot thead template html)

  @impl true
  # Character tokens: process using in_table rules (delegation)
  def process({:character, _} = token, state) do
    process_in_table(state, token)
  end

  # Comments: process using in_table rules (delegation)
  def process({:comment, _} = token, state) do
    process_in_table(state, token)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: tr - insert row, switch to in_row
  def process({:start_tag, "tr", attrs, _}, state) do
    state
    |> clear_to_table_body_context()
    |> push_element("tr", attrs)
    |> set_mode(:in_row)
    |> ok()
  end

  # Start tag: th, td - parse error, insert implied tr, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in ["th", "td"] do
    state
    |> parse_error()
    |> clear_to_table_body_context()
    |> push_element("tr", [])
    |> set_mode(:in_row)
    |> reprocess()
  end

  # Body-closing start tags: close table body, reprocess
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:start_tag, tag, _, _}, state) when tag in @body_closing_start_tags do
    @table_body_tags
    |> Enum.find(&in_scope?(state, &1, :table))
    |> close_table_body_or_error(state)
  end

  # Other start tags: process using in_table rules (delegation, not mode switch).
  # Per WHATWG spec, "process the token using the rules for in_table" is a
  # delegation for one token. The tree construction dispatcher handles foreign
  # content routing for subsequent tokens.
  def process({:start_tag, _, _, _} = token, state) do
    process_in_table(state, token)
  end

  # End tag: tbody, tfoot, thead - close if in scope
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:end_tag, tag}, state) when tag in @table_body_tags do
    if in_scope?(state, tag, :table) do
      state
      |> close_table_body(tag)
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: table - close table body, reprocess
  # Per spec: "If not in table scope, parse error; ignore."
  def process({:end_tag, "table"}, state) do
    @table_body_tags
    |> Enum.find(&in_scope?(state, &1, :table))
    |> close_table_body_or_error(state)
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # Other end tags: process using in_table rules (delegation)
  def process({:end_tag, _} = token, state) do
    process_in_table(state, token)
  end

  # EOF: process using in_body rules
  def process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Clear stack to table body context (tbody, tfoot, thead, template, html)
  defp clear_to_table_body_context(state) do
    pop_until_one_of(state, @table_body_context_tags)
  end

  defp close_table_body_or_error(nil, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp close_table_body_or_error(tag, state) do
    state
    |> close_table_body(tag)
    |> reprocess()
  end

  # Close the tbody/tfoot/thead. Caller guarantees `tag` is in table scope.
  defp close_table_body(state, tag) do
    state
    |> pop_until_tag(tag)
    |> after_pop_table_body()
  end

  defp after_pop_table_body({:ok, state}), do: set_mode(state, :in_table)
end
