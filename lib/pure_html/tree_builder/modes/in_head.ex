defmodule PureHTML.TreeBuilder.Modes.InHead do
  @moduledoc """
  HTML5 "in head" insertion mode.

  This mode handles content inside the <head> element.

  Per HTML5 spec:
  - Whitespace: Insert the character
  - Comment: Insert a comment
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - <base>, <basefont>, <bgsound>, <link>, <meta>: Insert void element
  - <title>: Insert and switch to RCDATA (handled by tokenizer)
  - <noscript>, <noframes>, <style>: Insert and switch to RAWTEXT
  - <script>: Insert and switch to script data state
  - <template>: Insert, push mode, set up template
  - </head>: Pop head, switch to "after head"
  - </body>, </html>, </br>: Act as "anything else"
  - </template>: Process template end tag
  - <head>: Parse error, ignore
  - Any other end tag: Parse error, ignore
  - Anything else: Close head (implied </head>), switch to "after head", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inhead
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @void_head_elements ~w(base basefont bgsound link meta)
  @raw_text_elements ~w(noframes noscript style)

  @impl true
  def process({:character, text}, %{stack: stack} = state) do
    case String.trim(text) do
      "" ->
        # Whitespace: insert as child of head
        {:ok, %{state | stack: add_text_child(stack, text)}}

      _ ->
        # Non-whitespace: close head, switch to after_head, reprocess
        {:reprocess, close_head(state)}
    end
  end

  def process({:comment, text}, %{stack: stack} = state) do
    # Insert comment as child of head
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

  def process({:start_tag, tag, attrs, _self_closing}, %{stack: stack} = state)
      when tag in @void_head_elements do
    # Insert void element as child of head
    element = {tag, attrs, []}
    {:ok, %{state | stack: add_child(stack, element)}}
  end

  def process({:start_tag, "title", attrs, _self_closing}, %{stack: stack} = state) do
    # Insert title element, switch to text mode (RCDATA)
    element = %{ref: make_ref(), tag: "title", attrs: attrs, children: []}
    {:ok, %{state | stack: [element | stack], original_mode: :in_head, mode: :text}}
  end

  def process({:start_tag, tag, attrs, _self_closing}, %{stack: stack} = state)
      when tag in @raw_text_elements do
    # Insert element, switch to text mode (RAWTEXT)
    element = %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
    {:ok, %{state | stack: [element | stack], original_mode: :in_head, mode: :text}}
  end

  def process({:start_tag, "script", attrs, _self_closing}, %{stack: stack} = state) do
    # Insert script element, switch to text mode
    element = %{ref: make_ref(), tag: "script", attrs: attrs, children: []}
    {:ok, %{state | stack: [element | stack], original_mode: :in_head, mode: :text}}
  end

  def process({:start_tag, "template", _attrs, _self_closing}, state) do
    # Template needs special handling with mode stack - delegate to main process/2
    # Set mode to :in_body (not in @mode_modules) so dispatch falls through
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:end_tag, "head"}, state) do
    # Pop head element, switch to after_head
    {:ok, close_head(state)}
  end

  def process({:end_tag, tag}, state) when tag in ~w(body html br) do
    # Act as "anything else" - close head and reprocess
    {:reprocess, close_head(state)}
  end

  def process({:end_tag, "template"}, state) do
    # Template end tag needs special handling - delegate to main process/2
    # Set mode to :in_body (not in @mode_modules) so dispatch falls through
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: close head, switch to after_head, reprocess
    {:reprocess, close_head(state)}
  end

  # Close head element and switch to after_head mode
  defp close_head(%{stack: [%{tag: "head"} = head | rest]} = state) do
    %{state | stack: add_child(rest, head), mode: :after_head}
  end

  defp close_head(state), do: %{state | mode: :after_head}

  # Add a child to the current element
  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  # Add text as child of the current element
  defp add_text_child(stack, text), do: add_child(stack, text)
end
