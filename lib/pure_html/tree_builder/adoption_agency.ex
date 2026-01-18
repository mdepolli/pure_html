defmodule PureHTML.TreeBuilder.AdoptionAgency do
  @moduledoc """
  HTML5 Adoption Agency Algorithm.

  This algorithm handles the complex case of misnested formatting elements,
  ensuring that tags like `<b>`, `<i>`, `<a>` are properly closed even when
  they overlap with block elements.

  See: https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm
  """

  import PureHTML.TreeBuilder.Helpers, only: [new_element: 3]

  # Scope boundaries for the "in scope" check
  @scope_boundaries ~w(
    applet caption html table td th marquee object template
    math mi mo mn ms mtext annotation-xml
    svg foreignObject desc title
  )

  # Use shared special_elements from Helpers
  @special_elements PureHTML.TreeBuilder.Helpers.special_elements()

  @doc """
  Run the adoption agency algorithm for the given subject tag.

  Returns the modified state. If no formatting element is found in the active
  formatting list, calls the provided `on_no_formatting_element` function
  (typically to close the tag normally).

  ## Parameters
    - state: Parser state with stack, elements, af (active formatting), current_parent_ref
    - subject: The tag name being processed (e.g., "b", "i", "a")
    - on_no_formatting_element: Function called when subject not in AF (fn state, tag -> state)
  """
  def run(state, subject, on_no_formatting_element \\ fn state, _tag -> state end) do
    outer_loop(state, subject, on_no_formatting_element, 0)
  end

  # Outer loop - runs up to 8 iterations
  defp outer_loop(state, _subject, _fallback, iteration) when iteration >= 8, do: state

  defp outer_loop(%{af: af} = state, subject, fallback, iteration) do
    case locate_formatting_element(state, subject) do
      :not_in_af ->
        if iteration == 0, do: fallback.(state, subject), else: state

      {:not_in_stack, af_idx} ->
        %{state | af: List.delete_at(af, af_idx)}

      :not_in_scope ->
        state

      {:no_furthest_block, af_idx, stack_idx} ->
        pop_to_formatting_element(state, af_idx, stack_idx)

      {:has_furthest_block, af_idx, fe_ref, fe_tag, fe_attrs, stack_idx, fb_idx} ->
        state
        |> process_with_furthest_block({af_idx, fe_ref, fe_tag, fe_attrs}, stack_idx, fb_idx)
        |> outer_loop(subject, fallback, iteration + 1)
    end
  end

  # --------------------------------------------------------------------------
  # Locating the formatting element
  # --------------------------------------------------------------------------

  defp locate_formatting_element(%{af: af, stack: stack} = state, subject) do
    with {:ok, af_idx, {fe_ref, fe_tag, fe_attrs}} <- find_formatting_entry(af, subject),
         {:ok, stack_idx} <- find_in_stack(stack, fe_ref, af_idx),
         :ok <- check_in_scope(state, stack_idx) do
      case find_furthest_block(state, stack_idx) do
        nil -> {:no_furthest_block, af_idx, stack_idx}
        fb_idx -> {:has_furthest_block, af_idx, fe_ref, fe_tag, fe_attrs, stack_idx, fb_idx}
      end
    end
  end

  defp find_formatting_entry(af, subject) do
    result =
      af
      |> Enum.with_index()
      |> Enum.find_value(fn
        {{ref, ^subject, attrs}, idx} -> {idx, {ref, subject, attrs}}
        _ -> nil
      end)

    case result do
      nil -> :not_in_af
      {af_idx, entry} -> {:ok, af_idx, entry}
    end
  end

  defp find_in_stack(stack, fe_ref, af_idx) do
    case Enum.find_index(stack, &(&1 == fe_ref)) do
      nil -> {:not_in_stack, af_idx}
      stack_idx -> {:ok, stack_idx}
    end
  end

  defp check_in_scope(state, stack_idx) do
    if element_in_scope?(state, stack_idx), do: :ok, else: :not_in_scope
  end

  defp element_in_scope?(%{stack: stack, elements: elements}, target_idx) do
    do_element_in_scope?(stack, elements, target_idx)
  end

  defp do_element_in_scope?(_stack, _elements, 0), do: true

  defp do_element_in_scope?([ref | rest], elements, idx) when is_map_key(elements, ref) do
    if elements[ref].tag in @scope_boundaries do
      false
    else
      do_element_in_scope?(rest, elements, idx - 1)
    end
  end

  defp do_element_in_scope?([_ref | rest], elements, idx) do
    do_element_in_scope?(rest, elements, idx)
  end

  defp do_element_in_scope?([], _elements, _idx), do: false

  # --------------------------------------------------------------------------
  # Finding furthest block
  # --------------------------------------------------------------------------

  defp find_furthest_block(%{stack: stack, elements: elements}, fe_idx) do
    stack
    |> Enum.take(fe_idx)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(&find_special_element(&1, elements))
  end

  defp find_special_element({ref, idx}, elements) when is_map_key(elements, ref) do
    case elements[ref].tag do
      tag when is_binary(tag) and tag in @special_elements -> idx
      _ -> nil
    end
  end

  defp find_special_element(_, _), do: nil

  # --------------------------------------------------------------------------
  # Pop to formatting element (no furthest block case)
  # --------------------------------------------------------------------------

  defp pop_to_formatting_element(
         %{stack: stack, af: af} = state,
         af_idx,
         stack_idx
       ) do
    {_above_fe, [_fe_ref | rest]} = Enum.split(stack, stack_idx)

    # Use new stack top as current_parent_ref (not element's parent_ref)
    # This handles foster-parented elements correctly
    new_parent_ref =
      case rest do
        [top | _] -> top
        [] -> nil
      end

    new_af = List.delete_at(af, af_idx)

    %{state | stack: rest, af: new_af, current_parent_ref: new_parent_ref}
  end

  # --------------------------------------------------------------------------
  # Process with furthest block (main algorithm)
  # --------------------------------------------------------------------------

  defp process_with_furthest_block(
         %{stack: stack, elements: elements} = state,
         {af_idx, fe_ref, fe_tag, fe_attrs},
         fe_stack_idx,
         fb_idx
       ) do
    # Common ancestor = element immediately before FE in stack
    # BUT: if FE was foster parented, use its actual parent_ref instead
    # (foster_parent_ref is the table, parent_ref is the table's parent where FE was inserted)
    fe_elem = elements[fe_ref]

    is_foster_parented =
      is_map_key(elements, fe_ref) and
        is_map_key(fe_elem, :foster_parent_ref) and
        fe_elem.foster_parent_ref != nil

    # If FE was foster-parented, use its parent_ref (body) as common ancestor
    # and propagate the foster_parent_ref to clones created in inner loop
    {common_ancestor_ref, clone_foster_parent_ref} =
      if is_foster_parented do
        {fe_elem.parent_ref, fe_elem.foster_parent_ref}
      else
        {Enum.at(stack, fe_stack_idx + 1), nil}
      end

    fb_ref = Enum.at(stack, fb_idx)

    # Run inner loop (processes nodes between FB and FE)
    {state, last_node_ref, bookmark} =
      inner_loop(
        state,
        fe_ref,
        fb_idx,
        fb_ref,
        fb_ref,
        common_ancestor_ref,
        clone_foster_parent_ref,
        af_idx,
        0
      )

    # Insert last_node at common ancestor (foster-aware)
    new_elements = reparent_node_foster_aware(state.elements, last_node_ref, common_ancestor_ref)

    # Create new element for formatting element
    new_fe = new_element(fe_tag, fe_attrs, fb_ref)
    new_elements = Map.put(new_elements, new_fe.ref, new_fe)

    # Move FB's children to new FE
    fb_elem = new_elements[fb_ref]

    new_elements =
      new_elements
      |> Map.update!(new_fe.ref, &%{&1 | children: fb_elem.children})
      |> Map.put(fb_ref, %{fb_elem | children: [new_fe.ref]})
      |> update_children_parent_refs(fb_elem.children, new_fe.ref)

    # Update AF: remove old FE (by ref, not index - inner loop may have changed indices)
    # Then insert new FE at bookmark position
    current_af_idx = Enum.find_index(state.af, fn {ref, _, _} -> ref == fe_ref end)

    adjusted_bookmark =
      if current_af_idx && current_af_idx < bookmark, do: bookmark - 1, else: bookmark

    new_af =
      if current_af_idx do
        state.af
        |> List.delete_at(current_af_idx)
        |> List.insert_at(adjusted_bookmark, {new_fe.ref, fe_tag, fe_attrs})
      else
        # FE was already removed from AF (shouldn't happen normally)
        List.insert_at(state.af, adjusted_bookmark, {new_fe.ref, fe_tag, fe_attrs})
      end

    # Update stack: remove FE, insert new FE below FB
    fe_current_idx = Enum.find_index(state.stack, &(&1 == fe_ref))
    fb_current_idx = Enum.find_index(state.stack, &(&1 == fb_ref))

    new_stack =
      if fe_current_idx do
        state.stack
        |> List.delete_at(fe_current_idx)
        |> List.insert_at(fb_current_idx, new_fe.ref)
      else
        List.insert_at(state.stack, fb_current_idx + 1, new_fe.ref)
      end

    # Update current_parent_ref to new stack top (not element's parent_ref)
    # This handles foster-parented elements correctly
    new_parent_ref =
      case new_stack do
        [top_ref | _] -> top_ref
        [] -> nil
      end

    %{
      state
      | stack: new_stack,
        af: new_af,
        elements: new_elements,
        current_parent_ref: new_parent_ref
    }
  end

  # --------------------------------------------------------------------------
  # Inner loop
  # Per HTML5 spec:
  # 13.4 Increment counter at START of each iteration
  # 13.5 If counter > 3 and node in AF, remove from AF
  # 13.6 If node not in AF, remove from stack and continue
  # 13.7+ Otherwise create new element and reparent
  # --------------------------------------------------------------------------

  defp inner_loop(
         %{stack: stack, af: af, elements: elements} = state,
         fe_ref,
         node_idx,
         last_node_ref,
         fb_ref,
         common_ancestor_ref,
         clone_foster_parent_ref,
         bookmark,
         counter
       ) do
    # 13.4: Increment counter at start of each iteration
    counter = counter + 1
    next_node_idx = node_idx + 1
    node_ref = Enum.at(stack, next_node_idx)

    cond do
      # Reached the formatting element or past it - done
      node_ref == fe_ref or node_ref == nil ->
        {state, last_node_ref, bookmark}

      true ->
        af_entry = find_af_entry_by_ref(af, node_ref)

        # 13.5: If counter > 3 and node in AF, remove from AF
        {af, af_entry} =
          if counter > 3 and af_entry != nil do
            {node_af_idx, _} = af_entry
            {List.delete_at(af, node_af_idx), nil}
          else
            {af, af_entry}
          end

        # 13.6: If node not in AF, remove from stack and continue
        if af_entry == nil do
          new_stack = List.delete_at(stack, next_node_idx)

          inner_loop(
            %{state | stack: new_stack, af: af},
            fe_ref,
            node_idx,
            last_node_ref,
            fb_ref,
            common_ancestor_ref,
            clone_foster_parent_ref,
            bookmark,
            counter
          )
        else
          # 13.7+: Node in AF - create new element, replace in AF, reparent
          {node_af_idx, {_, node_tag, node_attrs}} = af_entry

          new_node = new_element(node_tag, node_attrs, common_ancestor_ref)

          # If we're in a foster-parenting context, mark the clone as foster-parented too
          new_node =
            if clone_foster_parent_ref do
              Map.put(new_node, :foster_parent_ref, clone_foster_parent_ref)
            else
              new_node
            end

          new_elements = Map.put(elements, new_node.ref, new_node)

          new_af = List.replace_at(af, node_af_idx, {new_node.ref, node_tag, node_attrs})
          new_stack = List.replace_at(stack, next_node_idx, new_node.ref)

          new_bookmark = if last_node_ref == fb_ref, do: node_af_idx + 1, else: bookmark

          new_elements = reparent_node(new_elements, last_node_ref, new_node.ref)

          inner_loop(
            %{state | stack: new_stack, af: new_af, elements: new_elements},
            fe_ref,
            next_node_idx,
            new_node.ref,
            fb_ref,
            common_ancestor_ref,
            clone_foster_parent_ref,
            new_bookmark,
            counter
          )
        end
    end
  end

  # --------------------------------------------------------------------------
  # Helper: Find AF entry by ref
  # --------------------------------------------------------------------------

  defp find_af_entry_by_ref(af, target_ref) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{^target_ref, tag, attrs}, idx} -> {idx, {target_ref, tag, attrs}}
      _ -> nil
    end)
  end

  # --------------------------------------------------------------------------
  # Helper: Reparent node
  # --------------------------------------------------------------------------

  defp reparent_node(elements, child_ref, new_parent_ref) do
    child = elements[child_ref]
    old_parent_ref = child.parent_ref

    elements
    |> maybe_remove_from_old_parent(child_ref, old_parent_ref)
    |> Map.update!(child_ref, &%{&1 | parent_ref: new_parent_ref})
    |> Map.update!(new_parent_ref, fn p -> %{p | children: [child_ref | p.children]} end)
  end

  defp reparent_node_foster_aware(elements, child_ref, new_parent_ref) do
    child = elements[child_ref]
    old_parent_ref = child.parent_ref

    elements = maybe_remove_from_old_parent(elements, child_ref, old_parent_ref)
    elements = Map.update!(elements, child_ref, &%{&1 | parent_ref: new_parent_ref})

    parent = elements[new_parent_ref]

    table_ref =
      Enum.find(parent.children, fn
        ref when is_reference(ref) -> elements[ref] && elements[ref].tag == "table"
        _ -> false
      end)

    new_children =
      if table_ref do
        # Foster parenting: insert BEFORE table in DOM order = AFTER in stored list
        # (children are stored in reverse order)
        insert_after_in_list(parent.children, child_ref, table_ref)
      else
        [child_ref | parent.children]
      end

    Map.update!(elements, new_parent_ref, fn p -> %{p | children: new_children} end)
  end

  defp maybe_remove_from_old_parent(elements, _child_ref, nil), do: elements

  defp maybe_remove_from_old_parent(elements, child_ref, old_parent_ref) do
    if Map.has_key?(elements, old_parent_ref) do
      Map.update!(elements, old_parent_ref, fn p ->
        %{p | children: List.delete(p.children, child_ref)}
      end)
    else
      elements
    end
  end

  defp update_children_parent_refs(elements, children, new_parent_ref) do
    Enum.reduce(children, elements, fn
      child_ref, elems when is_reference(child_ref) ->
        Map.update!(elems, child_ref, &%{&1 | parent_ref: new_parent_ref})

      _, elems ->
        elems
    end)
  end

  defp insert_after_in_list(list, new_item, target_item) do
    do_insert_after(list, new_item, target_item, [])
  end

  defp do_insert_after([], new_item, _target, acc) do
    Enum.reverse([new_item | acc])
  end

  defp do_insert_after([target | rest], new_item, target, acc) do
    Enum.reverse(acc) ++ [target, new_item | rest]
  end

  defp do_insert_after([item | rest], new_item, target, acc) do
    do_insert_after(rest, new_item, target, [item | acc])
  end
end
