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

  alias PureHTML.TreeBuilder.Modes.InBody

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  @impl true
  # If top of stack is foreign content (svg/math), delegate to in_body
  # which has proper foreign content handling
  def process(token, %{stack: [%{tag: {ns, _}} | _]} = state) when ns in [:svg, :math] do
    InBody.process(token, state)
  end

  # Template pushed :in_table mode (e.g., after seeing <tbody> in template)
  # No real table exists - use body rules
  def process(token, %{template_mode_stack: [:in_table | _]} = state) do
    InBody.process(token, state)
  end

  def process(token, state) do
    process_in_table(token, state)
  end

  # Character tokens in table context elements: whitespace inserts, non-whitespace foster parents
  defp process_in_table({:character, text}, %{stack: [%{tag: tag} | _]} = state)
       when tag in @table_context do
    if String.trim(text) == "" do
      {:ok, add_text_to_stack(state, text)}
    else
      # Foster parent via in_body
      InBody.process({:character, text}, state)
    end
  end

  # Character tokens not in table context: delegate to in_body
  defp process_in_table({:character, _} = token, state) do
    InBody.process(token, state)
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
  defp process_in_table({:start_tag, "table", _, _}, %{stack: stack} = state) do
    if has_table_in_scope?(stack) do
      state = close_table(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # Start tags: style, script, template - process using in_head rules
  defp process_in_table({:start_tag, tag, _, _}, state) when tag in ~w(style script template) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Start tag: input - check for type=hidden
  defp process_in_table({:start_tag, "input", attrs, _}, %{stack: stack} = state) do
    type = Map.get(attrs, "type", "") |> String.downcase()

    if type == "hidden" do
      # Insert directly, no foster parenting
      {:ok, add_child_to_stack(state, {"input", attrs, []})}
    else
      # Foster parent
      new_stack = foster_element(stack, {"input", attrs, []})
      {:ok, %{state | stack: new_stack}}
    end
  end

  # Start tag: form - special handling
  defp process_in_table(
         {:start_tag, "form", attrs, _},
         %{stack: stack, form_element: nil} = state
       ) do
    # Only if no form element pointer and no template in stack
    if not has_template?(stack) do
      form = new_element("form", attrs)
      {:ok, %{state | form_element: form} |> add_child_to_stack(form)}
    else
      {:ok, state}
    end
  end

  defp process_in_table({:start_tag, "form", _, _}, state) do
    # Form element pointer already set, ignore
    {:ok, state}
  end

  # SVG and math: foster parent as foreign elements
  defp process_in_table({:start_tag, "svg", attrs, self_closing}, %{stack: stack} = state) do
    new_stack = foster_push_foreign_element(stack, :svg, "svg", attrs, self_closing)
    {:ok, %{state | stack: new_stack}}
  end

  defp process_in_table({:start_tag, "math", attrs, self_closing}, %{stack: stack} = state) do
    new_stack = foster_push_foreign_element(stack, :math, "math", attrs, self_closing)
    {:ok, %{state | stack: new_stack}}
  end

  # Select: foster parent and push in_select mode
  defp process_in_table({:start_tag, "select", attrs, _}, %{stack: stack} = state) do
    {new_stack, _ref} = foster_push_element(stack, "select", attrs)
    {:ok, %{state | stack: new_stack, mode: :in_select}}
  end

  # Other start tags: foster parent directly
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

  defp process_in_table({:start_tag, tag, attrs, self_closing}, %{stack: stack, af: af} = state) do
    cond do
      self_closing or tag in @void_elements ->
        new_stack = foster_element(stack, {tag, attrs, []})
        {:ok, %{state | stack: new_stack}}

      tag in @formatting_elements ->
        {new_stack, new_ref} = foster_push_element(stack, tag, attrs)
        new_af = [{new_ref, tag, attrs} | af]
        {:ok, %{state | stack: new_stack, af: new_af}}

      true ->
        {new_stack, _ref} = foster_push_element(stack, tag, attrs)
        {:ok, %{state | stack: new_stack}}
    end
  end

  # End tag: table
  defp process_in_table({:end_tag, "table"}, %{stack: stack} = state) do
    if has_table_in_scope?(stack) do
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

  # Other end tags: foster parent via in_body
  defp process_in_table({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # Error tokens: ignore
  defp process_in_table({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  defp push_element(%{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  defp set_mode(state, mode), do: %{state | mode: mode}

  defp push_af_marker(%{af: af} = state), do: %{state | af: [:marker | af]}

  defp add_text_to_stack(%{stack: stack} = state, text) do
    %{state | stack: add_text_child(stack, text)}
  end

  defp add_text_child([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text_child([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text_child([], _text), do: []

  defp add_child_to_stack(%{stack: stack} = state, child) do
    %{state | stack: add_child(stack, child)}
  end

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], _child), do: []

  # Clear stack to table context (table, template, html)
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_context(%{stack: stack} = state) do
    %{state | stack: do_clear_to_table_context(stack)}
  end

  defp do_clear_to_table_context([%{tag: tag} | _] = stack) when tag in @table_boundaries do
    stack
  end

  defp do_clear_to_table_context([elem | rest]) do
    do_clear_to_table_context(add_child(rest, elem))
  end

  defp do_clear_to_table_context([]), do: []

  defp ensure_colgroup(%{stack: [%{tag: "colgroup"} | _]} = state), do: state

  defp ensure_colgroup(%{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "colgroup", %{})
  end

  defp ensure_colgroup(state), do: state

  defp ensure_tbody(%{stack: [%{tag: tag} | _]} = state) when tag in @table_sections do
    state
  end

  defp ensure_tbody(%{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "tbody", %{})
  end

  defp ensure_tbody(state), do: state

  defp has_table_in_scope?(stack), do: do_has_table_in_scope?(stack)

  defp do_has_table_in_scope?([%{tag: "table"} | _]), do: true
  defp do_has_table_in_scope?([%{tag: tag} | _]) when tag in ["template", "html"], do: false
  defp do_has_table_in_scope?([_ | rest]), do: do_has_table_in_scope?(rest)
  defp do_has_table_in_scope?([]), do: false

  defp has_template?(stack), do: Enum.any?(stack, &match?(%{tag: "template"}, &1))

  defp close_table(%{stack: stack, af: af, template_mode_stack: tms} = state) do
    {new_stack, closed_refs} = do_close_table(stack, MapSet.new())
    new_af = reject_refs_from_af(af, closed_refs)
    new_tms = Enum.drop(tms, 1)
    mode = if new_tms == [], do: :in_body, else: hd(new_tms)
    %{state | stack: new_stack, af: new_af, mode: mode, template_mode_stack: new_tms}
  end

  defp do_close_table([%{tag: "table"} = table | rest], refs) do
    {add_child(rest, table), MapSet.put(refs, table.ref)}
  end

  defp do_close_table([%{tag: tag} | _] = stack, refs) when tag in ["template", "html"] do
    {stack, refs}
  end

  defp do_close_table([elem | rest], refs) do
    do_close_table(add_child(rest, elem), MapSet.put(refs, elem.ref))
  end

  defp do_close_table([], refs), do: {[], refs}

  defp reject_refs_from_af(af, refs) do
    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(refs, ref)
    end)
  end

  # Foreign element foster parenting helpers

  defp new_foreign_element(ns, tag, attrs) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: []}
  end

  defp foster_push_foreign_element(stack, ns, tag, attrs, self_closing) do
    if self_closing do
      # Self-closing: add as child before table, don't push to stack
      foster_element(stack, {{ns, tag}, attrs, []})
    else
      # Non-self-closing: push to stack to receive children
      new_elem = new_foreign_element(ns, tag, attrs)
      do_foster_push(stack, new_elem, [])
    end
  end

  defp foster_push_element(stack, tag, attrs) do
    new_elem = new_element(tag, attrs)
    {do_foster_push(stack, new_elem, []), new_elem.ref}
  end

  defp foster_element(stack, element) do
    do_foster_element(stack, element, [])
  end

  defp do_foster_element([%{tag: "table"} = table | rest], element, acc) do
    # Insert element as child of table's parent (body)
    rest = add_child(rest, element)
    rebuild_stack(acc, [table | rest])
  end

  defp do_foster_element([current | rest], element, acc) do
    do_foster_element(rest, element, [current | acc])
  end

  defp do_foster_element([], _element, acc) do
    Enum.reverse(acc)
  end

  defp do_foster_push([%{tag: "table"} = table | rest], new_elem, acc) do
    # Mark element with foster parent ref so it gets added to body when closed
    [foster_parent | _] = rest
    marked_elem = Map.put(new_elem, :foster_parent_ref, foster_parent.ref)
    table_and_below = [table | rest]
    [marked_elem | rebuild_stack(acc, table_and_below)]
  end

  defp do_foster_push([current | rest], new_elem, acc) do
    do_foster_push(rest, new_elem, [current | acc])
  end

  defp do_foster_push([], new_elem, acc) do
    Enum.reverse([new_elem | acc])
  end

  defp rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)
end
