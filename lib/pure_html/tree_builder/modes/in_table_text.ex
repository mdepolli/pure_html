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

  import PureHTML.TreeBuilder.Helpers, only: [add_text_to_stack: 2, foster_parent: 2]

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
    state
  end

  defp flush_pending_text(%{pending_table_text: text} = state) do
    state =
      if String.trim(text) == "" do
        # Whitespace only: insert normally
        add_text_to_stack(state, text)
      else
        # Contains non-whitespace: foster parent with active formatting reconstruction
        # Per spec: "process the token using the rules for 'in body' insertion mode"
        # with foster parenting enabled
        foster_parent_with_formatting(state, text)
      end

    %{state | pending_table_text: ""}
  end

  # Foster parent text with active formatting reconstruction
  # This emulates "in body" processing with foster parenting enabled
  defp foster_parent_with_formatting(%{af: af} = state, text) do
    # Check if we have any formatting elements to reconstruct
    entries_to_reconstruct =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.filter(fn {ref, _tag, _attrs} ->
        not Enum.any?(state.stack, &(&1 == ref))
      end)

    if entries_to_reconstruct == [] do
      # No formatting to reconstruct - just foster parent the text
      {new_state, _} = foster_parent(state, {:text, text})
      new_state
    else
      # Reconstruct formatting elements (they'll be foster parented)
      # Then add text to the reconstructed element (not foster parented)
      state
      |> reconstruct_formatting_for_foster()
      |> add_text_to_stack(text)
    end
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
    new_state = %{new_state | af: new_af}

    reconstruct_entries_foster(rest, new_state)
  end

  defp update_af_entry(af, old_ref, new_entry) do
    Enum.map(af, fn
      {^old_ref, _, _} -> new_entry
      entry -> entry
    end)
  end
end
