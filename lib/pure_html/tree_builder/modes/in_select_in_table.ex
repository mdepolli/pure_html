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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      in_scope?: 3,
      find_ref: 2,
      close_select: 1
    ]

  alias PureHTML.TreeBuilder.Modes.InSelect

  @table_elements ~w(caption table tbody tfoot thead tr td th)

  @impl true
  # Start tags for table elements: close select and reprocess
  # Per spec, just close select - no scope check needed (we're already in in_select_in_table)
  def process({:start_tag, tag, _, _}, state) when tag in @table_elements do
    if find_ref(state, "select") do
      state = close_select(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # End tags for table elements: close select and reprocess if in table scope
  # Per spec, check if tag is in table scope, then close select (no select scope check)
  def process({:end_tag, tag}, state) when tag in @table_elements do
    if in_scope?(state, tag, :table) && find_ref(state, "select") do
      state = close_select(state)
      {:reprocess, state}
    else
      # Not in table scope, ignore per spec
      {:ok, state}
    end
  end

  # Everything else: delegate to InSelect
  def process(token, state) do
    InSelect.process(token, state)
  end
end
