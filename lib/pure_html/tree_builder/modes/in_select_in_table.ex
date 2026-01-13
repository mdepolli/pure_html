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

  alias PureHTML.TreeBuilder.Modes.InSelect

  import PureHTML.TreeBuilder.Helpers,
    only: [
      in_table_scope?: 2,
      in_select_scope?: 2,
      close_select: 1
    ]

  @table_elements ~w(caption table tbody tfoot thead tr td th)

  @impl true
  # End tags for table elements: close select and reprocess if in table scope
  def process({:end_tag, tag}, state) when tag in @table_elements do
    if in_table_scope?(state, tag) and in_select_scope?(state, "select") do
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
