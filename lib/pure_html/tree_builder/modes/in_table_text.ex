defmodule PureHTML.TreeBuilder.Modes.InTableText do
  @moduledoc """
  HTML5 "in table text" insertion mode.

  This mode collects character tokens while in table context, then decides
  whether to insert them normally (whitespace only) or foster parent them
  (contains non-whitespace).

  Per HTML5 spec:
  - Character tokens: append to pending table character tokens
  - Anything else:
    - If pending tokens have any non-whitespace: foster parent all
    - Otherwise: insert as normal text
    - Switch back to original mode
    - Reprocess current token

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intabletext
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  # Character tokens: collect into pending list
  def process({:character, text}, %{pending_table_text: pending} = state) do
    {:ok, %{state | pending_table_text: pending <> text}}
  end

  # Any other token: flush pending text, restore mode, reprocess
  def process(_token, state) do
    state = flush_pending_text(state)
    # Restore original mode and reprocess the token
    {:reprocess, %{state | mode: state.original_mode, original_mode: nil}}
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp flush_pending_text(%{pending_table_text: ""} = state) do
    %{state | pending_table_text: ""}
  end

  defp flush_pending_text(%{pending_table_text: text, stack: stack} = state) do
    new_stack =
      if String.trim(text) == "" do
        # Whitespace only: insert normally
        add_text_to_stack(stack, text)
      else
        # Contains non-whitespace: foster parent
        foster_text(stack, text)
      end

    %{state | stack: new_stack, pending_table_text: ""}
  end

  defp add_text_to_stack([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text_to_stack([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text_to_stack([], _text), do: []

  # Foster parent text before the table
  defp foster_text(stack, text) do
    do_foster_text(stack, text, [])
  end

  defp do_foster_text([%{tag: "table"} = table | rest], text, acc) do
    rest = add_text_to_stack(rest, text)
    rebuild_stack(acc, [table | rest])
  end

  defp do_foster_text([current | rest], text, acc) do
    do_foster_text(rest, text, [current | acc])
  end

  defp do_foster_text([], _text, acc) do
    Enum.reverse(acc)
  end

  defp rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)
end
