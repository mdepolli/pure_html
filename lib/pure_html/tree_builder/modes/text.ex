defmodule PureHTML.TreeBuilder.Modes.Text do
  @moduledoc """
  HTML5 "text" insertion mode.

  This mode handles RAWTEXT and RCDATA content (script, style, title, etc.).

  Per HTML5 spec:
  - Character tokens: Insert the character into the current node
  - End tag matching current element: Close element, switch to original mode
  - End tag (script): Special handling (we simplify to same as above)
  - EOF: Parse error, close element, switch to original mode, reprocess
  - Anything else: Should not happen (tokenizer handles RAWTEXT/RCDATA)

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incdata
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [add_text_to_stack: 2, current_tag: 1, pop_element: 1]

  @impl true
  def process({:character, text}, state) do
    # Insert text as child of current element
    {:ok, add_text_to_stack(state, text)}
  end

  def process({:end_tag, tag}, state) do
    # End tag matches current element - close it and restore original mode
    if current_tag(state) == tag do
      {:ok, close_current_element(state)}
    else
      # End tag doesn't match - parse error, ignore
      {:ok, state}
    end
  end

  def process(:eof, state) do
    # EOF in text mode - parse error, close element and reprocess
    {:reprocess, close_current_element(state)}
  end

  def process(_token, state) do
    # Anything else shouldn't happen, but handle gracefully
    {:ok, state}
  end

  # Close current element and restore original mode
  defp close_current_element(%{original_mode: original_mode} = state) do
    state
    |> pop_element()
    |> Map.put(:mode, original_mode)
    |> Map.put(:original_mode, nil)
  end
end
