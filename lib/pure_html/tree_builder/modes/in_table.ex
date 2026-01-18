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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      push_element: 3,
      pop_element: 1,
      set_mode: 2,
      push_af_marker: 1,
      add_child_to_stack: 2,
      in_scope?: 3,
      find_ref: 2,
      foster_parent: 2,
      reject_refs_from_af: 2,
      needs_foster_parenting?: 1,
      update_af_entry: 3
    ]

  alias PureHTML.TreeBuilder.AdoptionAgency
  alias PureHTML.TreeBuilder.Modes.InBody

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  @impl true
  def process(token, %{stack: [ref | _], elements: elements} = state) do
    # If top of stack is foreign content (svg/math), delegate to in_body
    # which has proper foreign content handling
    case elements[ref] do
      %{tag: {ns, _}} when ns in [:svg, :math] -> InBody.process(token, state)
      _ -> process_dispatch(token, state)
    end
  end

  def process(token, state), do: process_dispatch(token, state)

  # In template context with table-related modes, most tokens go through normal
  # process_in_table which handles foster parenting correctly.
  # Only end tags for non-table elements need special handling via InBody.
  @template_table_modes [
    :in_table,
    :in_table_body,
    :in_row,
    :in_cell,
    :in_caption,
    :in_column_group
  ]

  # End tags for non-table elements in template table context: use InBody rules
  # (InBody handles "any other end tag" by traversing stack)
  defp process_dispatch({:end_tag, _} = token, %{template_mode_stack: [mode | _]} = state)
       when mode in @template_table_modes do
    InBody.process(token, state)
  end

  defp process_dispatch(token, state) do
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
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  defp process_in_table({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: caption
  defp process_in_table({:start_tag, "caption", attrs, _}, state) do
    state =
      state
      |> clear_to_table_context()
      |> push_af_marker()
      |> push_element("caption", attrs)
      |> set_mode(:in_caption)

    {:ok, state}
  end

  # Start tag: colgroup
  defp process_in_table({:start_tag, "colgroup", attrs, _}, state) do
    state =
      state
      |> clear_to_table_context()
      |> push_element("colgroup", attrs)
      |> set_mode(:in_column_group)

    {:ok, state}
  end

  # Start tag: col - ensure colgroup wrapper
  defp process_in_table({:start_tag, "col", attrs, _}, state) do
    state =
      state
      |> clear_to_table_context()
      |> ensure_colgroup()
      |> add_child_to_stack({"col", attrs, []})

    {:ok, state}
  end

  # Start tags: tbody, thead, tfoot
  defp process_in_table({:start_tag, tag, attrs, _}, state) when tag in @table_sections do
    state =
      state
      |> clear_to_table_context()
      |> push_element(tag, attrs)
      |> set_mode(:in_table_body)

    {:ok, state}
  end

  # Start tags: td, th, tr - ensure tbody, reprocess
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ~w(td th tr) do
    state =
      state
      |> clear_to_table_context()
      |> ensure_tbody()
      |> set_mode(:in_table_body)

    {:reprocess, state}
  end

  # Start tag: nested table - close current table, reprocess
  defp process_in_table({:start_tag, "table", _, _}, state) do
    if in_scope?(state, "table", :table) do
      state = close_table(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # Start tags: style, script - process using in_head rules
  # Set original_mode first so we return to table context after text mode
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ~w(style script) do
    {:reprocess, %{state | original_mode: state.mode, mode: :in_head}}
  end

  # Start tag: template - process using in_head rules (no original_mode needed)
  defp process_in_table({:start_tag, "template", _, _}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Start tag: input - check for type=hidden
  defp process_in_table({:start_tag, "input", attrs, _}, state) do
    type = Map.get(attrs, "type", "") |> String.downcase()

    if type == "hidden" do
      # Insert directly, no foster parenting
      {:ok, add_child_to_stack(state, {"input", attrs, []})}
    else
      # Foster parent
      {new_state, _} = foster_parent(state, {:element, {"input", attrs, []}})
      {:ok, new_state}
    end
  end

  # Start tag: form - special handling per HTML5 spec
  # In table mode, if form_element is null and no template on stack:
  # 1. Insert the form element (directly to table, not foster-parented)
  # 2. Set form_element pointer to that element
  # 3. Pop the element immediately (it stays in tree but not on stack)
  defp process_in_table({:start_tag, "form", attrs, _}, %{form_element: nil} = state) do
    # Only if no form element pointer and no template in stack
    if find_ref(state, "template") do
      {:ok, state}
    else
      # Push form, set pointer, then pop (form stays in tree as child of table)
      state = push_element(state, "form", attrs)
      [form_ref | _] = state.stack
      state = pop_element(state)
      {:ok, %{state | form_element: form_ref}}
    end
  end

  defp process_in_table({:start_tag, "form", _, _}, state) do
    # Form element pointer already set, ignore
    {:ok, state}
  end

  # SVG and math: foster parent as foreign elements
  defp process_in_table({:start_tag, tag, attrs, self_closing}, state)
       when tag in ["svg", "math"] do
    ns = if tag == "svg", do: :svg, else: :math
    {new_state, _} = foster_parent(state, {:push_foreign, ns, tag, attrs, self_closing})
    {:ok, new_state}
  end

  # Select: foster parent and push in_select_in_table mode
  defp process_in_table({:start_tag, "select", attrs, _}, state) do
    {new_state, _ref} = foster_parent(state, {:push, "select", attrs})
    {:ok, set_mode(new_state, :in_select_in_table)}
  end

  # Frameset/frame: parse error, ignore (table sets frameset_ok to false)
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ["frameset", "frame"] do
    {:ok, state}
  end

  # Other start tags: check if foster parenting is needed
  # Per HTML5 spec, enable foster parenting then process using in_body rules
  # "Appropriate insertion location" checks if current node is table context
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @formatting_element_tags ~w(a b big code em font i nobr s small strike strong tt u)
  @adopt_on_duplicate ~w(a nobr)
  @implicit_close_elements ~w(li dd dt)

  defp process_in_table({:start_tag, tag, attrs, self_closing}, state) do
    process_other_start_tag(tag, attrs, self_closing, state)
  end

  # End tag: table
  defp process_in_table({:end_tag, "table"}, state) do
    if in_scope?(state, "table", :table) do
      {:ok, close_table(state)}
    else
      {:ok, state}
    end
  end

  # End tag: template - process using in_head rules
  defp process_in_table({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Ignored end tags: parse error, ignore
  defp process_in_table({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
  end

  # </br> special case: foster parent a <br> element (per HTML5 spec, </br> is treated as <br>)
  defp process_in_table({:end_tag, "br"}, state) do
    {new_state, _} = foster_parent(state, {:element, {"br", %{}, []}})
    {:ok, new_state}
  end

  # </select> special case: close select if in scope, but don't change mode
  # (InBody's handler calls pop_mode which would incorrectly switch to in_body)
  defp process_in_table({:end_tag, "select"}, state) do
    {:ok, close_select_in_scope(state)}
  end

  # </p> special case: check if p is in button scope
  # If p is in scope (possibly above table due to foster parenting), close it
  # Otherwise, foster parent an empty p element
  defp process_in_table({:end_tag, "p"}, state) do
    if in_scope?(state, "p", :button) do
      # Let in_body handle closing the p
      InBody.process({:end_tag, "p"}, state)
    else
      # Foster parent an empty p element
      {new_state, _} = foster_parent(state, {:element, {"p", %{}, []}})
      {:ok, new_state}
    end
  end

  # Other end tags: process via in_body
  defp process_in_table({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # Error tokens: ignore
  defp process_in_table({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers (in_table specific - general helpers imported from TreeBuilder.Helpers)
  # --------------------------------------------------------------------------

  # Self-closing tags
  defp process_other_start_tag(tag, attrs, true, state) do
    insert_void_element(tag, attrs, state)
  end

  # Void elements
  defp process_other_start_tag(tag, attrs, _, state) when tag in @void_elements do
    insert_void_element(tag, attrs, state)
  end

  # Formatting elements
  defp process_other_start_tag(tag, attrs, _, %{af: af} = state)
       when tag in @formatting_element_tags do
    {state, old_ref} = handle_duplicate_formatting(state, af, tag)
    {new_state, new_ref} = push_formatting_element(state, tag, attrs)

    new_af = [{new_ref, tag, attrs} | new_state.af]
    new_state = %{new_state | af: new_af}

    new_state =
      if old_ref do
        remove_formatting_element_by_ref(new_state, old_ref)
      else
        new_state
      end

    {:ok, new_state}
  end

  # li, dd, dt: close open same-type element if foster-parented before inserting
  defp process_other_start_tag(tag, attrs, _, state) when tag in @implicit_close_elements do
    state = close_foster_parented_same_tag(state, tag)
    insert_or_foster_push(tag, attrs, state)
  end

  # Fallback: any other tag
  defp process_other_start_tag(tag, attrs, _, state) do
    insert_or_foster_push(tag, attrs, state)
  end

  defp insert_void_element(tag, attrs, state) do
    state =
      if needs_foster_parenting?(state) do
        reconstruct_formatting_for_foster(state)
      else
        state
      end

    if needs_foster_parenting?(state) do
      {new_state, _} = foster_parent(state, {:element, {tag, attrs, []}})
      {:ok, new_state}
    else
      {:ok, add_child_to_stack(state, {tag, attrs, []})}
    end
  end

  defp insert_or_foster_push(tag, attrs, state) do
    if needs_foster_parenting?(state) do
      {new_state, _ref} = foster_parent(state, {:push, tag, attrs})
      {:ok, new_state}
    else
      {:ok, push_element(state, tag, attrs)}
    end
  end

  defp do_process_character(%{tag: tag}, text, state) when tag in @table_context do
    # Switch to in_table_text mode to collect character tokens
    # Preserve original_mode if already set (e.g., delegated from in_row)
    orig_mode = state.original_mode || :in_table

    {:ok,
     %{
       state
       | mode: :in_table_text,
         original_mode: orig_mode,
         pending_table_text: text
     }}
  end

  defp do_process_character(_, text, state) do
    # Character tokens not in table context: delegate to in_body
    InBody.process({:character, text}, state)
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
      "table" -> push_element(state, "colgroup", %{})
      _ -> state
    end
  end

  defp ensure_colgroup(state), do: state

  defp ensure_tbody(%{stack: [ref | _], elements: elements} = state) do
    case elements[ref].tag do
      tag when tag in @table_sections -> state
      # In template context, template is the table context boundary - create tbody there too
      tag when tag in ["table", "template"] -> push_element(state, "tbody", %{})
      _ -> state
    end
  end

  defp ensure_tbody(state), do: state

  defp close_table(%{stack: stack, af: af, elements: elements, template_mode_stack: tms} = state) do
    {new_stack, closed_refs, _stored_parent_ref} = do_close_table(stack, [], elements)
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

  # Handle duplicate formatting elements (<a> and <nobr>)
  # Runs AA if duplicate exists, returns {state, old_ref}
  defp handle_duplicate_formatting(state, af, tag) do
    if tag in @adopt_on_duplicate and has_formatting_entry?(af, tag) do
      state = AdoptionAgency.run(state, tag)
      old_ref = find_formatting_ref(state.af, tag)
      {state, old_ref}
    else
      {state, nil}
    end
  end

  # Push formatting element with foster parenting reconstruction if needed
  defp push_formatting_element(state, tag, attrs) do
    state =
      if needs_foster_parenting?(state) do
        reconstruct_formatting_for_foster(state)
      else
        state
      end

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
