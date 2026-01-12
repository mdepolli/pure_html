defmodule PureHTML.TreeBuilder.Modes.InTemplate do
  @moduledoc """
  HTML5 "in template" insertion mode.

  This mode handles content inside a <template> element.

  Per HTML5 spec:
  - Character tokens: process using "in body" rules
  - Comments: process using "in body" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - base, basefont, bgsound, link, meta, noframes, script, style, template, title:
      Process using "in head" rules
    - caption, colgroup, tbody, tfoot, thead: switch to "in table", reprocess
    - col: switch to "in column group", reprocess
    - tr: switch to "in table body", reprocess
    - td, th: switch to "in row", reprocess
    - Anything else: switch to "in body", reprocess
  - End tags:
    - template: process using "in head" rules
    - Anything else: parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intemplate
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  alias PureHTML.TreeBuilder.Modes.InBody

  import PureHTML.TreeBuilder.Helpers,
    only: [add_child_to_stack: 2, push_element: 3, push_af_marker: 1]

  # Void head elements that can just be added directly
  @void_head_elements ~w(base basefont bgsound link meta)

  # Raw text elements that need text mode
  @raw_text_elements ~w(noframes noscript style)

  # Title should be delegated to in_head
  @delegate_head_elements ~w(title)

  @impl true
  # Character tokens: process using in_body rules
  def process({:character, _} = token, state) do
    InBody.process(token, state)
  end

  # Comments: process using in_body rules
  def process({:comment, _} = token, state) do
    InBody.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Void head elements: add directly to stack
  def process({:start_tag, tag, attrs, _}, state)
      when tag in @void_head_elements do
    {:ok, add_child_to_stack(state, {tag, attrs, []})}
  end

  # Script: push element, switch to text mode with original_mode: :in_template
  def process({:start_tag, "script", attrs, _}, state) do
    state =
      state
      |> push_element("script", attrs)
      |> Map.put(:original_mode, :in_template)
      |> Map.put(:mode, :text)

    {:ok, state}
  end

  # Raw text elements: push element, switch to text mode
  def process({:start_tag, tag, attrs, _}, state)
      when tag in @raw_text_elements do
    state =
      state
      |> push_element(tag, attrs)
      |> Map.put(:original_mode, :in_template)
      |> Map.put(:mode, :text)

    {:ok, state}
  end

  # Nested template: push element and push mode onto template_mode_stack
  def process({:start_tag, "template", attrs, _}, %{template_mode_stack: tms} = state) do
    new_tms = [:in_template | tms]

    state =
      state
      |> push_element("template", attrs)
      |> push_af_marker()
      |> Map.put(:template_mode_stack, new_tms)

    {:ok, state}
  end

  # Title: delegate to in_head
  def process({:start_tag, tag, _, _}, state) when tag in @delegate_head_elements do
    {:reprocess, %{state | mode: :in_head}}
  end

  # html/head/body start tags: parse error, ignore when in template
  # Per spec: "If there is a template element on the stack of open elements, then ignore the token"
  def process({:start_tag, tag, _, _}, state) when tag in ["html", "head", "body"] do
    {:ok, state}
  end

  # Table elements: delegate to InBody which has special handlers for :in_template mode
  # These handlers check mode: :in_template and do proper template_mode_stack switching
  @table_elements ~w(caption colgroup tbody tfoot thead col tr td th table)

  def process({:start_tag, tag, _, _} = token, state) when tag in @table_elements do
    InBody.process(token, state)
  end

  # Other start tags: switch to in_body and reprocess
  # Per spec: "Pop the current template insertion mode off the stack of template insertion modes.
  # Push 'in body' onto the stack of template insertion modes.
  # Switch the insertion mode to 'in body', and reprocess the token."
  def process({:start_tag, _, _, _}, state) do
    {:reprocess, switch_template_mode(state, :in_body)}
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Other end tags: parse error, ignore
  def process({:end_tag, _}, state) do
    {:ok, state}
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp switch_template_mode(%{template_mode_stack: tms} = state, new_mode) do
    new_tms =
      case tms do
        [_ | rest] -> [new_mode | rest]
        [] -> [new_mode]
      end

    %{state | mode: new_mode, template_mode_stack: new_tms}
  end
end
