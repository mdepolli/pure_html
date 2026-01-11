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
    only: [add_text_to_stack: 2, add_child_to_stack: 2, add_child: 2]

  @impl true
  # Whitespace: insert
  def process({:character, text}, state) do
    case extract_whitespace(text) do
      {"", _non_ws} ->
        # Non-whitespace: close colgroup, reprocess
        case close_colgroup(state) do
          {:ok, new_state} -> {:reprocess, new_state}
          :not_colgroup -> {:ok, state}
        end

      {ws, ""} ->
        # All whitespace: insert
        {:ok, add_text_to_stack(state, ws)}

      {ws, _non_ws} ->
        # Mixed: insert whitespace, then close colgroup and reprocess rest
        state = add_text_to_stack(state, ws)

        case close_colgroup(state) do
          {:ok, new_state} -> {:reprocess, new_state}
          :not_colgroup -> {:ok, state}
        end
    end
  end

  # Comments: insert
  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: html - process using in_body rules
  def process({:start_tag, "html", _, _}, state) do
    {:reprocess, %{state | mode: :in_body}}
  end

  # Start tag: col - insert void element
  def process({:start_tag, "col", attrs, _}, state) do
    {:ok, add_child_to_stack(state, {"col", attrs, []})}
  end

  # Start tag: template - process using in_head rules
  def process({:start_tag, "template", _, _}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Other start tags: close colgroup, reprocess
  def process({:start_tag, _, _, _}, state) do
    case close_colgroup(state) do
      {:ok, new_state} -> {:reprocess, new_state}
      :not_colgroup -> {:ok, state}
    end
  end

  # End tag: colgroup - pop and switch to in_table
  def process({:end_tag, "colgroup"}, %{stack: stack} = state) do
    case stack do
      [%{tag: "colgroup"} = colgroup | rest] ->
        {:ok, %{state | stack: add_child(rest, colgroup), mode: :in_table}}

      _ ->
        # Not in colgroup, ignore
        {:ok, state}
    end
  end

  # End tag: col - parse error, ignore
  def process({:end_tag, "col"}, state) do
    {:ok, state}
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Other end tags: close colgroup, reprocess
  def process({:end_tag, _}, state) do
    case close_colgroup(state) do
      {:ok, new_state} -> {:reprocess, new_state}
      :not_colgroup -> {:ok, state}
    end
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp extract_whitespace(text) do
    {ws, rest} =
      text
      |> String.graphemes()
      |> Enum.split_while(&(&1 in [" ", "\t", "\n", "\r", "\f"]))

    {Enum.join(ws), Enum.join(rest)}
  end

  # Close colgroup if current node is colgroup
  defp close_colgroup(%{stack: [%{tag: "colgroup"} = colgroup | rest]} = state) do
    {:ok, %{state | stack: add_child(rest, colgroup), mode: :in_table}}
  end

  defp close_colgroup(_state), do: :not_colgroup
end
