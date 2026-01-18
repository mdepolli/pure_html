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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      add_text_to_stack: 2,
      add_child_to_stack: 2,
      push_element: 3,
      pop_element: 1,
      current_tag: 1,
      extract_whitespace: 1
    ]

  @impl true
  # Whitespace: insert, non-whitespace: ignore
  def process({:character, text}, state) do
    whitespace = extract_whitespace(text)

    if whitespace == "" do
      {:ok, state}
    else
      {:ok, add_text_to_stack(state, whitespace)}
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
  def process({:start_tag, "html", _attrs, _}, state) do
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
  # Set original_mode so text mode returns here after noframes closes
  def process({:start_tag, "noframes", _attrs, _}, state) do
    {:reprocess, %{state | original_mode: :in_frameset, mode: :in_head}}
  end

  # Other start tags: parse error, ignore
  def process({:start_tag, _tag, _attrs, _}, state) do
    {:ok, state}
  end

  # End tag: frameset
  # Per spec: If current node is root html element, ignore. Otherwise pop frameset.
  # If not fragment parsing and current node is no longer frameset, switch to after frameset.
  def process({:end_tag, "frameset"}, state) do
    case current_tag(state) do
      "html" ->
        {:ok, state}

      "frameset" ->
        new_state = pop_element(state)

        new_mode =
          if current_tag(new_state) == "frameset", do: :in_frameset, else: :after_frameset

        {:ok, %{new_state | mode: new_mode}}

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
end
