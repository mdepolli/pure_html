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
  - <title>: generic RCDATA element parsing
  - <noscript> (scripting on), <noframes>, <style>: generic raw text element parsing
  - <noscript> (scripting off): insert, switch to "in head noscript"
  - <script>: insert, switch the tokenizer to script data, switch to "text"
  - <template>: insert, marker, frameset-ok "not ok", push "in template"
  - </head>: pop the current node, switch to "after head"
  - </body>, </html>, </br>: Act as "anything else"
  - </template>: pop through the template, clear formatting to the marker, pop the
    template insertion mode, reset the insertion mode
  - <head>: Parse error, ignore
  - Any other end tag: Parse error, ignore
  - Anything else: pop the current node, switch to "after head", reprocess

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
    # Generic RCDATA element parsing
    state
    |> switch_to_text_mode("title", attrs, :rcdata)
    |> ok()
  end

  # <noscript> with scripting enabled: treat as RAWTEXT (content is raw text)
  def process({:start_tag, "noscript", attrs, _self_closing}, %{scripting: true} = state) do
    state
    |> switch_to_text_mode("noscript", attrs, :rawtext)
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
    |> switch_to_text_mode(tag, attrs, :rawtext)
    |> ok()
  end

  def process({:start_tag, "script", attrs, _self_closing}, state) do
    # Insert script element, switch to text mode
    state
    |> switch_to_text_mode("script", attrs, :script_data)
    |> ok()
  end

  # Insert the template, a marker, frameset-ok "not ok", then push "in template"
  # onto the stack of template insertion modes and switch to it.
  def process({:start_tag, "template", attrs, _self_closing}, state) do
    state
    |> push_element("template", attrs)
    |> push_af_marker()
    |> set_frameset_not_ok()
    |> push_template_mode(:in_template)
    |> set_mode(:in_template)
    |> ok()
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

  # Per spec: with no template on the stack of open elements, parse error and
  # ignore. Otherwise generate implied end tags thoroughly, parse error unless
  # the current node is the template, pop through it, clear the active
  # formatting list to the last marker, pop the template insertion mode, and
  # reset the insertion mode appropriately.
  def process({:end_tag, "template"}, state) do
    if has_template_on_stack?(state) do
      state
      |> generate_implied_end_tags_thoroughly()
      |> parse_error_unless_current("template")
      |> close_html_template()
      |> clear_af_to_marker()
      |> pop_template_mode()
      |> reset_insertion_mode()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
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
  # "Pop the current node (which will be the head element) off the stack of
  # open elements. Switch the insertion mode to 'after head'."
  defp close_head(state) do
    state
    |> pop_element()
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

  defp parse_error_unless_current(state, tag) do
    state
    |> current_tag()
    |> mismatch_if_not(tag, state)
  end

  defp mismatch_if_not(tag, tag, state), do: state
  defp mismatch_if_not(_current, _tag, state), do: parse_error(state)

  defp switch_to_text_mode(state, tag, attrs, tokenizer_state) do
    state
    |> push_element(tag, attrs)
    |> enter_text_mode(tokenizer_state)
  end
end
