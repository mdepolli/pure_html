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

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody template tfoot thead tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)
  @formatting_element_tags ~w(a b big code em font i nobr s small strike strong tt u)

  @impl true
  def process(token, state) do
    process_in_table(token, state)
  end

  # Character tokens in table context elements: switch to in_table_text mode
  defp process_in_table({:character, text}, %{stack: [ref | _], elements: elements} = state) do
    do_process_character(elements[ref], text, state)
  end

  defp process_in_table({:character, text}, state) do
    InBody.process({:character, text}, state)
  end

  # Comments: insert
  defp process_in_table({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  defp process_in_table({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: caption
  defp process_in_table({:start_tag, "caption", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_af_marker()
    |> push_element("caption", attrs)
    |> set_mode(:in_caption)
    |> ok()
  end

  # Start tag: colgroup
  defp process_in_table({:start_tag, "colgroup", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", attrs)
    |> set_mode(:in_column_group)
    |> ok()
  end

  # Start tag: col - per spec, clear to table context, insert a colgroup, switch to
  # "in column group", and reprocess
  defp process_in_table({:start_tag, "col", _, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", [])
    |> set_mode(:in_column_group)
    |> reprocess()
  end

  # Start tags: tbody, thead, tfoot
  defp process_in_table({:start_tag, tag, attrs, _}, state) when tag in @table_sections do
    state
    |> clear_to_table_context()
    |> push_element(tag, attrs)
    |> set_mode(:in_table_body)
    |> ok()
  end

  # Start tags: td, th, tr - ensure tbody, reprocess
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ~w(td th tr) do
    state
    |> clear_to_table_context()
    |> ensure_tbody()
    |> set_mode(:in_table_body)
    |> reprocess()
  end

  # Start tag: nested table - parse error, close current table, reprocess
  defp process_in_table({:start_tag, "table", _, _}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> parse_error()
      |> close_table()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Start tags: style, script - process using in_head rules
  # Set original_mode first so we return to table context after text mode
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ~w(style script) do
    state
    |> Map.put(:original_mode, state.mode)
    |> set_mode(:in_head)
    |> reprocess()
  end

  # Start tag: template - process using in_head rules (no original_mode needed)
  defp process_in_table({:start_tag, "template", _, _}, state) do
    state
    |> set_mode(:in_head)
    |> reprocess()
  end

  # Start tag: input - check for type=hidden
  # Per spec: "Parse error." for both hidden and non-hidden cases in table.
  defp process_in_table({:start_tag, "input", attrs, _}, state) do
    attrs
    |> get_attr("type", "")
    |> String.downcase()
    |> insert_table_input(attrs, state)
  end

  # Start tag: form - Per spec: "Parse error."
  defp process_in_table({:start_tag, "form", attrs, _}, %{form_element: nil} = state) do
    state
    |> parse_error()
    |> insert_table_form(attrs)
  end

  # Per spec: "Parse error." Form element pointer already set, ignore.
  defp process_in_table({:start_tag, "form", _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Frameset/frame: per spec "Parse error." then in-body rules, which parse
  # error again and ignore the token (nothing is inserted, so no foster parenting).
  defp process_in_table({:start_tag, tag, _, _} = token, state)
       when tag in ["frameset", "frame"] do
    state
    |> parse_error()
    |> process_in_body(token)
  end

  # Other start tags: per spec "Parse error. Enable foster parenting, process
  # the token using the rules for the 'in body' insertion mode."
  defp process_in_table({:start_tag, _, _, _} = token, state) do
    state
    |> parse_error()
    |> enable_foster_parenting()
    |> process_in_body(token)
  end

  # End tag: table
  # Per spec: "If the stack of open elements does not have a table element in table scope,
  # this is a parse error; ignore the token."
  defp process_in_table({:end_tag, "table"}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> close_table()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: template - process using in_head rules
  defp process_in_table({:end_tag, "template"}, state) do
    state
    |> set_mode(:in_head)
    |> reprocess()
  end

  # Ignored end tags: parse error, ignore
  defp process_in_table({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # </br> special case: per spec "Parse error." Foster parent a <br> element.
  defp process_in_table({:end_tag, "br"}, state) do
    state
    |> parse_error()
    |> foster_insert({:element, {"br", [], []}})
    |> ok()
  end

  # Other end tags: per spec "Parse error. Enable foster parenting, process the
  # token using the rules for the 'in body' insertion mode, and then disable
  # foster parenting."
  defp process_in_table({:end_tag, _} = token, state) do
    state
    |> parse_error()
    |> enable_foster_parenting()
    |> process_in_body(token)
  end

  # EOF: reprocess in in_body
  defp process_in_table(:eof, state) do
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

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

  defp start_table_text(state, text) do
    %{state | mode: :in_table_text, original_mode: :in_table, pending_table_text: text}
  end

  # Clear stack to table context (table, template, html)
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_context(%{stack: stack, elements: elements} = state) do
    {new_stack, parent_ref} = do_clear_to_table_context(stack, elements)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
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

  defp close_table(%{stack: stack, elements: elements} = state) do
    stack
    |> do_close_table([], elements)
    |> finish_close_table(state)
  end

  # Fragment case: if nothing was actually closed (hit html boundary),
  # keep the current state unchanged
  defp finish_close_table({_new_stack, [], _parent_ref}, state), do: state

  defp finish_close_table(
         {new_stack, closed_refs, _parent_ref},
         %{af: af, elements: elements} = state
       ) do
    new_af = reject_refs_from_af(af, closed_refs)

    # Pop any orphaned formatting element from stack top (removed from AF by AA)
    {final_stack, current_parent_ref} =
      pop_orphaned_formatting_element(new_stack, new_af, elements)

    state
    |> Map.merge(%{stack: final_stack, af: new_af, current_parent_ref: current_parent_ref})
    |> pop_mode()
  end

  defp pop_orphaned_formatting_element([], _af, _elements), do: {[], nil}

  defp pop_orphaned_formatting_element([top | rest] = stack, af, elements) do
    elem = elements[top]
    in_af = Enum.any?(af, &match?({^top, _, _}, &1))

    # Pop formatting elements removed from AF so content after table goes to correct parent
    if elem != nil and elem.tag in @formatting_element_tags and not in_af do
      {rest, List.first(rest)}
    else
      {stack, top}
    end
  end

  defp do_close_table([], closed_refs, _elements), do: {[], closed_refs, nil}

  defp do_close_table([ref | rest], closed_refs, elements) do
    case elements[ref] do
      %{tag: "table", parent_ref: parent_ref} ->
        {rest, [ref | closed_refs], parent_ref}

      %{tag: boundary} when boundary in ["template", "html"] ->
        {[ref | rest], closed_refs, ref}

      # Skip foster-parented elements - they're outside the table
      # and should stay in AF for reconstruction
      %{foster_parent_ref: fpr} when not is_nil(fpr) ->
        do_close_table(rest, closed_refs, elements)

      _ ->
        do_close_table(rest, [ref | closed_refs], elements)
    end
  end
end
