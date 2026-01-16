defmodule PureHTML.TreeBuilder.Modes.AfterHead do
  @moduledoc """
  HTML5 "after head" insertion mode.

  This mode is entered after the head element is closed.

  Per HTML5 spec:
  - Whitespace: Insert the character
  - Comment: Insert a comment
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - <body> start tag: Insert body element, switch to "in body"
  - <frameset> start tag: Insert frameset element, switch to "in frameset"
  - Head elements (<base>, <link>, <meta>, <script>, <style>, <template>, <title>):
    Parse error, reprocess using "in head" rules
  - </template>: Process using "in head" rules
  - </body>, </html>, </br>: Act as "anything else"
  - <head> start tag: Parse error, ignore
  - Any other end tag: Parse error, ignore
  - Anything else: Insert implied <body>, switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-after-head-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [
      push_element: 3,
      set_mode: 2,
      set_frameset_ok: 2
    ]

  alias PureHTML.TreeBuilder.Modes.InHead

  @head_elements ~w(base basefont bgsound link meta noframes script style template title)
  # HTML5 ASCII whitespace characters
  @html5_whitespace ~c[ \t\n\r\f]

  @impl true
  # Empty string - done
  def process({:character, ""}, state), do: {:ok, state}

  # Leading HTML5 whitespace - insert and continue with rest
  def process({:character, <<c, rest::binary>>}, state) when c in @html5_whitespace do
    state = add_text_to_top_of_stack(state, <<c>>)
    process({:character, rest}, state)
  end

  # Non-whitespace at start - insert implied body and reprocess
  def process({:character, text}, state) do
    {:reprocess_with, insert_implied_body(state), {:character, text}}
  end

  def process({:comment, text}, state) do
    # Insert comment as child of current element (html)
    # Use top of stack to handle case where current_parent_ref may be stale
    {:ok, add_child_to_top_of_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules - reprocess in :in_body mode
    # Body will be created by transition_to if needed
    {:reprocess, insert_implied_body(state)}
  end

  def process({:start_tag, "body", attrs, _self_closing}, state) do
    # Insert body element, switch to "in body", set frameset-ok to false
    state =
      state
      |> push_element("body", attrs)
      |> set_mode(:in_body)
      |> set_frameset_ok(false)

    {:ok, state}
  end

  def process({:start_tag, "frameset", attrs, _self_closing}, state) do
    # Insert frameset element, switch to "in frameset"
    state =
      state
      |> push_element("frameset", attrs)
      |> set_mode(:in_frameset)

    {:ok, state}
  end

  def process({:start_tag, tag, _attrs, _self_closing} = token, state)
      when tag in @head_elements do
    # Parse error, but process using "in head" rules
    # Per spec: push head onto stack, process in in_head, then remove head from stack
    state = push_head_onto_stack(state)
    {result, state} = InHead.process(token, state)
    state = remove_head_from_stack(state)

    # If we switched to text mode (style/script), set original_mode to after_head
    state =
      if state.mode == :text,
        do: %{state | original_mode: :after_head},
        else: state

    {result, state}
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:end_tag, "template"}, state) do
    # Process using "in head" rules
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, tag}, state) when tag in ~w(body html br) do
    # Act as "anything else" - insert implied body and reprocess
    {:reprocess, insert_implied_body(state)}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: insert implied <body>, switch to "in body", reprocess
    {:reprocess, insert_implied_body(state)}
  end

  # Insert an implied body element and switch to :in_body mode
  # First reset current_parent_ref to top of stack in case it's stale
  defp insert_implied_body(%{stack: [top_ref | _]} = state) do
    %{state | current_parent_ref: top_ref}
    |> push_element("body", %{})
    |> set_mode(:in_body)
  end

  defp insert_implied_body(state), do: set_mode(state, :in_body)

  # Push head element onto stack (for processing head elements in after_head)
  defp push_head_onto_stack(%{head_element: head_ref, stack: stack} = state)
       when not is_nil(head_ref) do
    %{state | stack: [head_ref | stack], current_parent_ref: head_ref}
  end

  defp push_head_onto_stack(state), do: state

  # Remove head element from stack (wherever it is)
  defp remove_head_from_stack(%{head_element: head_ref, stack: stack} = state)
       when not is_nil(head_ref) do
    new_stack = List.delete(stack, head_ref)

    new_parent_ref =
      case new_stack do
        [ref | _] -> ref
        [] -> nil
      end

    %{state | stack: new_stack, current_parent_ref: new_parent_ref}
  end

  defp remove_head_from_stack(state), do: state

  # Add child using top of stack as parent (ignores current_parent_ref)
  # This is needed when current_parent_ref may be stale (e.g., after returning from text mode)
  defp add_child_to_top_of_stack(%{stack: [parent_ref | _], elements: elements} = state, child) do
    new_elements =
      Map.update!(elements, parent_ref, fn parent ->
        %{parent | children: [child | parent.children]}
      end)

    %{state | elements: new_elements}
  end

  defp add_child_to_top_of_stack(%{stack: []} = state, _child), do: state

  # Add text using top of stack as parent, merging adjacent text
  defp add_text_to_top_of_stack(%{stack: [parent_ref | _], elements: elements} = state, text) do
    new_elements =
      Map.update!(elements, parent_ref, fn
        %{children: [prev_text | rest]} = parent when is_binary(prev_text) ->
          %{parent | children: [prev_text <> text | rest]}

        parent ->
          %{parent | children: [text | parent.children]}
      end)

    %{state | elements: new_elements}
  end

  defp add_text_to_top_of_stack(%{stack: []} = state, _text), do: state
end
