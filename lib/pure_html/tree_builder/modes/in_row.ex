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

  # Start tags that close the row
  @row_closing_start_tags ~w(caption col colgroup tbody tfoot thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html td th)

  # Table body end tags that close row if in scope
  @table_body_end_tags ~w(tbody tfoot thead)

  @impl true
  # Character tokens: process using in_table rules
  def process({:character, _}, state) do
    # Delegate to in_table mode (handles foster parenting)
    {:reprocess, %{state | mode: :in_table}}
  end

  # Comments: process using in_table rules
  def process({:comment, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: th, td - insert cell, switch to in_cell
  def process({:start_tag, tag, attrs, _}, state) when tag in ["th", "td"] do
    state =
      state
      |> clear_to_table_row_context()
      |> push_element(tag, attrs)
      |> push_af_marker()
      |> set_mode(:in_cell)

    {:ok, state}
  end

  # Row-closing start tags: close row, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in @row_closing_start_tags do
    case close_row(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Other start tags: process using in_table rules
  def process({:start_tag, _, _, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # End tag: tr - close row, switch to in_table_body
  def process({:end_tag, "tr"}, state) do
    case close_row(state) do
      {:ok, new_state} ->
        {:ok, %{new_state | mode: :in_table_body}}

      :not_found ->
        {:ok, state}
    end
  end

  # End tag: table - close row, reprocess
  def process({:end_tag, "table"}, state) do
    case close_row(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Table body end tags: close row if in scope, reprocess
  def process({:end_tag, tag}, %{stack: stack} = state) when tag in @table_body_end_tags do
    if has_in_table_scope?(stack, tag) do
      case close_row(state) do
        {:ok, new_state} ->
          {:reprocess, new_state}

        :not_found ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
  end

  # Other end tags: process using in_table rules
  def process({:end_tag, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  defp push_element(%{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  defp set_mode(state, mode), do: %{state | mode: mode}

  defp push_af_marker(%{af: af} = state), do: %{state | af: [:marker | af]}

  # Clear stack to table row context (tr, template, html)
  defp clear_to_table_row_context(%{stack: stack} = state) do
    %{state | stack: do_clear_to_table_row_context(stack)}
  end

  defp do_clear_to_table_row_context([%{tag: tag} | _] = stack)
       when tag in ["tr", "template", "html"] do
    stack
  end

  defp do_clear_to_table_row_context([elem | rest]) do
    do_clear_to_table_row_context(add_child(rest, elem))
  end

  defp do_clear_to_table_row_context([]), do: []

  # Close the current row (tr) if in table scope
  defp close_row(%{stack: stack} = state) do
    if has_in_table_scope?(stack, "tr") do
      new_stack = pop_to_tr(stack)
      {:ok, %{state | stack: new_stack, mode: :in_table_body}}
    else
      :not_found
    end
  end

  defp pop_to_tr([%{tag: "tr"} = tr | rest]) do
    add_child(rest, tr)
  end

  defp pop_to_tr([elem | rest]) do
    pop_to_tr(add_child(rest, elem))
  end

  defp pop_to_tr([]), do: []

  # Check if tag is in table scope
  defp has_in_table_scope?(stack, target), do: do_has_in_table_scope?(stack, target)

  defp do_has_in_table_scope?([%{tag: tag} | _], target) when tag == target, do: true

  defp do_has_in_table_scope?([%{tag: tag} | _], _)
       when tag in ["table", "template", "html"],
       do: false

  defp do_has_in_table_scope?([_ | rest], target), do: do_has_in_table_scope?(rest, target)
  defp do_has_in_table_scope?([], _), do: false

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []
end
