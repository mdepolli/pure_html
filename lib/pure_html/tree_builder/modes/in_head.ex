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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      add_child_to_stack: 2,
      add_text_to_stack: 2,
      push_element: 3,
      pop_element: 1,
      current_tag: 1,
      split_whitespace: 1,
      merge_html_attrs: 2
    ]

  @void_head_elements ~w(base basefont bgsound link meta)
  @raw_text_elements ~w(noframes noscript style)

  @impl true
  def process({:character, text}, state) do
    case split_whitespace(text) do
      {"", _non_ws} ->
        # Starts with non-whitespace: close head, switch to after_head, reprocess
        {:reprocess, close_head(state)}

      {^text, ""} ->
        # All whitespace: insert as child of head
        {:ok, add_text_to_stack(state, text)}

      {ws, non_ws} ->
        # Mixed: insert whitespace in head, then close head and reprocess rest
        state = add_text_to_stack(state, ws)
        {:reprocess_with, close_head(state), {:character, non_ws}}
    end
  end

  def process({:comment, text}, state) do
    # Insert comment as child of head
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", attrs, _self_closing}, state) do
    # Process using "in body" rules - merge attrs to html element, stay in in_head
    {:ok, merge_html_attrs(state, attrs)}
  end

  def process({:start_tag, tag, attrs, _self_closing}, state)
      when tag in @void_head_elements do
    # Insert void element as child of head
    {:ok, add_child_to_stack(state, {tag, attrs, []})}
  end

  def process({:start_tag, "title", attrs, _self_closing}, state) do
    # Insert title element, switch to text mode (RCDATA)
    state =
      state
      |> push_element("title", attrs)
      |> Map.put(:original_mode, :in_head)
      |> Map.put(:mode, :text)

    {:ok, state}
  end

  def process({:start_tag, tag, attrs, _self_closing}, state)
      when tag in @raw_text_elements do
    # Insert element, switch to text mode (RAWTEXT)
    # Preserve original_mode if already set (e.g., from frameset context)
    state =
      state
      |> push_element(tag, attrs)
      |> then(fn s ->
        if s.original_mode, do: s, else: %{s | original_mode: :in_head}
      end)
      |> Map.put(:mode, :text)

    {:ok, state}
  end

  def process({:start_tag, "script", attrs, _self_closing}, state) do
    # Insert script element, switch to text mode
    # Preserve original_mode if already set (e.g., from table context)
    state =
      state
      |> push_element("script", attrs)
      |> then(fn s ->
        if s.original_mode, do: s, else: %{s | original_mode: :in_head}
      end)
      |> Map.put(:mode, :text)

    {:ok, state}
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
  defp close_head(state) do
    state
    |> pop_head_if_current()
    |> Map.put(:mode, :after_head)
  end

  defp pop_head_if_current(state) do
    if current_tag(state) == "head", do: pop_element(state), else: state
  end
end
