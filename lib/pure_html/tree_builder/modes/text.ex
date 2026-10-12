defmodule PureHTML.TreeBuilder.Modes.Text do
  @moduledoc false
  # HTML5 "text" insertion mode.
  #
  # This mode handles the content of raw text, RCDATA, and script elements.
  #
  # Per HTML5 spec:
  # - Character tokens: insert the characters (a textarea drops a line feed that
  #   immediately follows its start tag)
  # - End tag: pop the current node, switch to the original insertion mode (the
  #   script end tag has no script execution steps here)
  # - EOF: parse error, pop the current node, switch to the original insertion
  #   mode, reprocess
  #
  # See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incdata

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  @impl true
  def process({:character, text}, state), do: insert_text(text, state)

  # "An end tag whose tag name is "script"" and "Any other end tag": pop the
  # current node and switch to the original insertion mode. The script entry's
  # remaining steps run scripts, which this parser does not.
  def process({:end_tag, _tag}, state) do
    state
    |> close_current_element()
    |> ok()
  end

  def process(:eof, state) do
    # EOF in text mode - parse error, close element and reprocess
    state
    |> parse_error()
    |> close_current_element()
    |> reprocess()
  end

  def process(_token, state) do
    # Anything else shouldn't happen, but handle gracefully
    ok(state)
  end

  defp insert_text("", state), do: ok(state)

  defp insert_text(text, state) do
    state
    |> add_text_to_stack(text)
    |> ok()
  end

  defp close_current_element(%{original_mode: original_mode} = state) do
    state
    |> pop_element()
    |> set_mode(original_mode)
    |> Map.put(:original_mode, nil)
  end
end
