defmodule PureHTML.TreeBuilder.Helpers do
  @moduledoc """
  Shared helpers for the tree builder's insertion modes.

  The stack of open elements holds refs; the elements map holds the data
  (`ref => %{tag, attrs, children, parent_ref}`). A child joins its parent's
  children at push time, and popping only removes the ref: the stack top is
  the insertion parent.

  The modes import this module whole. Delegations between modes ("process the
  token using the rules for ...") are plain calls that leave the insertion mode
  to the rules invoked.
  """

  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Modes.InHead
  alias PureHTML.TreeBuilder.Modes.InTable

  # --------------------------------------------------------------------------
  # HTML5 Element Categories
  # --------------------------------------------------------------------------

  # HTML5 "special" category elements - used for scope checking and end tag processing
  @special_elements ~w(
    address applet area article aside base basefont bgsound blockquote body br button
    caption center col colgroup dd details dialog dir div dl dt embed fieldset figcaption
    figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hgroup hr html
    iframe img input keygen li link listing main marquee menu meta nav
    noembed noframes noscript object ol p param plaintext pre script search section select
    source style summary table tbody td template textarea tfoot th thead title tr
    track ul wbr xmp
  )

  def special_elements, do: @special_elements

  @svg_special ~w(desc foreignobject title)
  @mathml_special ~w(annotation-xml mi mn mo ms mtext)

  @doc "Whether an element with this tag is in the special category."
  def special_element?(tag) when is_binary(tag), do: tag in @special_elements
  def special_element?({:svg, tag}), do: String.downcase(tag) in @svg_special
  def special_element?({:math, tag}), do: tag in @mathml_special
  def special_element?(_), do: false

  # Tags that trigger foster parenting context
  @foster_parent_tags ~w(table tbody thead tfoot tr)

  @doc false
  def parse_error(state, count \\ 1)

  def parse_error(%{error_count: n} = state, count) when is_integer(count) and count >= 0 do
    %{state | error_count: n + count}
  end

  @doc false
  def ok(state), do: {:ok, state}

  @doc false
  def reprocess(state), do: {:reprocess, state}

  @doc false
  def reprocess_with(state, token), do: {:reprocess_with, state, token}

  # --------------------------------------------------------------------------
  # Element Creation
  # --------------------------------------------------------------------------

  @doc """
  Creates a new HTML element with the given tag and attributes.
  """
  def new_element(tag, attrs \\ [], parent_ref \\ nil) do
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
  def push_element(%{foster_parenting: true} = state, tag, attrs) do
    # Foster parenting enabled - use foster_parent only if current element is table-related
    if needs_foster_parenting?(state) do
      {new_state, _ref} = foster_parent(state, {:push, tag, attrs})
      new_state
    else
      # Already inside a foster-parented element, insert normally
      do_push_element(state, tag, attrs)
    end
  end

  def push_element(state, tag, attrs), do: do_push_element(state, tag, attrs)

  defp do_push_element(%{stack: stack, elements: elements} = state, tag, attrs) do
    parent_ref = List.first(stack)
    elem = new_element(tag, attrs, parent_ref)

    # Add to elements map
    new_elements = Map.put(elements, elem.ref, elem)

    # Add ref to parent's children (if parent exists)
    new_elements = add_ref_to_parent_children(new_elements, elem.ref, parent_ref)

    %{state | stack: [elem.ref | stack], elements: new_elements}
  end

  @doc """
  Pushes a new foreign element onto the stack.
  """
  def push_foreign_element(%{foster_parenting: true} = state, ns, tag, attrs) do
    if needs_foster_parenting?(state) do
      foster_insert(state, {:push_foreign, ns, tag, attrs, false})
    else
      do_push_foreign_element(state, ns, tag, attrs)
    end
  end

  def push_foreign_element(state, ns, tag, attrs),
    do: do_push_foreign_element(state, ns, tag, attrs)

  defp do_push_foreign_element(%{stack: stack, elements: elements} = state, ns, tag, attrs) do
    parent_ref = List.first(stack)
    elem = new_foreign_element(ns, tag, attrs, parent_ref)

    # Add to elements map
    new_elements = Map.put(elements, elem.ref, elem)

    # Add ref to parent's children (if parent exists)
    new_elements = add_ref_to_parent_children(new_elements, elem.ref, parent_ref)

    %{state | stack: [elem.ref | stack], elements: new_elements}
  end

  @doc """
  Adds a child (text, comment, or tuple element) to the current element.
  Updates children in elements map.
  """
  def add_child_to_stack(%{stack: []} = state, _child), do: state

  def add_child_to_stack(%{foster_parenting: true} = state, child) do
    # Foster parenting enabled - use foster_parent only if current element is table-related
    if needs_foster_parenting?(state) do
      {new_state, _} = foster_parent(state, {:element, child})
      new_state
    else
      do_add_child_to_stack(state, child)
    end
  end

  def add_child_to_stack(state, child), do: do_add_child_to_stack(state, child)

  defp do_add_child_to_stack(%{stack: [parent_ref | _], elements: elements} = state, child) do
    new_elements = add_child_to_elements(elements, parent_ref, child)
    %{state | elements: new_elements}
  end

  @doc """
  Adds text to the current element, merging with previous text if present.
  """
  def add_text_to_stack(%{stack: []} = state, _text), do: state

  def add_text_to_stack(%{foster_parenting: true} = state, text) do
    # Foster parenting enabled - use foster_parent only if current element is table-related
    if needs_foster_parenting?(state) do
      {new_state, _} = foster_parent(state, {:text, text})
      new_state
    else
      do_add_text_to_stack(state, text)
    end
  end

  def add_text_to_stack(state, text), do: do_add_text_to_stack(state, text)

  defp do_add_text_to_stack(%{stack: [parent_ref | _], elements: elements} = state, text) do
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

  @doc false
  # Insert new_item after target_item in list (because children are reversed)
  def insert_after_in_list(list, new_item, target_item) do
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
  Enables foster parenting for the token being processed. The tree builder
  disables it again once the token (and any reprocessing) is done.
  """
  def enable_foster_parenting(state), do: %{state | foster_parenting: true}

  @doc """
  Disables foster parenting. Called by the tree builder after each token.
  """
  def disable_foster_parenting(state), do: %{state | foster_parenting: false}

  @doc """
  Processes the token with the "in body" rules from inside a state pipe.
  """
  def process_in_body(state, token), do: InBody.process(token, state)

  @doc """
  Processes a head element start tag with the "in head" rules on behalf of a
  mode that inserts it where it stands (in body, in template): the token is
  consumed there, never reprocessed.
  """
  def process_in_head(state, token) do
    {:ok, state} = InHead.process(token, state)
    state
  end

  @doc """
  Generic raw text and RCDATA element parsing, after the element is inserted:
  switch the tokenizer, keep the current insertion mode as the original one,
  then switch to "text".
  """
  def enter_text_mode(%{mode: mode} = state, tokenizer_state) do
    state
    |> switch_tokenizer(tokenizer_state)
    |> Map.put(:original_mode, mode)
    |> set_mode(:text)
  end

  @doc """
  Asks the tree builder to switch the tokenizer to `tokenizer_state` before
  the next token.
  """
  def switch_tokenizer(state, tokenizer_state), do: %{state | tokenizer_state: tokenizer_state}

  @doc """
  Processes the token with the "in table" rules (in table body, in row): a
  delegation for one token that leaves the insertion mode to those rules.
  """
  def process_in_table(state, token), do: InTable.process(token, state)

  # Tags that are implicitly closed (popped) when generating implied end tags
  @implied_end_tag_tags ~w(dd dt li optgroup option p rb rp rt rtc)

  # Tags for "generate implied end tags thoroughly" (used at EOF)
  @implied_end_tag_tags_thorough ~w(
    caption colgroup dd dt li optgroup option p rb rp rt rtc
    tbody td tfoot th thead tr
  )

  @doc """
  Generates implied end tags per the HTML5 spec.
  """
  def generate_implied_end_tags(state) do
    pop_implied_end_tags(state, @implied_end_tag_tags, nil)
  end

  @doc """
  Generates implied end tags, except for elements with the given tag name.
  """
  def generate_implied_end_tags_except(state, except_tag) do
    pop_implied_end_tags(state, @implied_end_tag_tags, except_tag)
  end

  @doc """
  Generates implied end tags thoroughly (used at EOF per spec).
  """
  def generate_implied_end_tags_thoroughly(state) do
    pop_implied_end_tags(state, @implied_end_tag_tags_thorough, nil)
  end

  defp pop_implied_end_tags(%{stack: [ref | rest], elements: elements} = state, tags, except)
       when is_map_key(elements, ref) do
    tag = elements[ref].tag

    if is_binary(tag) and tag != except and tag in tags do
      pop_implied_end_tags(%{state | stack: rest}, tags, except)
    else
      state
    end
  end

  defp pop_implied_end_tags(state, _tags, _except), do: state

  @doc """
  Sets the frameset-ok flag.
  """
  def set_frameset_ok(state, value), do: %{state | frameset_ok: value}

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

  def set_frameset_not_ok(state), do: %{state | frameset_ok: false}

  @doc """
  Clears active formatting elements up to and including the last marker.
  """
  def clear_af_to_marker(%{af: af} = state) do
    %{state | af: do_clear_af_to_marker(af)}
  end

  defp do_clear_af_to_marker([]), do: []
  defp do_clear_af_to_marker([:marker | rest]), do: rest
  defp do_clear_af_to_marker([_ | rest]), do: do_clear_af_to_marker(rest)

  @doc """
  Updates an entry in the active formatting elements list by ref.
  """
  def update_af_entry(af, old_ref, new_entry) do
    Enum.map(af, fn
      {^old_ref, _, _} -> new_entry
      entry -> entry
    end)
  end

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
    default: ~w(applet caption html table td th marquee object select template),
    list_item: ~w(applet caption html table td th marquee object select template ol ul),
    table: ~w(html table template),
    button: ~w(applet caption html table td th marquee object select template button)
  }

  # Foreign scope boundaries per HTML5 spec (MathML tags are lowercase)
  @mathml_scope_boundaries ~w(annotation-xml mi mn mo ms mtext)

  # Scope types that include foreign elements as boundaries per HTML5 spec
  @scopes_with_foreign_boundaries [:default, :button, :list_item]

  @doc """
  Checks if an element with the given tag (or any tag in a list) is in the
  specified scope. Scope types: :default, :table, :button
  """
  def in_scope?(%{stack: stack} = state, tag, scope_type) do
    do_in_scope?(stack, tag, scope_type, state)
  end

  @doc """
  Checks if the element with the given ref is in the default scope, per the
  spec's "the stack of open elements does not have node in scope".
  """
  def node_in_scope?(%{stack: stack} = state, ref) do
    do_in_scope?(stack, ref, :default, state)
  end

  # Per spec the walk covers the stack of open elements only; the fragment
  # context element is not on the stack and is never in scope.
  defp do_in_scope?([], _target, _scope_type, _state), do: false

  defp do_in_scope?([ref | rest], target, scope_type, %{elements: elements} = state) do
    elem_tag = elements[ref].tag

    cond do
      scope_node_match?(ref, elem_tag, target) -> true
      scope_boundary?(elem_tag, scope_type) -> false
      true -> do_in_scope?(rest, target, scope_type, state)
    end
  end

  # The target is a tag, a list of tags, or a specific element ref
  defp scope_node_match?(ref, _elem_tag, target) when is_reference(target), do: ref == target
  defp scope_node_match?(_ref, elem_tag, tags) when is_list(tags), do: elem_tag in tags
  defp scope_node_match?(_ref, elem_tag, tag), do: elem_tag == tag

  defp scope_boundary?(elem_tag, scope_type) do
    elem_tag in @scope_boundaries[scope_type] or
      (scope_type in @scopes_with_foreign_boundaries and foreign_scope_boundary?(elem_tag))
  end

  # Check if a tag is a foreign scope boundary (for default/button scope)
  # SVG: compare case-insensitively (stored with camelCase like foreignObject)
  defp foreign_scope_boundary?({:svg, tag}) do
    String.downcase(tag) in ~w(desc foreignobject title)
  end

  defp foreign_scope_boundary?({:math, tag}) when tag in @mathml_scope_boundaries, do: true
  defp foreign_scope_boundary?(_), do: false

  # --------------------------------------------------------------------------
  # Pop Operations (ref-only stack)
  # --------------------------------------------------------------------------

  @doc """
  Pops the current element from the stack.
  Just removes the ref; the new stack top is the insertion parent.
  Children are already in elements map (added at push time).
  """
  def pop_element(%{stack: [_ref | rest]} = state), do: %{state | stack: rest}

  def pop_element(%{stack: []} = state), do: state

  @doc "Pops elements from the stack of open elements until `ref` has been popped."
  def pop_through_ref(%{stack: [ref | rest]} = state, ref), do: %{state | stack: rest}

  def pop_through_ref(%{stack: [_ | rest]} = state, ref),
    do: pop_through_ref(%{state | stack: rest}, ref)

  def pop_through_ref(%{stack: []} = state, _ref), do: state

  @doc """
  Pops elements from the stack until an element with the given tag is found.
  Returns {:ok, state} if found, {:not_found, state} otherwise.
  """
  def pop_until_tag(%{stack: stack, elements: elements} = state, tag) do
    case do_pop_until_tag(stack, tag, elements) do
      {:found, new_stack} -> {:ok, %{state | stack: new_stack}}
      :not_found -> {:not_found, state}
    end
  end

  defp do_pop_until_tag([], _tag, _elements), do: :not_found

  defp do_pop_until_tag([ref | rest], tag, elements) do
    case elements[ref].tag do
      ^tag -> {:found, rest}
      "template" -> :not_found
      _ -> do_pop_until_tag(rest, tag, elements)
    end
  end

  @doc """
  Pops elements from the stack until a tag in the given list is at the top.
  """
  def pop_until_one_of(%{stack: stack, elements: elements} = state, tags) when is_list(tags) do
    %{state | stack: do_pop_until_one_of(stack, tags, elements)}
  end

  defp do_pop_until_one_of([], _tags, _elements), do: []

  defp do_pop_until_one_of([ref | rest] = stack, tags, elements) do
    if elements[ref].tag in tags do
      stack
    else
      do_pop_until_one_of(rest, tags, elements)
    end
  end

  # --------------------------------------------------------------------------
  # Foster Parenting (ref-only stack)
  # --------------------------------------------------------------------------

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
    template_ref = find_last_template(stack, elements)
    table_ref = find_last_table(stack, elements)

    cond do
      template_closer_to_top?(stack, template_ref, table_ref) ->
        {template_ref, nil}

      table_ref != nil ->
        case elements[table_ref].parent_ref do
          nil -> {:document, nil}
          parent_ref -> {parent_ref, table_ref}
        end

      true ->
        {List.last(stack) || :document, nil}
    end
  end

  defp find_last_template(stack, elements) do
    Enum.find(stack, fn ref -> elements[ref].tag == "template" end)
  end

  defp find_last_table(stack, elements) do
    Enum.find(stack, fn ref ->
      elements[ref].tag == "table"
    end)
  end

  defp template_closer_to_top?(stack, template_ref, table_ref) do
    template_ref != nil and
      (table_ref == nil or
         stack_index(stack, template_ref) < stack_index(stack, table_ref))
  end

  defp stack_index(stack, ref) do
    Enum.find_index(stack, &(&1 == ref))
  end

  @doc """
  Foster parents `content` and returns only the state.
  """
  def foster_insert(state, content) do
    {new_state, _ref} = foster_parent(state, content)
    new_state
  end

  @doc """
  Moves an existing element to the appropriate place for inserting a node
  with `target_ref` as the override target: the foster parent location when
  foster parenting is enabled and the target is a table, tbody, tfoot, thead,
  or tr element, otherwise the end of the target.
  """
  def move_node_to_appropriate_place(%{elements: elements} = state, ref, target_ref) do
    if state.foster_parenting and elements[target_ref].tag in @foster_parent_tags do
      state
      |> detach_node(ref)
      |> foster_move_node(ref)
    else
      state
      |> detach_node(ref)
      |> append_node(ref, target_ref)
    end
  end

  defp detach_node(%{elements: elements} = state, ref) do
    case elements[ref].parent_ref do
      nil ->
        state

      parent_ref ->
        elements =
          elements
          |> Map.update!(parent_ref, &%{&1 | children: List.delete(&1.children, ref)})
          |> Map.update!(ref, &%{&1 | parent_ref: nil})

        %{state | elements: elements}
    end
  end

  defp append_node(%{elements: elements} = state, ref, parent_ref) do
    elements =
      elements
      |> Map.update!(ref, &%{&1 | parent_ref: parent_ref})
      |> add_ref_to_parent_children(ref, parent_ref)

    %{state | elements: elements}
  end

  defp foster_move_node(%{elements: elements} = state, ref) do
    case find_foster_parent(state) do
      {:document, _} ->
        state

      {parent_ref, insert_before_ref} ->
        elements =
          elements
          |> Map.update!(ref, &%{&1 | parent_ref: parent_ref})
          |> insert_ref_before_in_parent(ref, parent_ref, insert_before_ref)

        %{state | elements: elements}
    end
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

    elem = Map.put(elem, :parent_ref, actual_parent_ref)

    new_elements = Map.put(elements, elem.ref, elem)

    new_elements =
      if actual_parent_ref do
        insert_ref_before_in_parent(new_elements, elem.ref, actual_parent_ref, insert_before_ref)
      else
        new_elements
      end

    {%{state | stack: [elem.ref | stack], elements: new_elements}, elem.ref}
  end

  # --------------------------------------------------------------------------
  # Utility
  # --------------------------------------------------------------------------

  @doc """
  Gets an attribute value from an attribute list.

  Returns the value if the attribute is found, or the default if not.

  ## Examples

      iex> get_attr([{"type", "hidden"}, {"name", "foo"}], "type")
      "hidden"

      iex> get_attr([{"name", "foo"}], "type")
      nil

      iex> get_attr([{"name", "foo"}], "type", "text")
      "text"

  """
  def get_attr(attrs, key, default \\ nil) do
    case List.keyfind(attrs, key, 0) do
      nil -> default
      {_, val} -> val
    end
  end

  @doc """
  Corrects certain tag names (e.g., "image" -> "img").
  """
  def correct_tag("image"), do: "img"
  def correct_tag(tag), do: tag

  @doc """
  Splits U+0000 out of a character token's text: the text without them and
  how many there were. In body and in table text each one is a parse error
  and is ignored; foreign content replaces each with U+FFFD.
  """
  def split_null_characters(text) do
    parts = String.split(text, <<0>>)
    {Enum.join(parts), length(parts) - 1}
  end

  @doc """
  Extracts only whitespace characters from text.
  Returns the whitespace portion of the string.
  """
  def extract_whitespace(text) do
    for <<c <- text>>, c in ~c[ \t\n\r\f], into: "", do: <<c>>
  end

  @doc """
  True when every character is ASCII whitespace: U+0009, U+000A, U+000C,
  U+000D, U+0020. `String.trim/1` also strips U+00A0 and other Unicode
  whitespace, which the parser treats as characters.
  """
  def ascii_whitespace_only?(<<c, rest::binary>>) when c in ~c[ \t\n\r\f] do
    ascii_whitespace_only?(rest)
  end

  def ascii_whitespace_only?(<<>>), do: true
  def ascii_whitespace_only?(_text), do: false

  @doc """
  Splits text into leading whitespace and remaining content.
  Returns {whitespace, rest}.
  """
  def split_whitespace(<<c, rest::binary>> = text) when c in ~c[ \t\n\r\f] do
    n = count_leading_whitespace(rest, 1)
    {binary_part(text, 0, n), binary_part(text, n, byte_size(text) - n)}
  end

  def split_whitespace(text), do: {"", text}

  defp count_leading_whitespace(<<c, rest::binary>>, n) when c in ~c[ \t\n\r\f] do
    count_leading_whitespace(rest, n + 1)
  end

  defp count_leading_whitespace(_, n), do: n

  @doc """
  Merges new attributes into the html element, preserving existing attrs.
  Used when processing <html> start tags in various modes.
  """
  def merge_html_attrs(state, new_attrs) when new_attrs == [], do: state

  def merge_html_attrs(state, new_attrs) do
    state
    |> find_ref("html")
    |> merge_html_attrs_at(state, new_attrs)
  end

  defp merge_html_attrs_at(nil, state, _new_attrs), do: state

  defp merge_html_attrs_at(html_ref, %{elements: elements} = state, new_attrs) do
    html_elem = elements[html_ref]
    merged = merge_attr_lists(new_attrs, html_elem.attrs)
    %{state | elements: Map.put(elements, html_ref, %{html_elem | attrs: merged})}
  end

  @doc """
  Merges new attrs into existing attrs, preserving existing values.
  New attrs are only added if the key doesn't already exist.
  """
  def merge_attr_lists(new_attrs, existing_attrs) do
    Enum.reduce(new_attrs, existing_attrs, fn {k, v}, acc ->
      if List.keymember?(acc, k, 0), do: acc, else: [{k, v} | acc]
    end)
  end

  @doc """
  Checks if the current element requires foster parenting.
  Returns true if current node is a table structure element.
  """
  def needs_foster_parenting?(%{stack: [ref | _], elements: elements}) do
    case elements[ref] do
      %{tag: tag} -> tag in @foster_parent_tags
      _ -> true
    end
  end

  def needs_foster_parenting?(_), do: true

  # --------------------------------------------------------------------------
  # Insertion Mode Reset
  # --------------------------------------------------------------------------

  # Map for determining insertion mode from stack element tags.
  # Per WHATWG spec "reset the insertion mode appropriately" algorithm.
  @tag_to_mode %{
    "template" => :in_template,
    "tbody" => :in_table_body,
    "thead" => :in_table_body,
    "tfoot" => :in_table_body,
    "tr" => :in_row,
    "td" => :in_cell,
    "th" => :in_cell,
    "caption" => :in_caption,
    "colgroup" => :in_column_group,
    "table" => :in_table,
    "body" => :in_body,
    "frameset" => :in_frameset,
    "head" => :in_head,
    "html" => :before_head
  }

  @doc """
  "Reset the insertion mode appropriately": walk the stack of open elements
  from the current node; in the fragment case the last node is the context
  element.
  """
  def reset_insertion_mode(%{stack: stack} = state) do
    set_mode(state, mode_from_stack(stack, state))
  end

  defp mode_from_stack([], %{context_element: nil}), do: :in_body

  defp mode_from_stack([], %{context_element: {_ns, tag}} = state) do
    mode_for_node(tag, state) || :in_body
  end

  defp mode_from_stack([_last], %{context_element: {_ns, _tag}} = state) do
    mode_from_stack([], state)
  end

  defp mode_from_stack([ref | rest], %{elements: elements} = state) do
    elements[ref].tag
    |> mode_for_node(state)
    |> mode_or_previous_node(rest, state)
  end

  defp mode_or_previous_node(nil, rest, state), do: mode_from_stack(rest, state)
  defp mode_or_previous_node(mode, _rest, _state), do: mode

  # template: the current template insertion mode
  defp mode_for_node("template", %{template_mode_stack: [mode | _]}), do: mode
  # noscript with scripting enabled maps to :in_head per WHATWG spec
  defp mode_for_node("noscript", %{scripting: true}), do: :in_head
  # html: "before head" until the head element pointer is set, "after head" from then on
  defp mode_for_node("html", %{head_element: nil}), do: :before_head
  defp mode_for_node("html", _state), do: :after_head
  defp mode_for_node(tag, _state), do: Map.get(@tag_to_mode, tag)

  def has_template_on_stack?(state), do: find_ref(state, "template") != nil

  @doc """
  Pops elements from the stack of open elements until an HTML template
  element has been popped.
  """
  def close_html_template(state), do: pop_through(state, "template")

  @doc """
  Pops elements from the stack of open elements until an HTML element with
  the given tag name has been popped.
  """
  def pop_through(state, tag) do
    state
    |> current_tag()
    |> pop_through_tag(tag, state)
  end

  defp pop_through_tag(nil, _tag, state), do: state
  defp pop_through_tag(tag, tag, state), do: pop_element(state)

  defp pop_through_tag(_current, tag, state) do
    state
    |> pop_element()
    |> pop_through(tag)
  end

  def push_template_mode(%{template_mode_stack: modes} = state, mode) do
    %{state | template_mode_stack: [mode | modes]}
  end

  def pop_template_mode(%{template_mode_stack: [_ | rest]} = state) do
    %{state | template_mode_stack: rest}
  end
end
