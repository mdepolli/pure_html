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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      add_child_to_stack: 2,
      push_element: 3,
      push_af_marker: 1,
      switch_template_mode: 2,
      find_ref: 2
    ]

  alias PureHTML.TreeBuilder.Modes.InBody

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
    {:ok, push_and_enter_text_mode(state, "script", attrs)}
  end

  # Raw text elements: push element, switch to text mode
  def process({:start_tag, tag, attrs, _}, state)
      when tag in @raw_text_elements do
    {:ok, push_and_enter_text_mode(state, tag, attrs)}
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

  # Table elements: per HTML5 spec, switch template mode and reprocess through dispatch
  # caption, colgroup, tbody, tfoot, thead: switch to "in table", reprocess
  @table_section_elements ~w(caption colgroup tbody tfoot thead)

  def process({:start_tag, tag, _, _}, state) when tag in @table_section_elements do
    {:reprocess, switch_template_mode(state, :in_table)}
  end

  # col: switch to "in column group", reprocess
  def process({:start_tag, "col", _, _}, state) do
    {:reprocess, switch_template_mode(state, :in_column_group)}
  end

  # tr: if template_mode_stack has :in_table, switch to :in_table so tr triggers
  # implicit tbody creation.
  def process({:start_tag, "tr", _, _}, %{template_mode_stack: [:in_table | _]} = state) do
    {:reprocess, switch_template_mode(state, :in_table)}
  end

  # tr: check if template already has non-table content
  # If so, tr is "bogus" and should be ignored (test #77 scenario)
  def process({:start_tag, "tr", _, _}, state) do
    if template_has_non_table_content?(state) do
      {:ok, state}
    else
      {:reprocess, switch_template_mode(state, :in_table_body)}
    end
  end

  # td, th: need to create implicit tr if we're in table body context
  # Per spec says "in row", but if template_mode_stack has :in_table_body,
  # we need in_table_body to create the implicit tr first
  def process({:start_tag, tag, _, _}, %{template_mode_stack: [:in_table_body | _]} = state)
      when tag in ["td", "th"] do
    {:reprocess, switch_template_mode(state, :in_table_body)}
  end

  def process({:start_tag, tag, _, _}, state) when tag in ["td", "th"] do
    {:reprocess, switch_template_mode(state, :in_row)}
  end

  # Other start tags (including table): switch to in_body and reprocess
  # Per HTML5 spec, only caption/colgroup/tbody/tfoot/thead switch to :in_table
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

  defp push_and_enter_text_mode(state, tag, attrs) do
    state
    |> push_element(tag, attrs)
    |> Map.put(:original_mode, :in_template)
    |> Map.put(:mode, :text)
  end

  # Table-related elements that are valid as early template content
  @table_elements ~w(tr td th tbody thead tfoot caption colgroup col table)

  # Check if the current template element already has non-table content
  # (div, span, text, etc.) that would make tr "bogus"
  defp template_has_non_table_content?(%{elements: elements} = state) do
    case find_ref(state, "template") do
      nil -> false
      ref -> has_non_table_children?(elements[ref].children, elements)
    end
  end

  defp has_non_table_children?([], _elements), do: false

  # Text: non-whitespace counts as non-table content
  defp has_non_table_children?([{:text, text} | rest], elements) do
    if String.trim(text) != "", do: true, else: has_non_table_children?(rest, elements)
  end

  # Comments don't count
  defp has_non_table_children?([{:comment, _} | rest], elements) do
    has_non_table_children?(rest, elements)
  end

  # Element reference: check tag
  defp has_non_table_children?([ref | rest], elements) when is_reference(ref) do
    check_element_for_non_table_content(elements[ref], rest, elements)
  end

  # Skip unknown children
  defp has_non_table_children?([_ | rest], elements) do
    has_non_table_children?(rest, elements)
  end

  defp check_element_for_non_table_content(%{tag: tag}, rest, elements)
       when tag in @table_elements do
    has_non_table_children?(rest, elements)
  end

  defp check_element_for_non_table_content(%{tag: "template"}, rest, elements) do
    has_non_table_children?(rest, elements)
  end

  defp check_element_for_non_table_content(_, _rest, _elements), do: true
end
