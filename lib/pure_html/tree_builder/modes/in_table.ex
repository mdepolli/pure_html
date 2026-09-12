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

  alias PureHTML.TreeBuilder.AdoptionAgency
  alias PureHTML.TreeBuilder.Modes.InBody

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  # In template context with table-related modes, end tags for non-table
  # elements need special handling via InBody (which traverses the stack).
  @template_table_modes [
    :in_table,
    :in_table_body,
    :in_row,
    :in_cell,
    :in_caption,
    :in_column_group
  ]

  @impl true
  def process({:end_tag, _} = token, %{template_mode_stack: [mode | _]} = state)
      when mode in @template_table_modes do
    InBody.process(token, state)
  end

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

  # Start tag: col - ensure colgroup wrapper
  defp process_in_table({:start_tag, "col", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> ensure_colgroup()
    |> add_child_to_stack({"col", attrs, []})
    |> ok()
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

  # SVG and math: per spec "Parse error." Foster parent as foreign elements.
  defp process_in_table({:start_tag, "svg", attrs, self_closing}, state) do
    state
    |> parse_error()
    |> foster_insert({:push_foreign, :svg, "svg", attrs, self_closing})
    |> ok()
  end

  defp process_in_table({:start_tag, "math", attrs, self_closing}, state) do
    state
    |> parse_error()
    |> foster_insert({:push_foreign, :math, "math", attrs, self_closing})
    |> ok()
  end

  # Select: per spec "Parse error." Foster parent and push in_select_in_table mode.
  defp process_in_table({:start_tag, "select", attrs, _}, state) do
    state
    |> parse_error()
    |> foster_insert({:push, "select", attrs})
    |> set_mode(:in_select_in_table)
    |> ok()
  end

  # Frameset/frame: per spec "Parse error. Ignore the token."
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ["frameset", "frame"] do
    state
    |> parse_error()
    |> ok()
  end

  # Other start tags: per spec "Parse error. Enable foster parenting, process
  # the token using the rules for the 'in body' insertion mode."
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @formatting_element_tags ~w(a b big code em font i nobr s small strike strong tt u)
  @adopt_on_duplicate ~w(a nobr)
  @implicit_close_elements ~w(li dd dt)

  defp process_in_table({:start_tag, tag, attrs, self_closing}, state) do
    state
    |> parse_error()
    |> process_other_start_tag(tag, attrs, self_closing)
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

  # </select> special case: close select if in scope, but don't change mode
  # (InBody's handler calls pop_mode which would incorrectly switch to in_body)
  defp process_in_table({:end_tag, "select"}, state) do
    state
    |> close_select_in_scope()
    |> ok()
  end

  # </p> special case: per spec "Parse error." Check if p is in button scope.
  defp process_in_table({:end_tag, "p"}, state) do
    if in_scope?(state, "p", :button) do
      # Let in_body handle closing the p
      state
      |> parse_error()
      |> process_in_body({:end_tag, "p"})
    else
      # Foster parent an empty p element
      state
      |> parse_error()
      |> foster_insert({:element, {"p", [], []}})
      |> ok()
    end
  end

  # Other end tags: per spec "Parse error. Process using in_body rules."
  defp process_in_table({:end_tag, _} = token, state) do
    state
    |> parse_error()
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

  defp process_in_body(state, token), do: InBody.process(token, state)

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

  # Self-closing tags
  defp process_other_start_tag(state, tag, attrs, true) do
    state
    |> insert_void_element(tag, attrs)
    |> ok()
  end

  # Void elements
  defp process_other_start_tag(state, tag, attrs, _) when tag in @void_elements do
    state
    |> insert_void_element(tag, attrs)
    |> ok()
  end

  # Formatting elements. Per HTML5 spec, a duplicate <a>/<nobr> runs the
  # adoption agency first; the old element is then removed once the new one is in.
  defp process_other_start_tag(%{af: af} = state, tag, attrs, _)
       when tag in @formatting_element_tags do
    if tag in @adopt_on_duplicate and has_formatting_entry?(af, tag) do
      state
      |> parse_error()
      |> AdoptionAgency.run(tag)
      |> replace_formatting_element(tag, attrs)
      |> ok()
    else
      state
      |> insert_formatting_element(tag, attrs)
      |> ok()
    end
  end

  # li, dd, dt: close open same-type element if foster-parented before inserting
  defp process_other_start_tag(state, tag, attrs, _) when tag in @implicit_close_elements do
    state
    |> close_foster_parented_same_tag(tag)
    |> push_or_foster_push(tag, attrs)
    |> ok()
  end

  # Fallback: any other tag
  defp process_other_start_tag(state, tag, attrs, _) do
    state
    |> push_or_foster_push(tag, attrs)
    |> ok()
  end

  defp replace_formatting_element(%{af: af} = state, tag, attrs) do
    af
    |> find_formatting_ref(tag)
    |> replace_formatting_ref(tag, attrs, state)
  end

  defp replace_formatting_ref(nil, tag, attrs, state) do
    insert_formatting_element(state, tag, attrs)
  end

  defp replace_formatting_ref(old_ref, tag, attrs, state) do
    state
    |> insert_formatting_element(tag, attrs)
    |> remove_formatting_element_by_ref(old_ref)
  end

  defp insert_formatting_element(state, tag, attrs) do
    {new_state, new_ref} = push_formatting_element(state, tag, attrs)
    %{new_state | af: [{new_ref, tag, attrs} | new_state.af]}
  end

  defp insert_void_element(state, tag, attrs) do
    state
    |> reconstruct_if_foster_parenting()
    |> add_or_foster_child({tag, attrs, []})
  end

  defp reconstruct_if_foster_parenting(state) do
    if needs_foster_parenting?(state) do
      reconstruct_formatting_for_foster(state)
    else
      state
    end
  end

  defp add_or_foster_child(state, child) do
    if needs_foster_parenting?(state) do
      foster_insert(state, {:element, child})
    else
      add_child_to_stack(state, child)
    end
  end

  defp push_or_foster_push(state, tag, attrs) do
    if needs_foster_parenting?(state) do
      foster_insert(state, {:push, tag, attrs})
    else
      push_element(state, tag, attrs)
    end
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

  # Preserve original_mode if already set (e.g., delegated from in_row)
  defp start_table_text(%{original_mode: nil} = state, text) do
    %{state | mode: :in_table_text, original_mode: :in_table, pending_table_text: text}
  end

  defp start_table_text(state, text) do
    %{state | mode: :in_table_text, pending_table_text: text}
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

  defp ensure_colgroup(%{stack: [ref | _], elements: elements} = state) do
    case elements[ref].tag do
      "colgroup" -> state
      "table" -> push_element(state, "colgroup", [])
      _ -> state
    end
  end

  defp ensure_colgroup(state), do: state

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
         %{af: af, elements: elements, template_mode_stack: tms} = state
       ) do
    new_af = reject_refs_from_af(af, closed_refs)
    new_tms = Enum.drop(tms, 1)
    mode = List.first(new_tms, :in_body)

    # Pop any orphaned formatting element from stack top (removed from AF by AA)
    {final_stack, current_parent_ref} =
      pop_orphaned_formatting_element(new_stack, new_af, elements)

    %{
      state
      | stack: final_stack,
        af: new_af,
        mode: mode,
        template_mode_stack: new_tms,
        current_parent_ref: current_parent_ref
    }
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

  # Close select if in select scope (table/template/html are barriers)
  # Returns state unchanged if select not in scope
  @select_scope_barriers ~w(table template html)

  defp close_select_in_scope(%{stack: stack, elements: elements} = state) do
    do_close_select_in_scope(stack, elements, state)
  end

  defp do_close_select_in_scope([], _elements, state), do: state

  defp do_close_select_in_scope([ref | rest], elements, state) do
    case elements[ref] do
      %{tag: "select", parent_ref: parent_ref} ->
        %{state | stack: rest, current_parent_ref: parent_ref}

      %{tag: tag} when tag in @select_scope_barriers ->
        state

      _ ->
        do_close_select_in_scope(rest, elements, state)
    end
  end

  defp has_formatting_entry?(af, tag) do
    Enum.any?(af, &match?({_, ^tag, _}, &1))
  end

  # Push formatting element with foster parenting reconstruction if needed.
  # Returns {state, new_ref}.
  defp push_formatting_element(state, tag, attrs) do
    state
    |> reconstruct_if_foster_parenting()
    |> push_or_foster_push_ref(tag, attrs)
  end

  defp push_or_foster_push_ref(state, tag, attrs) do
    if needs_foster_parenting?(state) do
      foster_parent(state, {:push, tag, attrs})
    else
      new_state = push_element(state, tag, attrs)
      [new_ref | _] = new_state.stack
      {new_state, new_ref}
    end
  end

  # Close a foster-parented element of the same tag if it's the current node
  # This handles implicit closing for li, dd, dt in foster parenting context
  defp close_foster_parented_same_tag(%{stack: [ref | rest], elements: elements} = state, tag) do
    case elements[ref] do
      %{tag: ^tag, foster_parent_ref: fpr} when not is_nil(fpr) ->
        # Current node is a foster-parented element of the same tag - pop it
        parent_ref = elements[ref].parent_ref
        %{state | stack: rest, current_parent_ref: parent_ref}

      _ ->
        state
    end
  end

  defp close_foster_parented_same_tag(state, _tag), do: state

  # Per HTML5 spec: after running AA for <a>/<nobr> in table context,
  # explicitly remove old element from AF and stack if AA didn't already
  defp remove_formatting_element_by_ref(%{af: af, stack: stack} = state, ref) do
    new_af = Enum.reject(af, &match?({^ref, _, _}, &1))
    new_stack = List.delete(stack, ref)
    %{state | af: new_af, stack: new_stack}
  end

  defp find_formatting_ref(af, tag) do
    Enum.find_value(af, fn
      {ref, ^tag, _} -> ref
      _ -> nil
    end)
  end

  # Reconstruct active formatting elements for foster parenting
  # Creates clones of formatting elements and foster-parents them
  defp reconstruct_formatting_for_foster(%{stack: stack, af: af} = state) do
    entries =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {ref, _tag, _attrs} -> ref not in stack end)

    reconstruct_entries_foster(entries, state)
  end

  defp reconstruct_entries_foster([], state), do: state

  defp reconstruct_entries_foster([{old_ref, tag, attrs} | rest], state) do
    # Foster-push the element (inserts before table)
    {new_state, new_ref} = foster_parent(state, {:push, tag, attrs})

    # Update AF entry to point to new ref
    new_af = update_af_entry(new_state.af, old_ref, {new_ref, tag, attrs})
    new_state = %{new_state | af: new_af}

    reconstruct_entries_foster(rest, new_state)
  end
end
