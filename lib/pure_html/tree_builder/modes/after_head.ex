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
  - Head elements (<base>, <basefont>, <bgsound>, <link>, <meta>, <noframes>,
    <script>, <style>, <template>, <title>): parse error; push the head element,
    process using "in head" rules, remove the head element from the stack
  - </template>: Process using "in head" rules
  - </body>, </html>, </br>: Act as "anything else"
  - <head> start tag: Parse error, ignore
  - Any other end tag: Parse error, ignore
  - Anything else (EOF included): insert a body element, frameset-ok "ok",
    switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-after-head-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InHead

  @head_elements ~w(base basefont bgsound link meta noframes script style template title)
  # HTML5 ASCII whitespace characters
  @html5_whitespace ~c[ \t\n\r\f]

  @impl true
  # Empty string - done
  def process({:character, ""}, state), do: ok(state)

  # Leading HTML5 whitespace - insert and continue with rest
  def process({:character, <<c, rest::binary>>}, state) when c in @html5_whitespace do
    process({:character, rest}, add_text_to_top_of_stack(state, <<c>>))
  end

  # Non-whitespace at start - insert implied body and reprocess
  def process({:character, text}, state) do
    state
    |> insert_implied_body()
    |> reprocess_with({:character, text})
  end

  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  # "Process the token using the rules for the in body insertion mode": a parse
  # error and an attribute merge onto the html element, with no mode change.
  def process({:start_tag, "html", _attrs, _self_closing} = token, state) do
    process_in_body(state, token)
  end

  def process({:start_tag, "body", attrs, _self_closing}, state) do
    # Insert body element, switch to "in body", set frameset-ok to false
    state
    |> push_element("body", attrs)
    |> set_mode(:in_body)
    |> set_frameset_ok(false)
    |> ok()
  end

  def process({:start_tag, "frameset", attrs, _self_closing}, state) do
    # Insert frameset element, switch to "in frameset"
    state
    |> push_element("frameset", attrs)
    |> set_mode(:in_frameset)
    |> ok()
  end

  def process({:start_tag, tag, _attrs, _self_closing} = token, state)
      when tag in @head_elements do
    # Parse error, but process using "in head" rules
    # Per spec: push head onto stack, process in in_head, then remove head from stack
    state
    |> parse_error()
    |> push_head_onto_stack()
    |> process_in_head(token)
    |> remove_head_from_stack()
    |> ok()
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  # Process using "in head" rules
  def process({:end_tag, "template"} = token, state) do
    InHead.process(token, state)
  end

  def process({:end_tag, tag}, state) when tag in ~w(body html br) do
    # Act as "anything else" - insert implied body and reprocess
    state
    |> insert_implied_body()
    |> reprocess()
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    state
    |> parse_error()
    |> ok()
  end

  def process(_token, state) do
    # Anything else: insert implied <body>, switch to "in body", reprocess
    state
    |> insert_implied_body()
    |> reprocess()
  end

  # Anything else: insert a body element, frameset-ok "ok", switch to in body
  defp insert_implied_body(state) do
    state
    |> push_element("body", [])
    |> set_frameset_ok(true)
    |> set_mode(:in_body)
  end

  # Push head element onto stack (for processing head elements in after_head)
  defp push_head_onto_stack(%{head_element: head_ref, stack: stack} = state)
       when not is_nil(head_ref) do
    %{state | stack: [head_ref | stack]}
  end

  defp push_head_onto_stack(state), do: state

  # Remove head element from stack (wherever it is)
  defp remove_head_from_stack(%{head_element: head_ref, stack: stack} = state)
       when not is_nil(head_ref) do
    %{state | stack: List.delete(stack, head_ref)}
  end

  defp remove_head_from_stack(state), do: state

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
