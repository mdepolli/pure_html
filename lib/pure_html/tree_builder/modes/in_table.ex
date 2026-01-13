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
      set_mode: 2,
      push_af_marker: 1,
      add_child_to_stack: 2,
      in_table_scope?: 2,
      has_tag?: 2,
      foster_parent: 2,
      new_element: 2,
      reject_refs_from_af: 2
    ]

  alias PureHTML.TreeBuilder.AdoptionAgency
  alias PureHTML.TreeBuilder.Modes.InBody

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  @impl true
  # If top of stack is foreign content (svg/math), delegate to in_body
  # which has proper foreign content handling
  def process(token, %{stack: [ref | _], elements: elements} = state) do
    do_process(elements[ref], token, state)
  end

  def process(token, state), do: process_dispatch(token, state)

  defp do_process(%{tag: {ns, _}}, token, state) when ns in [:svg, :math] do
    InBody.process(token, state)
  end

  defp do_process(_, token, state), do: process_dispatch(token, state)

  defp process_dispatch(token, %{template_mode_stack: [:in_table | _]} = state) do
    # Template pushed :in_table mode (e.g., after seeing <tbody> in template)
    # No real table exists - use body rules
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
    if in_table_scope?(state, "table") do
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

  # Start tag: form - special handling
  defp process_in_table({:start_tag, "form", attrs, _}, %{form_element: nil} = state) do
    # Only if no form element pointer and no template in stack
    if has_tag?(state, "template") do
      {:ok, state}
    else
      form = new_element("form", attrs)
      {:ok, %{state | form_element: form} |> add_child_to_stack(form)}
    end
  end

  defp process_in_table({:start_tag, "form", _, _}, state) do
    # Form element pointer already set, ignore
    {:ok, state}
  end

  # SVG and math: foster parent as foreign elements
  defp process_in_table({:start_tag, "svg", attrs, self_closing}, state) do
    {:ok, foster_foreign_element(state, :svg, "svg", attrs, self_closing)}
  end

  defp process_in_table({:start_tag, "math", attrs, self_closing}, state) do
    {:ok, foster_foreign_element(state, :math, "math", attrs, self_closing)}
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

  # Other start tags: foster parent directly
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)
  @adopt_on_duplicate ~w(a nobr)

  defp process_in_table({:start_tag, tag, attrs, self_closing}, %{af: af} = state) do
    cond do
      self_closing or tag in @void_elements ->
        {new_state, _} = foster_parent(state, {:element, {tag, attrs, []}})
        {:ok, new_state}

      tag in @formatting_elements ->
        # For <a> and <nobr>, run adoption agency if duplicate
        state =
          if tag in @adopt_on_duplicate and has_formatting_entry?(af, tag) do
            AdoptionAgency.run(state, tag)
          else
            state
          end

        {new_state, new_ref} = foster_parent(state, {:push, tag, attrs})
        new_af = [{new_ref, tag, attrs} | new_state.af]
        {:ok, %{new_state | af: new_af}}

      true ->
        {new_state, _ref} = foster_parent(state, {:push, tag, attrs})
        {:ok, new_state}
    end
  end

  # End tag: table
  defp process_in_table({:end_tag, "table"}, state) do
    if in_table_scope?(state, "table") do
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
    case close_select_in_scope(state) do
      {:ok, new_state} -> {:ok, new_state}
      :not_found -> {:ok, state}
    end
  end

  # Other end tags: foster parent via in_body
  defp process_in_table({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # Error tokens: ignore
  defp process_in_table({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers (in_table specific - general helpers imported from TreeBuilder.Helpers)
  # --------------------------------------------------------------------------

  defp do_process_character(%{tag: tag}, text, state) when tag in @table_context do
    # Switch to in_table_text mode to collect character tokens
    {:ok,
     %{
       state
       | mode: :in_table_text,
         original_mode: :in_table,
         pending_table_text: text
     }}
  end

  defp do_process_character(_, text, state) do
    # Character tokens not in table context: delegate to in_body
    InBody.process({:character, text}, state)
  end

  defp foster_foreign_element(state, ns, tag, attrs, self_closing) do
    {new_state, _} = foster_parent(state, {:push_foreign, ns, tag, attrs, self_closing})
    new_state
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
    do_ensure_colgroup(elements[ref], state)
  end

  defp ensure_colgroup(state), do: state

  defp do_ensure_colgroup(%{tag: "colgroup"}, state), do: state
  defp do_ensure_colgroup(%{tag: "table"}, state), do: push_element(state, "colgroup", %{})
  defp do_ensure_colgroup(_, state), do: state

  defp ensure_tbody(%{stack: [ref | _], elements: elements} = state) do
    do_ensure_tbody(elements[ref], state)
  end

  defp ensure_tbody(state), do: state

  defp do_ensure_tbody(%{tag: tag}, state) when tag in @table_sections, do: state
  defp do_ensure_tbody(%{tag: "table"}, state), do: push_element(state, "tbody", %{})
  defp do_ensure_tbody(_, state), do: state

  defp close_table(%{stack: stack, af: af, elements: elements, template_mode_stack: tms} = state) do
    {new_stack, closed_refs, parent_ref} = do_close_table(stack, [], elements)
    new_af = reject_refs_from_af(af, closed_refs)
    new_tms = Enum.drop(tms, 1)
    mode = List.first(new_tms, :in_body)

    %{
      state
      | stack: new_stack,
        af: new_af,
        mode: mode,
        template_mode_stack: new_tms,
        current_parent_ref: parent_ref
    }
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
  defp close_select_in_scope(%{stack: stack, elements: elements} = state) do
    case find_select_in_scope(stack, elements) do
      {:found, new_stack, parent_ref} ->
        {:ok, %{state | stack: new_stack, current_parent_ref: parent_ref}}

      :not_found ->
        :not_found
    end
  end

  @select_scope_barriers ~w(table template html)
  defp find_select_in_scope([], _elements), do: :not_found

  defp find_select_in_scope([ref | rest], elements) do
    case elements[ref] do
      %{tag: "select", parent_ref: parent_ref} -> {:found, rest, parent_ref}
      %{tag: tag} when tag in @select_scope_barriers -> :not_found
      _ -> find_select_in_scope(rest, elements)
    end
  end

  defp has_formatting_entry?(af, tag) do
    Enum.any?(af, fn
      {_, ^tag, _} -> true
      _ -> false
    end)
  end
end
