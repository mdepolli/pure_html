defmodule PureHTML.TreeBuilder.Modes.InSelectInTable do
  @moduledoc """
  HTML5 "in select in table" insertion mode.

  This mode is used when a <select> element is opened inside a table context.
  It differs from "in select" only in handling of table-related end tags.

  Per HTML5 spec:
  - Start tags for table elements (caption, table, tbody, tfoot, thead, tr, td, th):
    Parse error. Close the select element and reprocess the token.
  - End tags for table elements:
    Parse error. If the stack has an element in table scope with the same tag,
    close the select element and reprocess. Otherwise, ignore.
  - Anything else: Process using "in select" rules.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inselectintable
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InSelect

  @table_elements ~w(caption table tbody tfoot thead tr td th)

  @impl true
  # Start tags for table elements: parse error, close select and reprocess
  # Per spec, just close select - no scope check needed (we're already in in_select_in_table)
  def process({:start_tag, tag, _, _}, state) when tag in @table_elements do
    state
    |> parse_error()
    |> close_select_and_reprocess()
  end

  # End tags for table elements: parse error, close select and reprocess if in table scope
  # Per spec, check if tag is in table scope, then close select (no select scope check)
  def process({:end_tag, tag}, state) when tag in @table_elements do
    state
    |> parse_error()
    |> close_select_for_table_end(tag)
  end

  # Everything else: delegate to InSelect
  def process(token, state) do
    InSelect.process(token, state)
  end

  defp close_select_for_table_end(state, tag) do
    state
    |> find_ref("select")
    |> close_select_if_tag_in_table_scope(tag, state)
  end

  defp close_select_if_tag_in_table_scope(nil, _tag, state), do: ok(state)

  defp close_select_if_tag_in_table_scope(_ref, tag, state) do
    state
    |> in_scope?(tag, :table)
    |> reprocess_after_close_select(state)
  end

  defp reprocess_after_close_select(true, state) do
    state
    |> close_select()
    |> reprocess()
  end

  defp reprocess_after_close_select(false, state), do: ok(state)

  defp close_select_and_reprocess(state) do
    state
    |> find_ref("select")
    |> reprocess_past_select(state)
  end

  defp reprocess_past_select(nil, state), do: ok(state)

  defp reprocess_past_select(_ref, state) do
    state
    |> close_select()
    |> reprocess()
  end
end
