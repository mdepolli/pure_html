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

  alias PureHTML.TreeBuilder.Modes.InBody

  # Start tags that close the cell
  @cell_closing_start_tags ~w(caption col colgroup tbody td tfoot th thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html)

  # End tags that close the cell if in scope
  @cell_closing_end_tags ~w(table tbody tfoot thead tr)

  @impl true
  # Character tokens: process using in_body rules
  def process({:character, _} = token, state) do
    InBody.process(token, state)
  end

  # Comments: process using in_body rules
  def process({:comment, _} = token, state) do
    InBody.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Cell-closing start tags: close cell, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in @cell_closing_start_tags do
    case close_cell(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        # Cell not in scope, ignore
        {:ok, state}
    end
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: td or th - close cell, switch to in_row
  def process({:end_tag, tag}, state) when tag in ["td", "th"] do
    case close_cell_for_tag(state, tag) do
      {:ok, new_state} ->
        {:ok, %{new_state | mode: :in_row}}

      :not_found ->
        {:ok, state}
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
  end

  # Cell-closing end tags: close cell if in scope, reprocess
  def process({:end_tag, tag}, state) when tag in @cell_closing_end_tags do
    case close_cell(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Other end tags: process using in_body rules
  def process({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Close td or th cell if in table scope
  defp close_cell(%{stack: stack, af: af} = state) do
    cond do
      has_in_table_scope?(stack, "td") ->
        {new_stack, closed_refs} = pop_to_tag(stack, "td", MapSet.new())
        new_af = clear_af_to_marker(af, closed_refs)
        {:ok, %{state | stack: new_stack, af: new_af}}

      has_in_table_scope?(stack, "th") ->
        {new_stack, closed_refs} = pop_to_tag(stack, "th", MapSet.new())
        new_af = clear_af_to_marker(af, closed_refs)
        {:ok, %{state | stack: new_stack, af: new_af}}

      true ->
        :not_found
    end
  end

  # Close specific cell tag if in table scope
  defp close_cell_for_tag(%{stack: stack, af: af} = state, tag) do
    if has_in_table_scope?(stack, tag) do
      {new_stack, closed_refs} = pop_to_tag(stack, tag, MapSet.new())
      new_af = clear_af_to_marker(af, closed_refs)
      {:ok, %{state | stack: new_stack, af: new_af}}
    else
      :not_found
    end
  end

  # Check if tag is in table scope
  defp has_in_table_scope?(stack, target), do: do_has_in_table_scope?(stack, target)

  defp do_has_in_table_scope?([%{tag: tag} | _], target) when tag == target, do: true

  defp do_has_in_table_scope?([%{tag: tag} | _], _)
       when tag in ["table", "template", "html"],
       do: false

  defp do_has_in_table_scope?([_ | rest], target), do: do_has_in_table_scope?(rest, target)
  defp do_has_in_table_scope?([], _), do: false

  # Pop elements until we reach the target tag
  defp pop_to_tag([%{tag: tag} = elem | rest], target, refs) when tag == target do
    {add_child(rest, elem), MapSet.put(refs, elem.ref)}
  end

  defp pop_to_tag([elem | rest], target, refs) do
    pop_to_tag(add_child(rest, elem), target, MapSet.put(refs, elem.ref))
  end

  defp pop_to_tag([], _target, refs), do: {[], refs}

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  # Clear active formatting elements up to marker or for closed refs
  defp clear_af_to_marker(af, closed_refs) do
    Enum.reduce_while(af, [], fn
      :marker, acc ->
        {:halt, Enum.reverse(acc)}

      {ref, _, _} = entry, acc ->
        if MapSet.member?(closed_refs, ref) do
          {:cont, acc}
        else
          {:cont, [entry | acc]}
        end
    end)
    |> case do
      result when is_list(result) -> result
      _ -> []
    end
  end
end
