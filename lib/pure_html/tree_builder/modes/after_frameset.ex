defmodule PureHTML.TreeBuilder.Modes.AfterFrameset do
  @moduledoc """
  HTML5 "after frameset" insertion mode.

  This mode is entered after the frameset element is closed.

  Per HTML5 spec:
  - Whitespace: Insert the character
  - Comment: Insert a comment
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - </html> end tag: Switch to "after after frameset" (we stay in after_frameset)
  - <noframes> start tag: Process using "in head" rules
  - Anything else: Parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-afterframeset
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  def process({:character, text}, %{stack: stack} = state) do
    # Only whitespace is inserted, non-whitespace is ignored
    case extract_whitespace(text) do
      "" ->
        {:ok, state}

      whitespace ->
        {:ok, %{state | stack: add_text_child(stack, whitespace)}}
    end
  end

  def process({:comment, text}, %{stack: stack} = state) do
    # Insert comment
    {:ok, %{state | stack: add_child(stack, {:comment, text})}}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:start_tag, "noframes", _attrs, _self_closing}, state) do
    # Process using "in head" rules
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after frameset" - we just stay in after_frameset
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: parse error, ignore
    {:ok, state}
  end

  # Extract only whitespace characters from text
  defp extract_whitespace(text) do
    text
    |> String.graphemes()
    |> Enum.filter(&(&1 in [" ", "\t", "\n", "\r", "\f"]))
    |> Enum.join()
  end

  # Add a child to the current element
  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  # Add text as child of the current element
  defp add_text_child(stack, text), do: add_child(stack, text)
end
