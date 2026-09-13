defmodule PureHTML.TreeBuilder.Modes.InTable do
  @moduledoc """
  HTML5 "in table" insertion mode.

  This mode handles content inside a <table> element.

  Per HTML5 spec:
  - Character tokens: foster parent via in_body (except whitespace in table context)
  - Comments: insert comment
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption: clear to table context, insert marker, insert caption, switch to in_caption
    - colgroup: clear to table context, insert colgroup, switch to in_column_group
    - col: ensure colgroup, insert col
    - tbody/thead/tfoot: clear to table context, insert element, switch to in_table_body
    - td/th/tr: ensure tbody, reprocess
    - table: parse error, close table, reprocess
    - style/script/template: process using in_head rules
    - input type=hidden: insert directly (no foster parenting)
    - form: special handling
    - Anything else: foster parent via in_body
  - End tags:
    - table: close table
    - body/caption/col/colgroup/html/tbody/td/tfoot/th/thead/tr: parse error, ignore
    - template: process using in_head rules
    - Anything else: foster parent via in_body

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intable
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Modes.InHead

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody template tfoot thead tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  @impl true
  def process(token, state) do
    do_process(token, state)
  end

  # Character tokens in table context elements: switch to in_table_text mode
  defp do_process({:character, text}, %{stack: [ref | _], elements: elements} = state) do
    do_process_character(elements[ref], text, state)
  end

  defp do_process({:character, text}, state) do
    InBody.process({:character, text}, state)
  end

  # Comments: insert
  defp do_process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  defp do_process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: caption
  defp do_process({:start_tag, "caption", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_af_marker()
    |> push_element("caption", attrs)
    |> set_mode(:in_caption)
    |> ok()
  end

  # Start tag: colgroup
  defp do_process({:start_tag, "colgroup", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", attrs)
    |> set_mode(:in_column_group)
    |> ok()
  end

  # Start tag: col - per spec, clear to table context, insert a colgroup, switch to
  # "in column group", and reprocess
  defp do_process({:start_tag, "col", _, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", [])
    |> set_mode(:in_column_group)
    |> reprocess()
  end

  # Start tags: tbody, thead, tfoot
  defp do_process({:start_tag, tag, attrs, _}, state) when tag in @table_sections do
    state
    |> clear_to_table_context()
    |> push_element(tag, attrs)
    |> set_mode(:in_table_body)
    |> ok()
  end

  # Start tags: td, th, tr - ensure tbody, reprocess
  defp do_process({:start_tag, tag, _, _}, state) when tag in ~w(td th tr) do
    state
    |> clear_to_table_context()
    |> ensure_tbody()
    |> set_mode(:in_table_body)
    |> reprocess()
  end

  # Start tag: nested table - parse error, close current table, reprocess
  defp do_process({:start_tag, "table", _, _}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> parse_error()
      |> close_table()
      |> reset_insertion_mode()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Start tags: style, script - process using in_head rules
  defp do_process({:start_tag, tag, _, _} = token, state) when tag in ~w(style script) do
    InHead.process(token, state)
  end

  # Start tag: template - process using in_head rules
  defp do_process({:start_tag, "template", _, _} = token, state) do
    InHead.process(token, state)
  end

  # Start tag: input - check for type=hidden
  # Per spec: "Parse error." for both hidden and non-hidden cases in table.
  defp do_process({:start_tag, "input", attrs, _}, state) do
    attrs
    |> get_attr("type", "")
    |> String.downcase()
    |> insert_table_input(attrs, state)
  end

  # Start tag: form - Per spec: "Parse error."
  defp do_process({:start_tag, "form", attrs, _}, %{form_element: nil} = state) do
    state
    |> parse_error()
    |> insert_table_form(attrs)
  end

  # Per spec: "Parse error." Form element pointer already set, ignore.
  defp do_process({:start_tag, "form", _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Frameset/frame: per spec "Parse error." then in-body rules, which parse
  # error again and ignore the token (nothing is inserted, so no foster parenting).
  defp do_process({:start_tag, tag, _, _} = token, state)
       when tag in ["frameset", "frame"] do
    state
    |> parse_error()
    |> process_in_body(token)
  end

  # Other start tags: per spec "Parse error. Enable foster parenting, process
  # the token using the rules for the 'in body' insertion mode."
  defp do_process({:start_tag, _, _, _} = token, state) do
    state
    |> parse_error()
    |> enable_foster_parenting()
    |> process_in_body(token)
  end

  # End tag: table
  # Per spec: "If the stack of open elements does not have a table element in table scope,
  # this is a parse error; ignore the token."
  defp do_process({:end_tag, "table"}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> close_table()
      |> reset_insertion_mode()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: template - process using in_head rules
  defp do_process({:end_tag, "template"} = token, state) do
    InHead.process(token, state)
  end

  # Ignored end tags: parse error, ignore
  defp do_process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # </br> special case: per spec "Parse error." Foster parent a <br> element.
  defp do_process({:end_tag, "br"}, state) do
    state
    |> parse_error()
    |> foster_insert({:element, {"br", [], []}})
    |> ok()
  end

  # Other end tags: per spec "Parse error. Enable foster parenting, process the
  # token using the rules for the 'in body' insertion mode, and then disable
  # foster parenting."
  defp do_process({:end_tag, _} = token, state) do
    state
    |> parse_error()
    |> enable_foster_parenting()
    |> process_in_body(token)
  end

  # EOF: process using in_body rules
  defp do_process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers (in_table specific - general helpers imported from TreeBuilder.Helpers)
  # --------------------------------------------------------------------------

  # Per spec: insert directly, no foster parenting.
  defp insert_table_input("hidden", attrs, state) do
    state
    |> parse_error()
    |> add_child_to_stack({"input", attrs, []})
    |> ok()
  end

  defp insert_table_input(_type, attrs, state) do
    state
    |> parse_error()
    |> foster_insert({:element, {"input", attrs, []}})
    |> ok()
  end

  # Switch to in_table_text mode to collect character tokens
  defp do_process_character(%{tag: tag}, text, state) when tag in @table_context do
    state
    |> start_table_text(text)
    |> ok()
  end

  # Per spec: "Parse error." Character tokens not in table context: delegate to in_body
  defp do_process_character(_, text, state) do
    state
    |> parse_error(String.length(text))
    |> process_in_body({:character, text})
  end

  # "Let the original insertion mode be the current insertion mode. Switch the
  # insertion mode to in table text."
  defp start_table_text(%{mode: mode} = state, text) do
    %{state | mode: :in_table_text, original_mode: mode, pending_table_text: text}
  end

  # Clear stack to table context (table, template, html)
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_context(%{stack: stack, elements: elements} = state) do
    {new_stack, _parent_ref} = do_clear_to_table_context(stack, elements)
    %{state | stack: new_stack}
  end

  defp do_clear_to_table_context([], _elements), do: {[], nil}

  defp do_clear_to_table_context([ref | _rest] = stack, elements) do
    tag = elements[ref].tag

    if tag in @table_boundaries do
      # Found boundary, parent is the ref itself since we stay on it
      {stack, ref}
    else
      do_clear_to_table_context(tl(stack), elements)
    end
  end

  defp ensure_tbody(%{stack: [ref | _], elements: elements, context_element: ctx} = state) do
    case elements[ref].tag do
      tag when tag in @table_sections ->
        state

      # Fragment mode: at html root with table body context, skip tbody creation.
      # The context element is already a tbody/thead/tfoot so content belongs there.
      "html" ->
        case ctx do
          {_, ctx_tag} when ctx_tag in ["tbody", "thead", "tfoot"] -> state
          _ -> push_element(state, "tbody", [])
        end

      tag when tag in ["table", "template"] ->
        push_element(state, "tbody", [])

      _ ->
        state
    end
  end

  defp ensure_tbody(state), do: state

  defp insert_table_form(state, attrs) do
    state
    |> find_ref("template")
    |> insert_table_form(attrs, state)
  end

  defp insert_table_form(nil, attrs, state) do
    state
    |> push_element("form", attrs)
    |> point_form_element()
    |> pop_element()
    |> ok()
  end

  defp insert_table_form(_ref, _attrs, state), do: ok(state)

  defp point_form_element(%{stack: [form_ref | _]} = state) do
    %{state | form_element: form_ref}
  end

  # "Pop elements from this stack until a table element has been popped from
  # the stack."
  defp close_table(state), do: pop_through(state, "table")
end
