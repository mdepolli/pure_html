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

  @impl true
  def process({:character, text}, %{stack: stack} = state) do
    # Insert text as child of current element
    {:ok, %{state | stack: add_text_child(stack, text)}}
  end

  def process({:end_tag, tag}, %{stack: [%{tag: tag} | _]} = state) do
    # End tag matches current element - close it and restore original mode
    {:ok, close_current_element(state)}
  end

  def process({:end_tag, _tag}, state) do
    # End tag doesn't match - parse error, ignore
    {:ok, state}
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
  defp close_current_element(%{stack: [elem | rest], original_mode: original_mode} = state) do
    %{state | stack: add_child(rest, elem), mode: original_mode, original_mode: nil}
  end

  defp close_current_element(state) do
    %{state | mode: state.original_mode, original_mode: nil}
  end

  # Add a child to the current element
  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  # Add text as child of the current element
  defp add_text_child(stack, text), do: add_child(stack, text)
end
