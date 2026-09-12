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

  import PureHTML.TreeBuilder.Helpers

  @void_head_elements ~w(base basefont bgsound link meta)
  @raw_text_elements ~w(noframes style)

  @impl true
  def process({:character, text}, state) do
    text
    |> split_whitespace()
    |> handle_characters(text, state)
  end

  def process({:comment, text}, state) do
    # Insert comment as child of head
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

  def process({:start_tag, "html", attrs, _self_closing}, state) do
    # Process using "in body" rules - parse error, then merge attrs to html element
    state
    |> parse_error()
    |> merge_html_attrs(attrs)
    |> ok()
  end

  def process({:start_tag, tag, attrs, _self_closing}, state)
      when tag in @void_head_elements do
    # Insert void element as child of head
    state
    |> add_child_to_stack({tag, attrs, []})
    |> ok()
  end

  def process({:start_tag, "title", attrs, _self_closing}, state) do
    # Insert title element, switch to text mode (RCDATA)
    state
    |> push_element("title", attrs)
    |> Map.put(:original_mode, :in_head)
    |> set_mode(:text)
    |> ok()
  end

  # <noscript> with scripting enabled: treat as RAWTEXT (content is raw text)
  def process({:start_tag, "noscript", attrs, _self_closing}, %{scripting: true} = state) do
    state
    |> switch_to_text_mode("noscript", attrs)
    |> ok()
  end

  # <noscript> with scripting disabled: push element, enter in_head_noscript mode
  def process({:start_tag, "noscript", attrs, _self_closing}, state) do
    state
    |> push_element("noscript", attrs)
    |> set_mode(:in_head_noscript)
    |> ok()
  end

  def process({:start_tag, tag, attrs, _self_closing}, state)
      when tag in @raw_text_elements do
    # Insert element, switch to text mode (RAWTEXT)
    state
    |> switch_to_text_mode(tag, attrs)
    |> ok()
  end

  def process({:start_tag, "script", attrs, _self_closing}, state) do
    # Insert script element, switch to text mode
    state
    |> switch_to_text_mode("script", attrs)
    |> ok()
  end

  def process({:start_tag, "template", _attrs, _self_closing}, state) do
    # Template needs special handling with mode stack - delegate to main process/2
    # Set mode to :in_body (not in @mode_modules) so dispatch falls through
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Parse error, ignore
    state
    |> parse_error()
    |> ok()
  end

  def process({:end_tag, "head"}, state) do
    # Pop head element, switch to after_head
    state
    |> close_head()
    |> ok()
  end

  def process({:end_tag, tag}, state) when tag in ~w(body html br) do
    # Act as "anything else" - close head and reprocess
    state
    |> close_head()
    |> reprocess()
  end

  def process({:end_tag, "template"}, state) do
    # Template end tag needs special handling - delegate to main process/2
    # Set mode to :in_body (not in @mode_modules) so dispatch falls through
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    state
    |> parse_error()
    |> ok()
  end

  def process(_token, state) do
    # Anything else: close head, switch to after_head, reprocess
    state
    |> close_head()
    |> reprocess()
  end

  # Close head element and switch to after_head mode
  defp close_head(state) do
    state
    |> pop_head_if_current()
    |> set_mode(:after_head)
  end

  defp handle_characters({"", _non_ws}, _text, state) do
    state
    |> close_head()
    |> reprocess()
  end

  defp handle_characters({text, ""}, text, state) do
    state
    |> add_text_to_stack(text)
    |> ok()
  end

  defp handle_characters({ws, rest}, _text, state) do
    state
    |> add_text_to_stack(ws)
    |> close_head()
    |> reprocess_with({:character, rest})
  end

  defp pop_head_if_current(state) do
    state
    |> current_tag()
    |> pop_if_tag("head", state)
  end

  defp pop_if_tag(tag, tag, state), do: pop_element(state)
  defp pop_if_tag(_current, _expected, state), do: state

  # Switch to text mode, preserving original_mode if already set
  defp switch_to_text_mode(state, tag, attrs) do
    state
    |> push_element(tag, attrs)
    |> enter_text_mode()
  end

  defp enter_text_mode(%{original_mode: nil} = state) do
    %{state | original_mode: :in_head, mode: :text}
  end

  defp enter_text_mode(state), do: set_mode(state, :text)
end
