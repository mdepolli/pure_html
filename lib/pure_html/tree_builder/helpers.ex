defmodule PureHTML.TreeBuilder.Helpers do
  @moduledoc """
  Shared helpers for tree builder insertion modes.

  ## Architecture (Phase 6)

  Stack holds only refs: [ref, ref, ref, ...]
  Elements map holds all data: ref => %{tag, attrs, children, parent_ref}

  Children are added to parent's children list at push time.
  Pop just removes ref from stack and updates current_parent_ref.

  Mode modules import this module to get access to these functions.
  """

  # --------------------------------------------------------------------------
  # Element Creation
  # --------------------------------------------------------------------------

  @doc """
  Creates a new HTML element with the given tag and attributes.
  """
  def new_element(tag, attrs \\ %{}, parent_ref \\ nil) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: [], parent_ref: parent_ref}
  end

  @doc """
  Creates a new foreign (SVG/MathML) element with namespace.
  """
  def new_foreign_element(ns, tag, attrs, parent_ref \\ nil) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: [], parent_ref: parent_ref}
  end

  # --------------------------------------------------------------------------
  # Stack Operations (ref-only stack)
  # --------------------------------------------------------------------------

  @doc """
  Pushes a new element onto the stack.
  - Creates element in elements map
  - Adds element's ref to parent's children (at push time)
  - Pushes ref to stack
  """
  def push_element(
        %{stack: stack, elements: elements, current_parent_ref: parent_ref} = state,
        tag,
        attrs
      ) do
    elem = new_element(tag, attrs, parent_ref)

    # Add to elements map
    new_elements = Map.put(elements, elem.ref, elem)

    # Add ref to parent's children (if parent exists)
    new_elements = add_ref_to_parent_children(new_elements, elem.ref, parent_ref)

    %{state | stack: [elem.ref | stack], elements: new_elements, current_parent_ref: elem.ref}
  end

  @doc """
  Pushes a new foreign element onto the stack.
  """
  def push_foreign_element(
        %{stack: stack, elements: elements, current_parent_ref: parent_ref} = state,
        ns,
        tag,
        attrs
      ) do
    elem = new_foreign_element(ns, tag, attrs, parent_ref)

    # Add to elements map
    new_elements = Map.put(elements, elem.ref, elem)

    # Add ref to parent's children (if parent exists)
    new_elements = add_ref_to_parent_children(new_elements, elem.ref, parent_ref)

    %{state | stack: [elem.ref | stack], elements: new_elements, current_parent_ref: elem.ref}
  end

  @doc """
  Adds a child (text, comment, or tuple element) to the current element.
  Updates children in elements map.
  """
  def add_child_to_stack(%{current_parent_ref: nil} = state, _child), do: state

  def add_child_to_stack(%{current_parent_ref: parent_ref, elements: elements} = state, child) do
    new_elements = add_child_to_elements(elements, parent_ref, child)
    %{state | elements: new_elements}
  end

  @doc """
  Adds text to the current element, merging with previous text if present.
  """
  def add_text_to_stack(%{current_parent_ref: nil} = state, _text), do: state

  def add_text_to_stack(%{current_parent_ref: parent_ref, elements: elements} = state, text) do
    new_elements = add_text_to_elements(elements, parent_ref, text)
    %{state | elements: new_elements}
  end

  # Add child to element's children in elements map
  defp add_child_to_elements(elements, parent_ref, child) do
    Map.update!(elements, parent_ref, fn parent ->
      %{parent | children: [child | parent.children]}
    end)
  end

  # Add text to element's children, merging adjacent text
  defp add_text_to_elements(elements, parent_ref, text) do
    Map.update!(elements, parent_ref, fn
      %{children: [prev_text | rest]} = parent when is_binary(prev_text) ->
        %{parent | children: [prev_text <> text | rest]}

      %{children: children} = parent ->
        %{parent | children: [text | children]}
    end)
  end

  # Add element ref to parent's children in elements map
  defp add_ref_to_parent_children(elements, _ref, nil), do: elements

  defp add_ref_to_parent_children(elements, ref, parent_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      %{parent | children: [ref | parent.children]}
    end)
  end

  # --------------------------------------------------------------------------
  # Legacy Stack Operations (for compatibility during migration)
  # --------------------------------------------------------------------------

  @doc """
  Low-level: adds a child to the first element in the stack.
  LEGACY - used by modes that haven't been migrated yet.
  """
  def add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  def add_child([], child), do: [child]

  @doc """
  Low-level: adds text to the first element in the stack, merging adjacent text.
  LEGACY - used by modes that haven't been migrated yet.
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
  # Stack Queries (ref-only stack + elements map)
  # --------------------------------------------------------------------------

  @doc """
  Returns the tag of the current element (top of stack).
  """
  def current_tag(%{stack: [ref | _], elements: elements}) when is_map_key(elements, ref) do
    elements[ref].tag
  end

  def current_tag(%{stack: [_ | _]}), do: nil
  def current_tag(%{stack: []}), do: nil

  @doc """
  Returns the current element (top of stack).
  """
  def current_element(%{stack: [ref | _], elements: elements}), do: elements[ref]
  def current_element(%{stack: []}), do: nil

  @doc """
  Returns the current element's ref.
  """
  def current_ref(%{stack: [ref | _]}), do: ref
  def current_ref(%{stack: []}), do: nil

  @doc """
  Checks if a tag is in the stack.
  """
  def has_element_in_stack?(%{stack: stack, elements: elements}, tag) do
    Enum.any?(stack, fn ref ->
      is_map_key(elements, ref) and elements[ref].tag == tag
    end)
  end

  @doc """
  Checks if a template element is in the stack.
  """
  def has_template?(%{stack: stack, elements: elements}) do
    Enum.any?(stack, fn ref -> elements[ref].tag == "template" end)
  end

  @doc """
  Gets an element from the elements map by ref.
  """
  def get_element(%{elements: elements}, ref), do: elements[ref]

  @doc """
  Updates an element in the elements map.
  """
  def update_element(%{elements: elements} = state, ref, updates) do
    new_elements = Map.update!(elements, ref, fn elem -> Map.merge(elem, updates) end)
    %{state | elements: new_elements}
  end

  # --------------------------------------------------------------------------
  # Scope Checking (ref-only stack + elements map)
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
  def in_scope?(%{stack: stack, elements: elements}, tag) do
    do_in_scope?(stack, tag, @default_scope_boundaries, elements)
  end

  @doc """
  Checks if an element is in list item scope.
  """
  def in_list_scope?(%{stack: stack, elements: elements}, tag) do
    do_in_scope?(stack, tag, @list_scope_boundaries, elements)
  end

  @doc """
  Checks if an element is in button scope.
  """
  def in_button_scope?(%{stack: stack, elements: elements}, tag) do
    do_in_scope?(stack, tag, @button_scope_boundaries, elements)
  end

  @doc """
  Checks if an element is in table scope.
  """
  def in_table_scope?(%{stack: stack, elements: elements}, tag) do
    do_in_scope?(stack, tag, @table_scope_boundaries, elements)
  end

  @doc """
  Checks if an element is in select scope.
  """
  def in_select_scope?(%{stack: stack, elements: elements}, tag) do
    do_in_scope?(stack, tag, @select_scope_boundaries, elements)
  end

  defp do_in_scope?([], _tag, _boundaries, _elements), do: false

  defp do_in_scope?([ref | rest], tag, boundaries, elements) do
    elem_tag = elements[ref].tag

    cond do
      elem_tag == tag -> true
      elem_tag in boundaries -> false
      true -> do_in_scope?(rest, tag, boundaries, elements)
    end
  end

  # --------------------------------------------------------------------------
  # Pop Operations (ref-only stack)
  # --------------------------------------------------------------------------

  @doc """
  Pops the current element from the stack.
  Just removes ref and updates current_parent_ref.
  Children are already in elements map (added at push time).
  """
  def pop_element(%{stack: [ref | rest], elements: elements} = state) do
    parent_ref = elements[ref].parent_ref
    %{state | stack: rest, current_parent_ref: parent_ref}
  end

  def pop_element(%{stack: []} = state), do: state

  @doc """
  Pops elements from the stack until an element with the given tag is found.
  Returns {:ok, state} if found, {:not_found, state} otherwise.
  """
  def pop_until_tag(%{stack: stack, af: af, elements: elements} = state, tag) do
    case do_pop_until_tag(stack, tag, [], elements) do
      {:found, new_stack, popped_refs, parent_ref} ->
        new_af = reject_refs_from_af(af, popped_refs)
        {:ok, %{state | stack: new_stack, af: new_af, current_parent_ref: parent_ref}}

      :not_found ->
        {:not_found, state}
    end
  end

  defp do_pop_until_tag([], _tag, _popped, _elements), do: :not_found

  defp do_pop_until_tag([ref | rest], tag, popped, elements) do
    elem = elements[ref]

    cond do
      elem.tag == tag ->
        {:found, rest, [ref | popped], elem.parent_ref}

      elem.tag == "template" ->
        :not_found

      true ->
        do_pop_until_tag(rest, tag, [ref | popped], elements)
    end
  end

  @doc """
  Pops elements from the stack until a tag in the given list is at the top.
  """
  def pop_until_one_of(%{stack: stack, af: af, elements: elements} = state, tags)
      when is_list(tags) do
    {new_stack, popped_refs, parent_ref} = do_pop_until_one_of(stack, tags, [], elements)
    new_af = reject_refs_from_af(af, popped_refs)
    %{state | stack: new_stack, af: new_af, current_parent_ref: parent_ref}
  end

  defp do_pop_until_one_of([], _tags, popped, _elements), do: {[], popped, nil}

  defp do_pop_until_one_of([ref | rest] = stack, tags, popped, elements) do
    elem_tag = elements[ref].tag

    if elem_tag in tags do
      {stack, popped, elements[ref].parent_ref}
    else
      do_pop_until_one_of(rest, tags, [ref | popped], elements)
    end
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
    {new_stack, parent_ref} = do_generate_implied_end_tags(stack, elements)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
  end

  @doc """
  Generates implied end tags except for the given tag.
  """
  def generate_implied_end_tags_except(%{stack: stack, elements: elements} = state, except_tag) do
    {new_stack, parent_ref} = do_generate_implied_end_tags_except(stack, except_tag, elements)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
  end

  defp do_generate_implied_end_tags([], _elements), do: {[], nil}

  defp do_generate_implied_end_tags([ref | rest] = stack, elements) do
    elem = elements[ref]

    if elem.tag in @implied_end_tags do
      do_generate_implied_end_tags(rest, elements)
    else
      {stack, elem.parent_ref}
    end
  end

  defp do_generate_implied_end_tags_except([], _except, _elements), do: {[], nil}

  defp do_generate_implied_end_tags_except([ref | rest] = stack, except, elements) do
    elem = elements[ref]

    if elem.tag in @implied_end_tags and elem.tag != except do
      do_generate_implied_end_tags_except(rest, except, elements)
    else
      {stack, elem.parent_ref}
    end
  end

  # --------------------------------------------------------------------------
  # Foster Parenting (ref-only stack)
  # --------------------------------------------------------------------------

  # Tags that trigger foster parenting context
  @foster_parent_context ~w(table tbody thead tfoot tr)

  @doc """
  Determines the appropriate insertion location for a new element.
  """
  def appropriate_insertion_location(%{stack: []} = _state) do
    {:document, nil}
  end

  def appropriate_insertion_location(%{stack: [ref | _], elements: elements} = state) do
    elem = elements[ref]

    if elem.tag in @foster_parent_context do
      find_foster_parent(state)
    else
      {ref, nil}
    end
  end

  @doc """
  Finds the foster parent for foster parenting.
  Returns `{foster_parent_ref, insert_before_ref}`.
  """
  def find_foster_parent(%{stack: stack, elements: elements}) do
    do_find_foster_parent(stack, elements)
  end

  defp do_find_foster_parent([], _elements), do: {:document, nil}

  defp do_find_foster_parent([ref | rest], elements) do
    if elements[ref].tag == "table" do
      case rest do
        [parent_ref | _] -> {parent_ref, nil}
        [] -> {:document, nil}
      end
    else
      do_find_foster_parent(rest, elements)
    end
  end

  @doc """
  Checks if we're currently in a foster parenting context.
  """
  def in_foster_parent_context?(%{stack: [ref | _], elements: elements}) do
    elements[ref].tag in @foster_parent_context
  end

  def in_foster_parent_context?(_state), do: false

  @doc """
  Foster parents an element (adds it to the foster parent's children).
  """
  def foster_element(%{elements: elements} = state, child) do
    {foster_parent_ref, _} = find_foster_parent(state)

    if foster_parent_ref == :document do
      state
    else
      new_elements = add_child_to_elements(elements, foster_parent_ref, child)
      %{state | elements: new_elements}
    end
  end

  @doc """
  Foster parents text (adds it to the foster parent's children).
  """
  def foster_text(%{elements: elements} = state, text) do
    {foster_parent_ref, _} = find_foster_parent(state)

    if foster_parent_ref == :document do
      state
    else
      new_elements = add_text_to_elements(elements, foster_parent_ref, text)
      %{state | elements: new_elements}
    end
  end

  @doc """
  Foster parents an element and pushes it to the stack.
  Returns {state, ref}.
  """
  def foster_push_element(%{stack: stack, elements: elements} = state, tag, attrs) do
    {foster_parent_ref, _} = find_foster_parent(state)

    actual_parent_ref =
      if foster_parent_ref == :document, do: nil, else: foster_parent_ref

    elem = new_element(tag, attrs, actual_parent_ref)
    elem = Map.put(elem, :foster_parent_ref, actual_parent_ref)

    new_elements = Map.put(elements, elem.ref, elem)

    new_elements =
      if actual_parent_ref do
        add_ref_to_parent_children(new_elements, elem.ref, actual_parent_ref)
      else
        new_elements
      end

    {%{state | stack: [elem.ref | stack], elements: new_elements, current_parent_ref: elem.ref},
     elem.ref}
  end

  @doc """
  Foster parents a foreign element and pushes it to the stack.
  Returns state (for self-closing) or {state, ref} (for non-self-closing).
  """
  def foster_push_foreign_element(
        %{stack: stack, elements: elements} = state,
        ns,
        tag,
        attrs,
        self_closing
      ) do
    {foster_parent_ref, _} = find_foster_parent(state)

    actual_parent_ref =
      if foster_parent_ref == :document, do: nil, else: foster_parent_ref

    if self_closing do
      foster_element(state, {{ns, tag}, attrs, []})
    else
      elem = new_foreign_element(ns, tag, attrs, actual_parent_ref)
      elem = Map.put(elem, :foster_parent_ref, actual_parent_ref)

      new_elements = Map.put(elements, elem.ref, elem)

      new_elements =
        if actual_parent_ref do
          add_ref_to_parent_children(new_elements, elem.ref, actual_parent_ref)
        else
          new_elements
        end

      {%{state | stack: [elem.ref | stack], elements: new_elements, current_parent_ref: elem.ref},
       elem.ref}
    end
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
