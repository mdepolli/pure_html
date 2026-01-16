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
  # HTML5 Element Categories
  # --------------------------------------------------------------------------

  # HTML5 "special" category elements - used for scope checking and end tag processing
  @special_elements ~w(
    address applet area article aside base basefont bgsound blockquote body br button
    caption center col colgroup dd details dialog dir div dl dt embed fieldset figcaption
    figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hgroup hr html
    iframe img input keygen li link listing main marquee menu menuitem meta nav
    noembed noframes noscript object ol p param plaintext pre script search section select
    source style summary table tbody td template textarea tfoot th thead title tr
    track ul wbr xmp
  )

  def special_elements, do: @special_elements

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

  # Insert a child before a specific element (for foster parenting)
  defp insert_child_before_in_elements(elements, parent_ref, child, nil) do
    add_child_to_elements(elements, parent_ref, child)
  end

  defp insert_child_before_in_elements(elements, parent_ref, child, insert_before_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      children = insert_after_in_list(parent.children, child, insert_before_ref)
      %{parent | children: children}
    end)
  end

  # Insert text before a specific element (for foster parenting)
  # Merges with adjacent text if possible
  defp insert_text_before_in_elements(elements, parent_ref, text, nil) do
    add_text_to_elements(elements, parent_ref, text)
  end

  defp insert_text_before_in_elements(elements, parent_ref, text, insert_before_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      children = insert_text_after_in_list(parent.children, text, insert_before_ref)
      %{parent | children: children}
    end)
  end

  # Insert text after target in list, merging with adjacent text if possible
  defp insert_text_after_in_list(list, text, target_ref) do
    do_insert_text_after(list, text, target_ref, [])
  end

  defp do_insert_text_after([], text, _target, acc) do
    # Target not found, prepend text to result
    merge_text_at_end(Enum.reverse(acc), text)
  end

  defp do_insert_text_after([target | rest], text, target, acc) do
    # Found target - insert text right after it, merging if next is text
    prefix = Enum.reverse(acc) ++ [target]
    merge_text_at_start(prefix, text, rest)
  end

  defp do_insert_text_after([item | rest], text, target, acc) do
    do_insert_text_after(rest, text, target, [item | acc])
  end

  # Merge text at start of suffix list if first element is text
  defp merge_text_at_start(prefix, text, [next_text | rest]) when is_binary(next_text) do
    prefix ++ [next_text <> text | rest]
  end

  defp merge_text_at_start(prefix, text, rest) do
    prefix ++ [text | rest]
  end

  # Merge text at end of list if last element is text
  defp merge_text_at_end([], text), do: [text]

  defp merge_text_at_end(list, text) do
    {init, [last]} = Enum.split(list, -1)

    if is_binary(last) do
      init ++ [last <> text]
    else
      list ++ [text]
    end
  end

  # Add element ref to parent's children in elements map
  defp add_ref_to_parent_children(elements, _ref, nil), do: elements

  defp add_ref_to_parent_children(elements, ref, parent_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      %{parent | children: [ref | parent.children]}
    end)
  end

  # Insert a child ref before a specific element in the parent's children.
  # Children are stored in reverse order, so "before X" in final output means
  # "after X" in the stored list.
  defp insert_ref_before_in_parent(elements, ref, parent_ref, nil) do
    # No insert_before specified, just prepend
    add_ref_to_parent_children(elements, ref, parent_ref)
  end

  defp insert_ref_before_in_parent(elements, ref, parent_ref, insert_before_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      children = insert_after_in_list(parent.children, ref, insert_before_ref)
      %{parent | children: children}
    end)
  end

  # Insert new_item after target_item in list (because children are reversed)
  defp insert_after_in_list(list, new_item, target_item) do
    do_insert_after(list, new_item, target_item, [])
  end

  defp do_insert_after([], new_item, _target, acc) do
    # Target not found, prepend to result (append to original)
    Enum.reverse([new_item | acc])
  end

  defp do_insert_after([target | rest], new_item, target, acc) do
    # Found target, insert new_item right after it
    Enum.reverse(acc) ++ [target, new_item | rest]
  end

  defp do_insert_after([item | rest], new_item, target, acc) do
    do_insert_after(rest, new_item, target, [item | acc])
  end

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

  @doc """
  Pops the insertion mode from the template mode stack.
  Returns to the previous mode, or :in_body if stack is empty.
  """
  def pop_mode(%{template_mode_stack: [prev_mode | rest]} = state) do
    %{state | mode: prev_mode, template_mode_stack: rest}
  end

  def pop_mode(%{template_mode_stack: []} = state) do
    %{state | mode: :in_body}
  end

  @doc """
  Closes the select element by popping elements until select is found,
  then pops the insertion mode from the template mode stack.
  """
  def close_select(%{stack: stack, elements: elements} = state) do
    {new_stack, parent_ref} = do_close_to_select(stack, elements)
    pop_mode(%{state | stack: new_stack, current_parent_ref: parent_ref})
  end

  defp do_close_to_select([ref | rest], elements) do
    case elements[ref].tag do
      "select" -> {rest, elements[ref].parent_ref}
      _ -> do_close_to_select(rest, elements)
    end
  end

  defp do_close_to_select([], _elements), do: {[], nil}

  @doc """
  Switches the current template insertion mode.
  Replaces the top of template_mode_stack with new_mode (or pushes if empty).
  """
  def switch_template_mode(%{template_mode_stack: [_ | rest]} = state, new_mode) do
    %{state | mode: new_mode, template_mode_stack: [new_mode | rest]}
  end

  def switch_template_mode(%{template_mode_stack: []} = state, new_mode) do
    %{state | mode: new_mode, template_mode_stack: [new_mode]}
  end

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
  Finds the ref of an element with the given tag in the stack.
  Returns the ref or nil if not found.
  """
  def find_ref(%{stack: stack, elements: elements}, tag) do
    Enum.find(stack, fn ref -> elements[ref].tag == tag end)
  end

  # --------------------------------------------------------------------------
  # Scope Checking (ref-only stack + elements map)
  # --------------------------------------------------------------------------

  @scope_boundaries %{
    table: ~w(html table template),
    select: ~w(optgroup option),
    button: ~w(applet caption html table td th marquee object template button)
  }

  @doc """
  Checks if an element with the given tag is in the specified scope.
  Scope types: :table, :select, :button
  """
  def in_scope?(%{stack: stack, elements: elements}, tag, scope_type) do
    do_in_scope?(stack, tag, @scope_boundaries[scope_type], elements)
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

    case elem.tag do
      ^tag -> {:found, rest, [ref | popped], elem.parent_ref}
      "template" -> :not_found
      _ -> do_pop_until_tag(rest, tag, [ref | popped], elements)
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
    if elements[ref].tag in tags do
      {stack, popped, ref}
    else
      do_pop_until_one_of(rest, tags, [ref | popped], elements)
    end
  end

  @doc """
  Removes formatting entries from the active formatting list that have refs in the given set.
  """
  def reject_refs_from_af(af, %MapSet{} = ref_set) do
    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(ref_set, ref)
    end)
  end

  def reject_refs_from_af(af, refs) when is_list(refs) do
    reject_refs_from_af(af, MapSet.new(refs))
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

  Per HTML5 spec:
  1. Let last table be the last table element in the stack
  2. Let last template be the last template element in the stack
  3. If there is a template AND (no table OR template is closer to stack top than table),
     then foster parent is the template element itself (no insert_before)
  4. Otherwise if there is a table, foster parent is table's parent, insert before table
  5. Otherwise foster parent is the first element (html)
  """
  def find_foster_parent(%{stack: stack, elements: elements}) do
    # Find positions of last table and last template (closest to stack top)
    {table_pos, template_pos} = find_table_and_template_positions(stack, elements, 0, nil, nil)

    cond do
      # Template exists and is closer to top than table (or no table)
      template_pos != nil and (table_pos == nil or template_pos < table_pos) ->
        template_ref = Enum.at(stack, template_pos)
        {template_ref, nil}

      # Table exists and is closer to top than template (or no template)
      table_pos != nil ->
        table_ref = Enum.at(stack, table_pos)

        case Enum.at(stack, table_pos + 1) do
          nil -> {:document, nil}
          parent_ref -> {parent_ref, table_ref}
        end

      # Neither table nor template - use first element (html) as foster parent
      true ->
        case List.last(stack) do
          nil -> {:document, nil}
          html_ref -> {html_ref, nil}
        end
    end
  end

  defp find_table_and_template_positions([], _elements, _pos, table_pos, template_pos) do
    {table_pos, template_pos}
  end

  defp find_table_and_template_positions([ref | rest], elements, pos, table_pos, template_pos) do
    tag = elements[ref].tag

    new_table_pos = if tag == "table" and table_pos == nil, do: pos, else: table_pos
    new_template_pos = if tag == "template" and template_pos == nil, do: pos, else: template_pos

    find_table_and_template_positions(rest, elements, pos + 1, new_table_pos, new_template_pos)
  end

  @doc """
  Unified foster parenting function.
  Inserts content before the table element per HTML5 spec.
  Always returns `{state, ref}` where ref is nil for text/element insertions.

  ## Content types:
  - `{:text, text}` - insert text, returns `{state, nil}`
  - `{:element, {tag, attrs, children}}` - insert complete element, returns `{state, nil}`
  - `{:push, tag, attrs}` - create element, push to stack, returns `{state, ref}`
  - `{:push_foreign, ns, tag, attrs, self_closing}` - create foreign element,
     returns `{state, nil}` for self-closing, `{state, ref}` otherwise
  """
  def foster_parent(state, content)

  def foster_parent(state, {:text, text}) do
    new_state =
      with_foster_parent(state, fn elements, parent_ref, insert_before_ref ->
        insert_text_before_in_elements(elements, parent_ref, text, insert_before_ref)
      end)

    {new_state, nil}
  end

  def foster_parent(state, {:element, child}) do
    new_state =
      with_foster_parent(state, fn elements, parent_ref, insert_before_ref ->
        insert_child_before_in_elements(elements, parent_ref, child, insert_before_ref)
      end)

    {new_state, nil}
  end

  def foster_parent(state, {:push, tag, attrs}) do
    foster_push_element(state, new_element(tag, attrs))
  end

  def foster_parent(state, {:push_foreign, ns, tag, attrs, true = _self_closing}) do
    {new_state, _} = foster_parent(state, {:element, {{ns, tag}, attrs, []}})
    {new_state, nil}
  end

  def foster_parent(state, {:push_foreign, ns, tag, attrs, false = _self_closing}) do
    foster_push_element(state, new_foreign_element(ns, tag, attrs))
  end

  # Helper for simple foster parent insertions (text, element)
  defp with_foster_parent(%{elements: elements} = state, insert_fn) do
    case find_foster_parent(state) do
      {:document, _} ->
        state

      {parent_ref, insert_before_ref} ->
        %{state | elements: insert_fn.(elements, parent_ref, insert_before_ref)}
    end
  end

  # Helper for foster parenting that pushes an element to the stack
  defp foster_push_element(%{stack: stack, elements: elements} = state, elem) do
    {foster_parent_ref, insert_before_ref} = find_foster_parent(state)

    actual_parent_ref =
      if foster_parent_ref == :document, do: nil, else: foster_parent_ref

    elem =
      elem
      |> Map.put(:parent_ref, actual_parent_ref)
      |> Map.put(:foster_parent_ref, actual_parent_ref)

    new_elements = Map.put(elements, elem.ref, elem)

    new_elements =
      if actual_parent_ref do
        insert_ref_before_in_parent(new_elements, elem.ref, actual_parent_ref, insert_before_ref)
      else
        new_elements
      end

    {%{state | stack: [elem.ref | stack], elements: new_elements, current_parent_ref: elem.ref},
     elem.ref}
  end

  # --------------------------------------------------------------------------
  # Utility
  # --------------------------------------------------------------------------

  @doc """
  Corrects certain tag names (e.g., "image" -> "img").
  """
  def correct_tag("image"), do: "img"
  def correct_tag(tag), do: tag

  @whitespace_chars [" ", "\t", "\n", "\r", "\f"]

  @doc """
  Extracts only whitespace characters from text.
  Returns the whitespace portion of the string.
  """
  def extract_whitespace(text) do
    text
    |> String.graphemes()
    |> Enum.filter(&(&1 in @whitespace_chars))
    |> Enum.join()
  end

  @doc """
  Splits text into leading whitespace and remaining content.
  Returns {whitespace, rest}.
  """
  def split_whitespace(text) do
    text
    |> String.graphemes()
    |> Enum.split_while(&(&1 in @whitespace_chars))
    |> then(fn {ws, rest} -> {Enum.join(ws), Enum.join(rest)} end)
  end
end
