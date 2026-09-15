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
  - EOF: with no template on the stack, stop; otherwise parse error, pop through
    the template, clear formatting to the marker, pop the template insertion
    mode, reset the insertion mode, reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intemplate
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Modes.InHead

  @head_elements ~w(base basefont bgsound link meta noframes script style title)

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
    state
    |> parse_error()
    |> ok()
  end

  # Head elements: process using "in head" rules
  def process({:start_tag, tag, _, _} = token, state) when tag in @head_elements do
    InHead.process(token, state)
  end

  # Nested template: push element and push mode onto template_mode_stack
  def process({:start_tag, "template", attrs, _}, state) do
    state
    |> push_element("template", attrs)
    |> push_af_marker()
    |> push_template_mode(:in_template)
    |> ok()
  end

  # Table elements: per HTML5 spec, switch template mode and reprocess through dispatch
  # caption, colgroup, tbody, tfoot, thead: switch to "in table", reprocess
  @table_section_elements ~w(caption colgroup tbody tfoot thead)

  def process({:start_tag, tag, _, _}, state) when tag in @table_section_elements do
    state
    |> switch_template_mode(:in_table)
    |> reprocess()
  end

  # col: switch to "in column group", reprocess
  def process({:start_tag, "col", _, _}, state) do
    state
    |> switch_template_mode(:in_column_group)
    |> reprocess()
  end

  # tr: switch to "in table body", reprocess
  def process({:start_tag, "tr", _, _}, state) do
    state
    |> switch_template_mode(:in_table_body)
    |> reprocess()
  end

  # td, th: switch to "in row", reprocess
  def process({:start_tag, tag, _, _}, state) when tag in ["td", "th"] do
    state
    |> switch_template_mode(:in_row)
    |> reprocess()
  end

  # Any other start tag, html/head/body/noscript/table included: "Pop the
  # current template insertion mode off the stack of template insertion modes.
  # Push 'in body' onto the stack of template insertion modes. Switch the
  # insertion mode to 'in body', and reprocess the token." In body then
  # ignores html/head/body with a parse error while a template is open.
  def process({:start_tag, _, _, _}, state) do
    state
    |> switch_template_mode(:in_body)
    |> reprocess()
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"} = token, state) do
    InHead.process(token, state)
  end

  # Other end tags: parse error, ignore
  def process({:end_tag, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # EOF: per spec, if there is no template element on the stack of open elements,
  # stop parsing. Otherwise, this is a parse error.
  def process(:eof, state) do
    state
    |> find_ref("template")
    |> eof_in_template(state)
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp eof_in_template(nil, state), do: ok(state)

  defp eof_in_template(_ref, state) do
    state
    |> parse_error()
    |> pop_template_for_eof()
    |> clear_af_to_marker()
    |> pop_template_mode()
    |> reset_insertion_mode()
    |> reprocess()
  end

  defp pop_template_for_eof(state) do
    {_status, state} = pop_until_tag(state, "template")
    state
  end
end
