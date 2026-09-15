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
  # U+0000: "Parse error. Ignore the token." Any other character token joins
  # the pending table character tokens.
  def process({:character, text}, state) do
    {text, null_count} = split_null_characters(text)

    state
    |> parse_error(null_count)
    |> append_pending_text(text)
    |> ok()
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

  defp append_pending_text(%{pending_table_text: pending} = state, text) do
    %{state | pending_table_text: pending <> text}
  end

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

  # Non-whitespace: "reprocess the character tokens ... using the rules given
  # in the anything else entry in the in table insertion mode": a parse error
  # per character token (we coalesce text), then the in body rules with
  # foster parenting enabled for those tokens.
  defp insert_pending_text(_non_ws, text, state) do
    state
    |> parse_error(String.length(text))
    |> foster_parent_characters(text)
    |> clear_pending_text()
  end

  defp foster_parent_characters(state, text) do
    {:ok, state} =
      state
      |> enable_foster_parenting()
      |> process_in_body({:character, text})

    disable_foster_parenting(state)
  end

  defp clear_pending_text(state), do: %{state | pending_table_text: ""}
end
