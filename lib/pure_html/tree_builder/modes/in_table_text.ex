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
      (using "in body" rules with foster parenting enabled)
    - Otherwise: insert as normal text
    - Switch back to original mode
    - Reprocess current token

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intabletext
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  @impl true
  # Character tokens: collect into pending list
  def process({:character, text}, %{pending_table_text: pending} = state) do
    ok(%{state | pending_table_text: pending <> text})
  end

  # Any other token: flush pending text, restore mode, reprocess
  def process(_token, state) do
    state
    |> flush_pending_text()
    |> restore_original_mode()
    |> reprocess()
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp restore_original_mode(%{original_mode: mode} = state) do
    %{state | mode: mode, original_mode: nil}
  end

  defp flush_pending_text(%{pending_table_text: ""} = state), do: state

  defp flush_pending_text(%{pending_table_text: text} = state) do
    text
    |> String.trim()
    |> insert_pending_text(text, state)
  end

  # Whitespace only: insert normally
  defp insert_pending_text("", text, state) do
    state
    |> add_text_to_stack(text)
    |> clear_pending_text()
  end

  # html5lib counts one foster-parenting-character parse error per
  # character token; we coalesce text, so increment per codepoint.
  defp insert_pending_text(_non_ws, text, state) do
    state
    |> parse_error(String.length(text))
    |> foster_parent_with_formatting(text)
    |> clear_pending_text()
  end

  defp clear_pending_text(state), do: %{state | pending_table_text: ""}

  # Foster parent text with active formatting reconstruction
  # This emulates "in body" processing with foster parenting enabled
  defp foster_parent_with_formatting(%{af: af, stack: stack} = state, text) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.filter(fn {ref, _tag, _attrs} -> ref not in stack end)
    |> foster_parent_text(text, state)
  end

  # No formatting to reconstruct - just foster parent the text
  defp foster_parent_text([], text, state) do
    {new_state, _ref} = foster_parent(state, {:text, text})
    new_state
  end

  # Reconstruct formatting elements (they'll be foster parented)
  # Then add text to the reconstructed element (not foster parented)
  defp foster_parent_text(_entries, text, state) do
    state
    |> reconstruct_formatting_for_foster()
    |> add_text_to_stack(text)
  end

  # Reconstruct active formatting elements for foster parenting
  # Creates clones of formatting elements and foster-parents them
  defp reconstruct_formatting_for_foster(%{stack: stack, af: af} = state) do
    # Get entries to reconstruct (formatting elements not on stack)
    entries =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {ref, _tag, _attrs} ->
        not Enum.any?(stack, &(&1 == ref))
      end)

    # Reconstruct each entry with foster parenting
    reconstruct_entries_foster(entries, state)
  end

  defp reconstruct_entries_foster([], state), do: state

  defp reconstruct_entries_foster([{old_ref, tag, attrs} | rest], state) do
    # Foster-push the element (inserts before table)
    {new_state, new_ref} = foster_parent(state, {:push, tag, attrs})

    # Update AF entry to point to new ref
    new_af = update_af_entry(new_state.af, old_ref, {new_ref, tag, attrs})
    reconstruct_entries_foster(rest, %{new_state | af: new_af})
  end
end
