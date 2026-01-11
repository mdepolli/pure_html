defmodule PureHTML.TreeBuilder.Modes.InCaption do
  @moduledoc """
  HTML5 "in caption" insertion mode.

  This mode handles content inside a <caption> element within a table.

  Per HTML5 spec:
  - Character tokens: process using "in body" rules
  - Comments: process using "in body" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption, col, colgroup, tbody, td, tfoot, th, thead, tr: close caption, reprocess
    - Anything else: process using "in body" rules
  - End tags:
    - caption: close caption, switch to "in table"
    - table: parse error, close caption, reprocess
    - body, col, colgroup, html, tbody, td, tfoot, th, thead, tr: parse error, ignore
    - Anything else: process using "in body" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incaption
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  alias PureHTML.TreeBuilder.Modes.InBody

  # Table-related start tags that close the caption
  @table_tags ~w(caption col colgroup tbody td tfoot th thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body col colgroup html tbody td tfoot th thead tr)

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

  # Table-related start tags: close caption, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in @table_tags do
    case close_caption(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        # Caption not in scope, ignore
        {:ok, state}
    end
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: caption
  def process({:end_tag, "caption"}, state) do
    case close_caption(state) do
      {:ok, new_state} ->
        {:ok, %{new_state | mode: :in_table}}

      :not_found ->
        {:ok, state}
    end
  end

  # End tag: table - close caption, reprocess
  def process({:end_tag, "table"}, state) do
    case close_caption(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
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

  # Close caption if in table scope
  defp close_caption(%{stack: stack, af: af} = state) do
    if has_caption_in_table_scope?(stack) do
      {new_stack, closed_refs} = pop_to_caption(stack, MapSet.new())
      new_af = clear_af_to_marker(af, closed_refs)
      {:ok, %{state | stack: new_stack, af: new_af, mode: :in_table}}
    else
      :not_found
    end
  end

  defp has_caption_in_table_scope?(stack), do: do_has_caption_in_table_scope?(stack)

  defp do_has_caption_in_table_scope?([%{tag: "caption"} | _]), do: true

  defp do_has_caption_in_table_scope?([%{tag: tag} | _])
       when tag in ["table", "template", "html"],
       do: false

  defp do_has_caption_in_table_scope?([_ | rest]), do: do_has_caption_in_table_scope?(rest)
  defp do_has_caption_in_table_scope?([]), do: false

  defp pop_to_caption([%{tag: "caption"} = caption | rest], refs) do
    {add_child(rest, caption), MapSet.put(refs, caption.ref)}
  end

  defp pop_to_caption([elem | rest], refs) do
    pop_to_caption(add_child(rest, elem), MapSet.put(refs, elem.ref))
  end

  defp pop_to_caption([], refs), do: {[], refs}

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
