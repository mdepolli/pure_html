defmodule PureHTML.TreeBuilder.AdoptionAgency do
  @moduledoc """
  The adoption agency algorithm, run for a formatting element end tag (and by
  the `a` and `nobr` start tag entries), one function per step of the text.

  See: https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm
  """

  import PureHTML.TreeBuilder.Helpers

  @doc """
  Runs the algorithm for `subject`, the token's tag name. When the list of
  active formatting elements has no entry for the subject, the token is
  handled by `any_other_end_tag` instead: "act as described in the 'any other
  end tag' entry above and return".
  """
  def run(state, subject, any_other_end_tag) do
    state
    |> current_tag()
    |> start(subject, state, any_other_end_tag)
  end

  # Step 2: the current node has the subject's tag name and is not in the list
  # of active formatting elements: pop it and return.
  defp start(subject, subject, %{stack: [ref | _], af: af} = state, any_other_end_tag) do
    if af_entry(af, ref) do
      outer_loop(state, subject, any_other_end_tag, 1)
    else
      pop_element(state)
    end
  end

  defp start(_current, subject, state, any_other_end_tag) do
    outer_loop(state, subject, any_other_end_tag, 1)
  end

  # Steps 4.1 and 4.2: at most eight iterations
  defp outer_loop(state, _subject, _any_other_end_tag, counter) when counter > 8, do: state

  defp outer_loop(%{af: af} = state, subject, any_other_end_tag, counter) do
    af
    |> formatting_element(subject)
    |> adopt(state, subject, any_other_end_tag, counter)
  end

  # Step 4.3: the last entry with the subject's tag name after the last marker
  defp formatting_element(af, subject) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.find(&match?({_ref, ^subject, _attrs}, &1))
  end

  # Step 4.3: no such element
  defp adopt(nil, state, subject, any_other_end_tag, _counter) do
    any_other_end_tag.(state, subject)
  end

  defp adopt({fe_ref, _tag, _attrs} = entry, %{stack: stack} = state, subject, any, counter) do
    cond do
      # Step 4.4: not in the stack of open elements
      fe_ref not in stack ->
        state
        |> parse_error()
        |> remove_af_entry(fe_ref)

      # Step 4.5: in the stack, but not in scope
      not node_in_scope?(state, fe_ref) ->
        parse_error(state)

      true ->
        state
        |> parse_error_unless_current_ref(fe_ref)
        |> adopt_in_scope(entry, subject, any, counter)
    end
  end

  # Step 4.6: "If formattingElement is not the current node, this is a parse
  # error. (But do not return.)"
  defp parse_error_unless_current_ref(%{stack: [ref | _]} = state, ref), do: state
  defp parse_error_unless_current_ref(state, _fe_ref), do: parse_error(state)

  defp adopt_in_scope(state, {fe_ref, _tag, _attrs} = entry, subject, any_other_end_tag, counter) do
    state
    |> furthest_block(fe_ref)
    |> adopt_with(entry, state, subject, any_other_end_tag, counter)
  end

  # Step 4.7: the special element nearest the formatting element among those
  # pushed after it (the stack is stored current node first)
  defp furthest_block(%{stack: stack, elements: elements}, fe_ref) do
    stack
    |> Enum.take_while(&(&1 != fe_ref))
    |> Enum.reverse()
    |> Enum.find(&special_element?(elements[&1].tag))
  end

  # Step 4.8: no furthest block
  defp adopt_with(nil, {fe_ref, _tag, _attrs}, state, _subject, _any, _counter) do
    state
    |> pop_through_ref(fe_ref)
    |> remove_af_entry(fe_ref)
  end

  # Steps 4.9 to 4.19, then the next iteration
  defp adopt_with(fb_ref, entry, state, subject, any_other_end_tag, counter) do
    state
    |> reparent_misnested(entry, fb_ref)
    |> outer_loop(subject, any_other_end_tag, counter + 1)
  end

  defp reparent_misnested(%{stack: stack} = state, {fe_ref, tag, attrs}, fb_ref) do
    # Step 4.9: the element immediately above the formatting element
    common_ancestor = element_above(stack, fe_ref)
    # Step 4.10: the bookmark starts at the formatting element's position
    # Steps 4.11 to 4.13: node and lastNode start at the furthest block
    {state, last_node, bookmark} =
      stack
      |> nodes_between(fb_ref, fe_ref)
      |> inner_loop({state, fb_ref, {:at, fe_ref}}, fb_ref, 1)

    state
    |> move_node_to_appropriate_place(last_node, common_ancestor)
    |> replace_formatting_element(fe_ref, tag, attrs, fb_ref, bookmark)
  end

  defp element_above(stack, ref) do
    stack
    |> Enum.drop_while(&(&1 != ref))
    |> Enum.at(1)
  end

  # The nodes above the furthest block up to (excluding) the formatting element
  defp nodes_between(stack, fb_ref, fe_ref) do
    stack
    |> Enum.drop_while(&(&1 != fb_ref))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != fe_ref))
  end

  # Step 4.13: walk from the furthest block up to the formatting element. The
  # progress is `{state, lastNode, bookmark}`.
  defp inner_loop([], progress, _fb_ref, _counter), do: progress

  defp inner_loop([node | rest], {%{af: af} = state, last_node, bookmark}, fb_ref, counter) do
    af
    |> af_entry(node)
    |> inner_step(node, counter, {state, last_node, bookmark}, fb_ref)
    |> inner_loop_rest(rest, fb_ref, counter + 1)
  end

  defp inner_loop_rest(progress, rest, fb_ref, counter),
    do: inner_loop(rest, progress, fb_ref, counter)

  # Step 4.13.4: past three iterations the node's entry is removed from the
  # list, so the node is then not in the list (step 4.13.5)
  defp inner_step({_, _, _}, node, counter, {state, last_node, bookmark}, _fb_ref)
       when counter > 3 do
    state
    |> remove_af_entry(node)
    |> remove_from_stack(node)
    |> with_progress(last_node, bookmark)
  end

  # Step 4.13.5: not in the list: remove from the stack and continue
  defp inner_step(nil, node, _counter, {state, last_node, bookmark}, _fb_ref) do
    state
    |> remove_from_stack(node)
    |> with_progress(last_node, bookmark)
  end

  # Steps 4.13.6 to 4.13.9: a new element for the node's token replaces the
  # node in the list and the stack; the bookmark moves after it when lastNode
  # is the furthest block; lastNode is appended to it and becomes it.
  defp inner_step({_, tag, attrs}, node, _counter, {state, last_node, bookmark}, fb_ref) do
    new = new_element(tag, attrs)

    state
    |> put_element(new)
    |> replace_af_entry(node, {new.ref, tag, attrs})
    |> replace_in_stack(node, new.ref)
    |> reparent(last_node, new.ref)
    |> with_progress(new.ref, move_bookmark(bookmark, last_node, fb_ref, new.ref))
  end

  defp with_progress(state, last_node, bookmark), do: {state, last_node, bookmark}

  defp move_bookmark(_bookmark, fb_ref, fb_ref, new_ref), do: {:after, new_ref}
  defp move_bookmark(bookmark, _last_node, _fb_ref, _new_ref), do: bookmark

  # Steps 4.15 to 4.19: a new element for the formatting element's token takes
  # the furthest block's children and becomes its only child; it replaces the
  # formatting element in the list (at the bookmark) and in the stack
  # (immediately below the furthest block).
  defp replace_formatting_element(
         %{elements: elements} = state,
         fe_ref,
         tag,
         attrs,
         fb_ref,
         bookmark
       ) do
    new = new_element(tag, attrs, fb_ref)
    fb = elements[fb_ref]

    elements =
      elements
      |> Map.put(new.ref, %{new | children: fb.children})
      |> reparent_children(fb.children, new.ref)
      |> Map.put(fb_ref, %{fb | children: [new.ref]})

    %{state | elements: elements}
    |> place_af_entry(fe_ref, {new.ref, tag, attrs}, bookmark)
    |> replace_in_stack_below(fe_ref, new.ref, fb_ref)
  end

  # --------------------------------------------------------------------------
  # List of active formatting elements
  # --------------------------------------------------------------------------

  defp af_entry(af, ref), do: Enum.find(af, &match?({^ref, _, _}, &1))

  defp remove_af_entry(%{af: af} = state, ref) do
    %{state | af: Enum.reject(af, &match?({^ref, _, _}, &1))}
  end

  defp replace_af_entry(%{af: af} = state, ref, entry) do
    %{state | af: update_af_entry(af, ref, entry)}
  end

  # The bookmark is either the formatting element's own position or the
  # position immediately after another entry. The list head is its end, so
  # "after" an entry is the index before it.
  defp place_af_entry(state, fe_ref, entry, {:at, fe_ref}),
    do: replace_af_entry(state, fe_ref, entry)

  defp place_af_entry(%{af: af} = state, fe_ref, entry, {:after, ref}) do
    af = Enum.reject(af, &match?({^fe_ref, _, _}, &1))
    index = Enum.find_index(af, &match?({^ref, _, _}, &1))
    %{state | af: List.insert_at(af, index, entry)}
  end

  # --------------------------------------------------------------------------
  # Stack of open elements
  # --------------------------------------------------------------------------

  defp remove_from_stack(%{stack: stack} = state, ref),
    do: %{state | stack: List.delete(stack, ref)}

  defp replace_in_stack(%{stack: stack} = state, old_ref, new_ref) do
    %{state | stack: Enum.map(stack, &if(&1 == old_ref, do: new_ref, else: &1))}
  end

  # "Immediately below the position of furthestBlock": the stack is stored
  # current node first, so the new element goes in front of the furthest block.
  defp replace_in_stack_below(%{stack: stack} = state, fe_ref, new_ref, fb_ref) do
    stack = List.delete(stack, fe_ref)
    index = Enum.find_index(stack, &(&1 == fb_ref))
    %{state | stack: List.insert_at(stack, index, new_ref)}
  end

  # --------------------------------------------------------------------------
  # Elements
  # --------------------------------------------------------------------------

  defp put_element(%{elements: elements} = state, elem) do
    %{state | elements: Map.put(elements, elem.ref, elem)}
  end

  # Append `child_ref` to `parent_ref`, removing it from its current parent
  defp reparent(%{elements: elements} = state, child_ref, parent_ref) do
    elements =
      elements
      |> detach_child(child_ref)
      |> attach_child(child_ref, parent_ref)

    %{state | elements: elements}
  end

  defp reparent_children(elements, children, parent_ref) do
    Enum.reduce(children, elements, fn
      ref, acc when is_reference(ref) -> Map.update!(acc, ref, &%{&1 | parent_ref: parent_ref})
      _text_or_comment, acc -> acc
    end)
  end

  defp detach_child(elements, child_ref) do
    case elements[child_ref].parent_ref do
      nil ->
        elements

      parent_ref ->
        elements
        |> Map.update!(parent_ref, &%{&1 | children: List.delete(&1.children, child_ref)})
        |> Map.update!(child_ref, &%{&1 | parent_ref: nil})
    end
  end

  # Children are stored last first, so prepending appends in document order
  defp attach_child(elements, child_ref, parent_ref) do
    elements
    |> Map.update!(child_ref, &%{&1 | parent_ref: parent_ref})
    |> Map.update!(parent_ref, &%{&1 | children: [child_ref | &1.children]})
  end
end
