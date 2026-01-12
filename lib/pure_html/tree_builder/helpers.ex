defmodule PureHTML.TreeBuilder.Helpers do
  @moduledoc """
  Shared helpers for tree builder insertion modes.

  This module provides common operations used across all insertion modes:
  - Element creation
  - Stack operations (push, add_child, add_text)
  - Mode switching
  - Scope checking and element popping

  Mode modules import this module to get access to these functions.
  """

  # --------------------------------------------------------------------------
  # Element Creation
  # --------------------------------------------------------------------------

  @doc """
  Creates a new HTML element with the given tag and attributes.
  Optionally accepts a parent_ref for elements map tracking.
  """
  def new_element(tag, attrs \\ %{}, parent_ref \\ nil) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: [], parent_ref: parent_ref}
  end

  @doc """
  Creates a new foreign (SVG/MathML) element with namespace.
  Optionally accepts a parent_ref for elements map tracking.
  """
  def new_foreign_element(ns, tag, attrs, parent_ref \\ nil) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: [], parent_ref: parent_ref}
  end

  # --------------------------------------------------------------------------
  # Stack Operations
  # --------------------------------------------------------------------------

  @doc """
  Pushes a new element onto the stack.
  Also stores the element in the elements map with parent_ref for O(1) tree building.
  """
  def push_element(
        %{stack: stack, elements: elements, current_parent_ref: parent_ref} = state,
        tag,
        attrs
      ) do
    elem = new_element(tag, attrs, parent_ref)
    new_elements = Map.put(elements, elem.ref, elem)
    %{state | stack: [elem | stack], elements: new_elements, current_parent_ref: elem.ref}
  end

  @doc """
  Pushes a new foreign element onto the stack.
  Also stores the element in the elements map with parent_ref.
  """
  def push_foreign_element(
        %{stack: stack, elements: elements, current_parent_ref: parent_ref} = state,
        ns,
        tag,
        attrs
      ) do
    elem = new_foreign_element(ns, tag, attrs, parent_ref)
    new_elements = Map.put(elements, elem.ref, elem)
    %{state | stack: [elem | stack], elements: new_elements, current_parent_ref: elem.ref}
  end

  @doc """
  Adds a child (element, text, or comment) to the current element.
  """
  def add_child_to_stack(%{stack: stack} = state, child) do
    %{state | stack: add_child(stack, child)}
  end

  @doc """
  Low-level: adds a child to the first element in the stack.
  """
  def add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  def add_child([], child), do: [child]

  @doc """
  Adds text to the current element, merging with previous text if present.
  """
  def add_text_to_stack(%{stack: stack} = state, text) do
    %{state | stack: add_text(stack, text)}
  end

  @doc """
  Low-level: adds text to the first element in the stack, merging adjacent text.
  """
  def add_text([%{children: [prev_text | rest_children]} = parent | rest], text)
      when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  def add_text([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  def add_text([], _text), do: []

  # --------------------------------------------------------------------------
  # Mode Switching
  # --------------------------------------------------------------------------

  @doc """
  Sets the current insertion mode.
  """
  def set_mode(state, mode), do: %{state | mode: mode}

  @doc """
  Sets the frameset-ok flag.
  """
  def set_frameset_ok(state, value), do: %{state | frameset_ok: value}

  # --------------------------------------------------------------------------
  # Active Formatting Elements
  # --------------------------------------------------------------------------

  @doc """
  Pushes a marker onto the active formatting elements list.
  """
  def push_af_marker(%{af: af} = state), do: %{state | af: [:marker | af]}

  @doc """
  Clears active formatting elements up to and including the last marker.
  """
  def clear_af_to_marker(%{af: af} = state) do
    %{state | af: do_clear_af_to_marker(af)}
  end

  defp do_clear_af_to_marker([]), do: []
  defp do_clear_af_to_marker([:marker | rest]), do: rest
  defp do_clear_af_to_marker([_ | rest]), do: do_clear_af_to_marker(rest)

  # --------------------------------------------------------------------------
  # Stack Queries
  # --------------------------------------------------------------------------

  @doc """
  Returns the tag of the current element (top of stack).
  """
  def current_tag([%{tag: tag} | _]), do: tag
  def current_tag([]), do: nil

  @doc """
  Returns the current element (top of stack).
  """
  def current_element([elem | _]), do: elem
  def current_element([]), do: nil

  @doc """
  Checks if a tag is in the stack.
  """
  def has_element_in_stack?(stack, tag) do
    Enum.any?(stack, &match?(%{tag: ^tag}, &1))
  end

  @doc """
  Checks if a template element is in the stack.
  """
  def has_template?(stack) do
    Enum.any?(stack, &match?(%{tag: "template"}, &1))
  end

  # --------------------------------------------------------------------------
  # Scope Checking
  # --------------------------------------------------------------------------

  # Scope boundaries for different scope types
  @default_scope_boundaries ~w(applet caption html marquee object table td template th)
  @list_scope_boundaries @default_scope_boundaries ++ ~w(ol ul)
  @button_scope_boundaries @default_scope_boundaries ++ ["button"]
  @table_scope_boundaries ~w(html table template)
  @select_scope_boundaries ~w(optgroup option)

  @doc """
  Checks if an element is in scope (default scope).
  """
  def in_scope?(stack, tag), do: do_in_scope?(stack, tag, @default_scope_boundaries)

  @doc """
  Checks if an element is in list item scope.
  """
  def in_list_scope?(stack, tag), do: do_in_scope?(stack, tag, @list_scope_boundaries)

  @doc """
  Checks if an element is in button scope.
  """
  def in_button_scope?(stack, tag), do: do_in_scope?(stack, tag, @button_scope_boundaries)

  @doc """
  Checks if an element is in table scope.
  """
  def in_table_scope?(stack, tag), do: do_in_scope?(stack, tag, @table_scope_boundaries)

  @doc """
  Checks if an element is in select scope.
  """
  def in_select_scope?(stack, tag), do: do_in_scope?(stack, tag, @select_scope_boundaries)

  defp do_in_scope?([], _tag, _boundaries), do: false
  defp do_in_scope?([%{tag: tag} | _], tag, _boundaries), do: true

  defp do_in_scope?([%{tag: elem_tag} | rest], tag, boundaries) do
    if elem_tag in boundaries do
      false
    else
      do_in_scope?(rest, tag, boundaries)
    end
  end

  # --------------------------------------------------------------------------
  # Pop Operations
  # --------------------------------------------------------------------------

  @doc """
  Pops the current element from the stack and adds it as a child of the new top.
  Also restores current_parent_ref and updates elements map.
  """
  def pop_element(%{stack: [elem | rest], elements: elements} = state) do
    parent_ref = Map.get(elem, :parent_ref)
    # Update stack (legacy)
    new_stack = add_child(rest, elem)
    # Update elements map - add elem.ref to parent's children
    new_elements = add_ref_to_parent_children(elements, elem.ref, parent_ref)
    %{state | stack: new_stack, elements: new_elements, current_parent_ref: parent_ref}
  end

  def pop_element(%{stack: []} = state), do: state

  @doc """
  Pops elements from the stack until an element with the given tag is found.
  Returns {:ok, state} if found, {:not_found, state} otherwise.
  """
  def pop_until_tag(%{stack: stack, af: af, elements: elements} = state, tag) do
    case do_pop_until_tag(stack, tag, [], elements) do
      {:found, new_stack, popped_refs, new_elements} ->
        new_af = reject_refs_from_af(af, popped_refs)
        {:ok, %{state | stack: new_stack, af: new_af, elements: new_elements}}

      :not_found ->
        {:not_found, state}
    end
  end

  defp do_pop_until_tag([], _tag, _popped, _elements), do: :not_found

  defp do_pop_until_tag([%{tag: tag, ref: ref, parent_ref: parent_ref} = elem | rest], tag, popped, elements) do
    new_elements = add_ref_to_parent_children(elements, ref, parent_ref)
    {:found, add_child(rest, elem), [ref | popped], new_elements}
  end

  defp do_pop_until_tag([%{tag: "template"} | _], _tag, _popped, _elements), do: :not_found

  defp do_pop_until_tag([%{ref: ref, parent_ref: parent_ref} = elem | rest], tag, popped, elements) do
    new_elements = add_ref_to_parent_children(elements, ref, parent_ref)
    do_pop_until_tag(add_child(rest, elem), tag, [ref | popped], new_elements)
  end

  @doc """
  Pops elements from the stack until a tag in the given list is at the top.
  """
  def pop_until_one_of(%{stack: stack, af: af, elements: elements} = state, tags) when is_list(tags) do
    {new_stack, popped_refs, new_elements} = do_pop_until_one_of(stack, tags, [], elements)
    new_af = reject_refs_from_af(af, popped_refs)
    %{state | stack: new_stack, af: new_af, elements: new_elements}
  end

  defp do_pop_until_one_of([], _tags, popped, elements), do: {[], popped, elements}

  defp do_pop_until_one_of([%{tag: tag} | _] = stack, tags, popped, elements) do
    if tag in tags do
      {stack, popped, elements}
    else
      [%{ref: ref, parent_ref: parent_ref} = elem | rest] = stack
      new_elements = add_ref_to_parent_children(elements, ref, parent_ref)
      do_pop_until_one_of(add_child(rest, elem), tags, [ref | popped], new_elements)
    end
  end

  # Add element ref to its parent's children in elements map
  defp add_ref_to_parent_children(elements, _ref, nil), do: elements

  defp add_ref_to_parent_children(elements, ref, parent_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      %{parent | children: [ref | parent.children]}
    end)
  end

  defp reject_refs_from_af(af, refs) do
    ref_set = MapSet.new(refs)

    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(ref_set, ref)
    end)
  end

  # --------------------------------------------------------------------------
  # Implied End Tags
  # --------------------------------------------------------------------------

  @implied_end_tags ~w(dd dt li optgroup option p rb rp rt rtc)

  @doc """
  Generates implied end tags (pops elements with implied end tags).
  """
  def generate_implied_end_tags(%{stack: stack, elements: elements} = state) do
    {new_stack, new_elements} = do_generate_implied_end_tags(stack, elements)
    %{state | stack: new_stack, elements: new_elements}
  end

  @doc """
  Generates implied end tags except for the given tag.
  """
  def generate_implied_end_tags_except(%{stack: stack, elements: elements} = state, except_tag) do
    {new_stack, new_elements} = do_generate_implied_end_tags_except(stack, except_tag, elements)
    %{state | stack: new_stack, elements: new_elements}
  end

  defp do_generate_implied_end_tags([%{tag: tag, ref: ref, parent_ref: parent_ref} = elem | rest], elements)
       when tag in @implied_end_tags do
    new_elements = add_ref_to_parent_children(elements, ref, parent_ref)
    do_generate_implied_end_tags(add_child(rest, elem), new_elements)
  end

  defp do_generate_implied_end_tags(stack, elements), do: {stack, elements}

  defp do_generate_implied_end_tags_except([%{tag: tag, ref: ref, parent_ref: parent_ref} = elem | rest], except, elements)
       when tag in @implied_end_tags and tag != except do
    new_elements = add_ref_to_parent_children(elements, ref, parent_ref)
    do_generate_implied_end_tags_except(add_child(rest, elem), except, new_elements)
  end

  defp do_generate_implied_end_tags_except(stack, _except, elements), do: {stack, elements}

  # --------------------------------------------------------------------------
  # Foster Parenting
  # --------------------------------------------------------------------------

  # Tags that trigger foster parenting context
  @foster_parent_context ~w(table tbody thead tfoot tr)

  @doc """
  Determines the appropriate insertion location for a new element.

  Returns `{parent_ref, insert_before_ref}` where:
  - `parent_ref` is the element ref where the child should be inserted
  - `insert_before_ref` is the ref of the element to insert before (nil for append)

  In normal cases, returns `{current_element_ref, nil}`.
  In foster parenting context (inside table structure), returns the foster parent
  (typically body) with insertion point before the table.
  """
  def appropriate_insertion_location(%{stack: []} = _state) do
    {:document, nil}
  end

  def appropriate_insertion_location(%{stack: [%{tag: tag, ref: current_ref} | _]} = state)
      when tag in @foster_parent_context do
    # We're in a foster parenting context - find the appropriate foster parent
    find_foster_parent(state, current_ref)
  end

  def appropriate_insertion_location(%{stack: [%{ref: current_ref} | _]}) do
    # Normal case - insert as child of current element
    {current_ref, nil}
  end

  @doc """
  Finds the foster parent for foster parenting.
  Returns `{foster_parent_ref, insert_before_ref}`.
  """
  def find_foster_parent(%{stack: stack}, _current_ref) do
    do_find_foster_parent(stack)
  end

  defp do_find_foster_parent([%{tag: "table"} = _table, %{ref: parent_ref} | _]) do
    # Found table - foster parent is table's parent, insert before table
    # Note: insert_before_ref would be table.ref, but we use nil for "append"
    # since the current stack-based approach appends to children
    {parent_ref, nil}
  end

  defp do_find_foster_parent([%{tag: "table"} = _table]) do
    # Table with no parent - insert at document level
    {:document, nil}
  end

  defp do_find_foster_parent([_ | rest]) do
    do_find_foster_parent(rest)
  end

  defp do_find_foster_parent([]) do
    # No table found - shouldn't happen in valid foster parenting context
    {:document, nil}
  end

  @doc """
  Checks if we're currently in a foster parenting context.
  """
  def in_foster_parent_context?(%{stack: [%{tag: tag} | _]}) when tag in @foster_parent_context,
    do: true

  def in_foster_parent_context?(_state), do: false

  @doc """
  Foster parents an element (adds it before the table in the table's parent).
  This is the stack-manipulation version for the current architecture.
  """
  def foster_element(%{stack: stack} = state, element) do
    %{state | stack: do_foster_element(stack, element, [])}
  end

  defp do_foster_element([%{tag: "table"} = table | rest], element, acc) do
    # Insert element as child of table's parent
    rest = add_child(rest, element)
    rebuild_stack(acc, [table | rest])
  end

  defp do_foster_element([current | rest], element, acc) do
    do_foster_element(rest, element, [current | acc])
  end

  defp do_foster_element([], _element, acc) do
    Enum.reverse(acc)
  end

  @doc """
  Foster parents text (adds it before the table in the table's parent).
  """
  def foster_text(%{stack: stack} = state, text) do
    %{state | stack: do_foster_text(stack, text, [])}
  end

  defp do_foster_text([%{tag: "table"} = table | rest], text, acc) do
    rest = add_text(rest, text)
    rebuild_stack(acc, [table | rest])
  end

  defp do_foster_text([current | rest], text, acc) do
    do_foster_text(rest, text, [current | acc])
  end

  defp do_foster_text([], _text, acc) do
    Enum.reverse(acc)
  end

  @doc """
  Foster parents an element and pushes it to the stack.

  This is for elements that need to be foster-parented (inserted before the table)
  but also need to be on the stack to receive children.

  The element's parent_ref is set to the foster parent (table's parent) for correct
  DOM structure, and current_parent_ref is updated to this element since it will
  receive children.

  Returns {state, ref} where ref is the new element's reference.
  """
  def foster_push_element(%{stack: stack, elements: elements} = state, tag, attrs) do
    # Find the foster parent ref (table's parent)
    foster_parent_ref = find_foster_parent_ref(stack)
    # Create element with foster parent as its parent_ref
    elem = new_element(tag, attrs, foster_parent_ref)
    {new_stack, ref} = do_foster_push(stack, elem, [])
    # Store in elements map and update current_parent_ref
    new_elements = Map.put(elements, elem.ref, elem)
    {%{state | stack: new_stack, elements: new_elements, current_parent_ref: elem.ref}, ref}
  end

  @doc """
  Foster parents a foreign element and pushes it to the stack.

  For self-closing elements, adds as a child without pushing to stack.
  For non-self-closing, pushes to stack to receive children.

  Returns state (for self-closing) or {state, ref} (for non-self-closing).
  """
  def foster_push_foreign_element(
        %{stack: stack, elements: elements} = state,
        ns,
        tag,
        attrs,
        self_closing
      ) do
    if self_closing do
      # Self-closing: add as child before table, don't push to stack
      foster_element(state, {{ns, tag}, attrs, []})
    else
      # Find the foster parent ref (table's parent)
      foster_parent_ref = find_foster_parent_ref(stack)
      # Create element with foster parent as its parent_ref
      elem = new_foreign_element(ns, tag, attrs, foster_parent_ref)
      new_stack = do_foster_push_only(stack, elem, [])
      # Store in elements map and update current_parent_ref
      new_elements = Map.put(elements, elem.ref, elem)

      {%{state | stack: new_stack, elements: new_elements, current_parent_ref: elem.ref},
       elem.ref}
    end
  end

  # Find the ref of the table's parent (the foster parent)
  defp find_foster_parent_ref(stack) do
    do_find_foster_parent_ref(stack)
  end

  defp do_find_foster_parent_ref([%{tag: "table"}, %{ref: parent_ref} | _]), do: parent_ref
  defp do_find_foster_parent_ref([%{tag: "table"}]), do: nil
  defp do_find_foster_parent_ref([_ | rest]), do: do_find_foster_parent_ref(rest)
  defp do_find_foster_parent_ref([]), do: nil

  defp do_foster_push([%{tag: "table"} = table | rest], elem, acc) do
    # Mark element with foster parent ref (for legacy finalization)
    [foster_parent | _] = rest
    marked_elem = Map.put(elem, :foster_parent_ref, foster_parent.ref)
    # Push marked element on top of rebuilt stack
    {[marked_elem | rebuild_stack(acc, [table | rest])], elem.ref}
  end

  defp do_foster_push([current | rest], elem, acc) do
    do_foster_push(rest, elem, [current | acc])
  end

  defp do_foster_push([], elem, acc) do
    {[elem | Enum.reverse(acc)], elem.ref}
  end

  defp do_foster_push_only([%{tag: "table"} = table | rest], elem, acc) do
    # Mark element with foster parent ref (for legacy finalization)
    [foster_parent | _] = rest
    marked_elem = Map.put(elem, :foster_parent_ref, foster_parent.ref)
    # Push marked element on top of rebuilt stack
    [marked_elem | rebuild_stack(acc, [table | rest])]
  end

  defp do_foster_push_only([current | rest], elem, acc) do
    do_foster_push_only(rest, elem, [current | acc])
  end

  defp do_foster_push_only([], elem, acc) do
    [elem | Enum.reverse(acc)]
  end

  # --------------------------------------------------------------------------
  # Utility
  # --------------------------------------------------------------------------

  @doc """
  Rebuilds a stack by reversing an accumulator onto it.
  """
  def rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)

  @doc """
  Corrects certain tag names (e.g., "image" -> "img").
  """
  def correct_tag("image"), do: "img"
  def correct_tag(tag), do: tag
end
