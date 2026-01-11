defmodule PureHTML.TreeBuilder.Modes.InFrameset do
  @moduledoc """
  HTML5 "in frameset" insertion mode.

  This mode handles content inside a <frameset> element.

  Per HTML5 spec:
  - Whitespace characters: insert
  - Non-whitespace: parse error, ignore
  - Comments: insert
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules (merge attrs)
    - frameset: insert element
    - frame: insert void element
    - noframes: process using "in head" rules
  - End tag frameset: pop frameset, switch to "after frameset"
  - Anything else: parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inframeset
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  # Whitespace: insert
  def process({:character, text}, state) do
    case extract_whitespace(text) do
      "" -> {:ok, state}
      whitespace -> {:ok, add_text_to_stack(state, whitespace)}
    end
  end

  # Comments: insert
  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    {:ok, state}
  end

  # Start tag: html - process using in_body rules (merge attrs)
  def process({:start_tag, "html", _attrs, _} = token, state) do
    {:reprocess, %{state | mode: :in_body}}
  end

  # Start tag: frameset
  def process({:start_tag, "frameset", attrs, _}, state) do
    {:ok, push_element(state, "frameset", attrs)}
  end

  # Start tag: frame (void element)
  def process({:start_tag, "frame", attrs, _}, state) do
    {:ok, add_child_to_stack(state, {"frame", attrs, []})}
  end

  # Start tag: noframes - process using in_head rules
  def process({:start_tag, "noframes", _attrs, _} = token, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Other start tags: parse error, ignore
  def process({:start_tag, _tag, _attrs, _}, state) do
    {:ok, state}
  end

  # End tag: frameset
  # Per spec: If current node is root html element, ignore. Otherwise pop frameset.
  # If not fragment parsing and current node is no longer frameset, switch to after frameset.
  def process({:end_tag, "frameset"}, %{stack: stack} = state) do
    case stack do
      # Only html on stack - current node is html, ignore
      [%{tag: "html"}] ->
        {:ok, state}

      # Frameset on stack - pop it and check what remains
      [%{tag: "frameset"} = frameset | rest] ->
        new_stack = add_child(rest, frameset)

        # Switch to after_frameset if current node is no longer a frameset
        case new_stack do
          [%{tag: "frameset"} | _] ->
            # Still in a nested frameset, stay in in_frameset mode
            {:ok, %{state | stack: new_stack}}

          _ ->
            # Current node is not frameset (likely html), switch to after_frameset
            {:ok, %{state | stack: new_stack, mode: :after_frameset}}
        end

      _ ->
        {:ok, state}
    end
  end

  # Other end tags: parse error, ignore
  def process({:end_tag, _tag}, state) do
    {:ok, state}
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp extract_whitespace(text) do
    text
    |> String.graphemes()
    |> Enum.filter(&(&1 in [" ", "\t", "\n", "\r", "\f"]))
    |> Enum.join()
  end

  defp add_text_to_stack(%{stack: stack} = state, text) do
    %{state | stack: add_text_child(stack, text)}
  end

  defp add_text_child([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text_child([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text_child([], _text), do: []

  defp add_child_to_stack(%{stack: stack} = state, child) do
    %{state | stack: add_child(stack, child)}
  end

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  defp push_element(%{stack: stack} = state, tag, attrs) do
    element = %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
    %{state | stack: [element | stack]}
  end
end
