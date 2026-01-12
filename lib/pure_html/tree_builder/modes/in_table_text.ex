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

  import PureHTML.TreeBuilder.Helpers, only: [add_text_to_stack: 2, foster_text: 2]

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
        # Contains non-whitespace: foster parent
        foster_text(state, text)
      end

    %{state | pending_table_text: ""}
  end
end
