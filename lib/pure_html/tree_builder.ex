defmodule PureHtml.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a stream of tokens.

  Uses a tuple-based representation inspired by Floki/Saxy:
  - Element: `{tag, attrs, children}` (internally `{id, tag, attrs, children}` during parsing)
  - Text: plain strings in children list
  - Comment: `{:comment, text}`
  - Doctype: returned separately

  The stack holds `{id, tag, attrs, children}` tuples where children
  accumulate in reverse order (for efficient prepending). IDs are stripped
  during finalization.
  """

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)
  @table_cells ~w(td th)
  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)

  @closes_p ~w(address article aside blockquote center details dialog dir div dl
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr listing main menu nav ol p pre section summary table ul)

  @self_closing %{
    "li" => ["li"],
    "dt" => ["dt", "dd"],
    "dd" => ["dt", "dd"],
    "option" => ["option", "optgroup"],
    "optgroup" => ["optgroup"],
    "tr" => ["tr"],
    "td" => ["td", "th"],
    "th" => ["td", "th"]
  }

  # Formatting elements tracked for adoption agency algorithm
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

  # Special elements that create scope boundaries
  @special_elements ~w(address applet area article aside base basefont bgsound blockquote
                       body br button caption center col colgroup dd details dir div dl dt
                       embed fieldset figcaption figure footer form frame frameset h1 h2 h3
                       h4 h5 h6 head header hgroup hr html iframe img input keygen li link
                       listing main marquee menu meta nav noembed noframes noscript object
                       ol p param plaintext pre script section select source style summary
                       table tbody td template textarea tfoot th thead title tr track ul wbr xmp)

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Builds a document from a stream of tokens.

  Returns `{doctype, tree}` where tree is a nested tuple structure.
  """
  def build(tokens) do
    {doctype, stack, _af, _next_id} =
      Enum.reduce(tokens, {nil, [], [], 0}, fn
        {:doctype, name, public_id, system_id, _}, {_, stack, af, nid} ->
          {{name, public_id, system_id}, stack, af, nid}

        token, {doctype, stack, af, nid} ->
          {new_stack, new_af, new_nid} = process(token, stack, af, nid)
          {doctype, new_stack, new_af, new_nid}
      end)

    {doctype, finalize(stack)}
  end

  # --------------------------------------------------------------------------
  # Token processing
  # --------------------------------------------------------------------------

  # Explicit html tag
  defp process({:start_tag, "html", attrs, _}, [], af, nid) do
    {[{nid, "html", attrs, []}], af, nid + 1}
  end

  defp process({:start_tag, "html", _attrs, _}, stack, af, nid) do
    {stack, af, nid}
  end

  # Explicit head tag
  defp process({:start_tag, "head", attrs, _}, stack, af, nid) do
    {stack, nid} = ensure_html(stack, nid)
    {stack, nid} = push_element(stack, nid, "head", attrs)
    {stack, af, nid}
  end

  # Explicit body tag
  defp process({:start_tag, "body", attrs, _}, stack, af, nid) do
    {stack, nid} = ensure_html(stack, nid)
    {stack, nid} = ensure_head(stack, nid)
    stack = close_head(stack)
    {stack, nid} = push_element(stack, nid, "body", attrs)
    {stack, af, nid}
  end

  # SVG element - enter SVG namespace
  defp process({:start_tag, "svg", attrs, _}, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = push_foreign_element(stack, nid, :svg, "svg", attrs)
    {stack, af, nid}
  end

  # MathML element - enter MathML namespace
  defp process({:start_tag, "math", attrs, _}, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = push_foreign_element(stack, nid, :math, "math", attrs)
    {stack, af, nid}
  end

  # Inside foreign content (SVG/MathML) - elements inherit namespace
  defp process({:start_tag, tag, attrs, self_closing}, stack, af, nid) do
    case foreign_namespace(stack) do
      nil -> process_html_start_tag(tag, attrs, self_closing, stack, af, nid)
      ns ->
        {stack, nid} = push_foreign_element(stack, nid, ns, tag, attrs, self_closing)
        {stack, af, nid}
    end
  end

  # End tags for implicit elements
  defp process({:end_tag, "html"}, stack, af, nid), do: {stack, af, nid}
  defp process({:end_tag, "head"}, stack, af, nid), do: {close_head(stack), af, nid}
  defp process({:end_tag, "body"}, stack, af, nid), do: {stack, af, nid}

  # End tag for formatting elements - run adoption agency algorithm
  defp process({:end_tag, tag}, stack, af, nid) when tag in @formatting_elements do
    {stack, af, nid} = run_adoption_agency(tag, stack, af, nid)
    {stack, af, nid}
  end

  # End tag - pop and nest in parent
  defp process({:end_tag, tag}, stack, af, nid), do: {close_tag(tag, stack), af, nid}

  # Character data - empty stack, create structure
  defp process({:character, text}, [], af, nid) do
    {stack, nid} = ensure_html([], nid)
    {stack, nid} = in_body(stack, nid)
    {stack, af, nid} = reconstruct_active_formatting(stack, af, nid)
    {add_text(stack, text), af, nid}
  end

  # Character data inside head element - add directly
  defp process({:character, text}, [{_, tag, _, _} | _] = stack, af, nid) when tag in @head_elements do
    {add_text(stack, text), af, nid}
  end

  # Character data in table context - foster parent (add before table)
  defp process({:character, text}, [{_, tag, _, _} | _] = stack, af, nid) when tag in @table_context do
    {foster_text(stack, text), af, nid}
  end

  # Character data - whitespace before body is ignored
  defp process({:character, text}, stack, af, nid) do
    case {has_body?(stack), String.trim(text)} do
      {false, ""} -> {stack, af, nid}
      _ ->
        {stack, nid} = in_body(stack, nid)
        # Reconstruct active formatting elements before adding text
        {stack, af, nid} = reconstruct_active_formatting(stack, af, nid)
        {add_text(stack, text), af, nid}
    end
  end

  # Comment before html - ignored for now
  defp process({:comment, _text}, [], af, nid), do: {[], af, nid}

  # Comment - add to current element
  defp process({:comment, text}, stack, af, nid) do
    {add_child(stack, {:comment, text}), af, nid}
  end

  # Errors - ignore
  defp process({:error, _}, stack, af, nid), do: {stack, af, nid}

  # HTML start tag processing (called when not in SVG context)
  defp process_html_start_tag(tag, attrs, self_closing, stack, af, nid) when tag in @head_elements do
    {stack, nid} = ensure_html(stack, nid)
    {stack, nid} = ensure_head(stack, nid)
    process_start_tag(stack, af, nid, tag, attrs, self_closing)
  end

  defp process_html_start_tag(tag, attrs, _, stack, af, nid) when tag in @void_elements do
    {stack, nid} = in_body(stack, nid)
    stack = maybe_close_p(stack, tag)
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp process_html_start_tag(tag, attrs, true, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    stack = maybe_close_p(stack, tag)
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp process_html_start_tag(tag, attrs, _, stack, af, nid) when tag in @table_cells do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = ensure_table_context(stack, nid)
    {stack, nid} = push_element(stack, nid, tag, attrs)
    {stack, af, nid}
  end

  defp process_html_start_tag("tr", attrs, _, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = ensure_tbody(stack, nid)
    {stack, nid} = push_element(stack, nid, "tr", attrs)
    {stack, af, nid}
  end

  # Formatting elements - track in active formatting list
  defp process_html_start_tag(tag, attrs, _, stack, af, nid) when tag in @formatting_elements do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = push_element(stack, nid, tag, attrs)
    # Get the ID of the element we just pushed
    [{id, _, _, _} | _] = stack
    # Noah's Ark: limit to 3 elements with same tag/attrs
    af = apply_noahs_ark([{id, tag, attrs} | af], tag, attrs)
    {stack, af, nid}
  end

  defp process_html_start_tag(tag, attrs, _, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    # Close p first (before pushing new element)
    stack = maybe_close_p(stack, tag)
    stack = maybe_close_same(stack, tag)
    # Push new element BEFORE reconstructing, so formatting goes INSIDE it
    {stack, nid} = push_element(stack, nid, tag, attrs)
    # Now reconstruct active formatting elements inside the new element
    {stack, af, nid} = reconstruct_active_formatting(stack, af, nid)
    {stack, af, nid}
  end

  defp process_start_tag(stack, af, nid, tag, attrs, true) do
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp process_start_tag(stack, af, nid, tag, attrs, _) when tag in @void_elements do
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp process_start_tag(stack, af, nid, tag, attrs, _) do
    {stack, nid} = push_element(stack, nid, tag, attrs)
    {stack, af, nid}
  end

  # --------------------------------------------------------------------------
  # Adoption agency algorithm
  # --------------------------------------------------------------------------

  # Run the adoption agency algorithm for a formatting element end tag
  # This handles misnested formatting elements like <a><p></a></p>
  defp run_adoption_agency(subject, stack, af, nid) do
    case find_formatting_entry(af, subject) do
      nil ->
        # No formatting element with this tag in active formatting list
        # Just close normally
        {close_tag(subject, stack), af, nid}

      {af_idx, {fe_id, _fe_tag, _fe_attrs}} ->
        case find_in_stack_by_id(stack, fe_id) do
          nil ->
            # Formatting element not in stack - remove from af
            {stack, List.delete_at(af, af_idx), nid}

          stack_idx ->
            case find_furthest_block(stack, stack_idx) do
              nil ->
                # No furthest block - simple case, just pop to formatting element
                {stack, af} = pop_to_formatting_element(stack, af, af_idx, stack_idx)
                {stack, af, nid}

              fb_idx ->
                # Has furthest block - run full adoption agency
                {_, fe_tag, fe_attrs} = Enum.at(af, af_idx)
                run_adoption_agency_with_furthest_block(
                  stack, af, nid, {af_idx, fe_id, fe_tag, fe_attrs}, stack_idx, fb_idx
                )
            end
        end
    end
  end

  # Find a formatting element entry in the active formatting list
  defp find_formatting_entry(af, tag) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{id, ^tag, attrs}, idx} -> {idx, {id, tag, attrs}}
      _ -> nil
    end)
  end

  # Find an element in the stack by its ID
  defp find_in_stack_by_id(stack, target_id) do
    Enum.find_index(stack, fn {id, _, _, _} -> id == target_id end)
  end

  # Full adoption agency algorithm when there's a furthest block
  # For <a>1<div>2<div>3</a>, stack is [div2{3}, div1{2}, a{1}, body]
  # We want: a{1} closed, div1{a{2}}, div2{a{3}} stay on stack
  defp run_adoption_agency_with_furthest_block(stack, af, nid, {af_idx, fe_id, fe_tag, fe_attrs}, fe_stack_idx, fb_idx) do
    # Split stack: [above_fb..., fb, between..., fe, below_fe...]
    {above_fb, rest1} = Enum.split(stack, fb_idx)
    [fb | rest2] = rest1
    between_count = fe_stack_idx - fb_idx - 1
    {between, [fe | below_fe]} = Enum.split(rest2, between_count)

    # Close elements above FB into FB's children first
    {fb_id, fb_tag, fb_attrs, fb_children} = fb
    fb_children = close_elements_into(above_fb, fb_children)

    # Separate between elements: formatting (in AF) vs non-formatting (blocks)
    {formatting_between, block_between} = partition_between_elements(between, af)

    # HTML5 spec: only clone first 3 formatting elements (inner loop counter limit)
    # Elements beyond 3 are removed from AF and closed into FE without cloning
    {formatting_to_clone_list, _formatting_to_close} = Enum.split(formatting_between, 3)

    # 1. Close ALL formatting elements between into FE (original versions)
    {_fe_id, _fe_tag, _fe_attrs, fe_children} = fe
    fe_children = close_elements_into(formatting_between, fe_children)
    closed_fe = {fe_id, fe_tag, fe_attrs, fe_children}
    below_fe = add_child(below_fe, closed_fe)

    # 2. Create FB with clone of FE wrapping its children
    fb_with_fe_clone = {fb_id, fb_tag, fb_attrs, [{fe_tag, fe_attrs, fb_children}]}

    # 3. Wrap FB with clones of ONLY the first 3 formatting elements
    formatting_to_clone = Enum.map(formatting_to_clone_list, fn {_id, tag, attrs, _} -> {tag, attrs} end)
    {final_fb, nid} = wrap_fb_with_clones_and_ids(fb_with_fe_clone, formatting_to_clone, nid)

    # 4. Block elements stay on stack with FE clone inside their children
    block_with_clones = wrap_children_with_fe_clone(block_between, fe_tag, fe_attrs)

    # 5. Rebuild stack: FB + block elements (reversed) + below_fe
    # block_between is [closest_to_fb, ..., closest_to_fe]
    # We want closest_to_fe on top of below_fe, then others, then FB on top
    final_stack = [final_fb | Enum.reverse(block_with_clones)] ++ below_fe

    # Remove old formatting element from AF, and ALL formatting elements from between
    af = remove_formatting_from_af(af, af_idx, formatting_between)

    {final_stack, af, nid}
  end

  # Partition between elements into formatting (in AF) vs non-formatting
  defp partition_between_elements(between, af) do
    Enum.split_with(between, fn {elem_id, _tag, _attrs, _children} ->
      find_af_entry_by_id(af, elem_id) != nil
    end)
  end

  # Remove formatting element and between formatting elements from AF
  defp remove_formatting_from_af(af, fe_idx, formatting_between) do
    # Remove the formatting element entry
    af = List.delete_at(af, fe_idx)
    # Remove all formatting elements that were between FB and FE
    formatting_ids = MapSet.new(Enum.map(formatting_between, fn {id, _, _, _} -> id end))
    Enum.reject(af, fn {id, _, _} -> MapSet.member?(formatting_ids, id) end)
  end

  # Wrap children of each element with a clone of the formatting element
  defp wrap_children_with_fe_clone(elements, fe_tag, fe_attrs) do
    Enum.map(elements, fn {id, tag, attrs, children} ->
      # Always add a clone of FE wrapping the children (even if empty)
      # FE clone is a 3-tuple since it's a child, not on stack
      wrapped_children = [{fe_tag, fe_attrs, children}]
      {id, tag, attrs, wrapped_children}
    end)
  end

  # Wrap FB with cloned formatting elements, giving each a new ID
  # formatting_to_clone is [closest_to_fb, ..., closest_to_fe]
  defp wrap_fb_with_clones_and_ids(fb, [], nid), do: {fb, nid}

  defp wrap_fb_with_clones_and_ids(fb, formatting_to_clone, nid) do
    # We want: outermost{..{innermost{fb}}}
    # closest_to_fb should be outermost (first to wrap)
    {result, nid} =
      Enum.reduce(formatting_to_clone, {fb, nid}, fn {tag, attrs}, {inner, current_nid} ->
        # Create wrapper with new ID
        wrapper = {current_nid, tag, attrs, [inner]}
        {wrapper, current_nid + 1}
      end)

    {result, nid}
  end

  defp find_af_entry_by_id(af, target_id) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{^target_id, tag, attrs}, idx} -> {idx, {target_id, tag, attrs}}
      _ -> nil
    end)
  end

  # Close a list of elements, nesting each inside the previous one
  # elements is [top_of_stack, ..., closest_to_target]
  # We want: closest_to_target{...{top_of_stack{...children}}}
  defp close_elements_into([], children), do: children

  defp close_elements_into(elements, children) do
    # Process in order: top_of_stack first (becomes innermost)
    # Each subsequent element wraps around the previous result
    Enum.reduce(elements, children, fn {id, tag, attrs, elem_children}, inner_children ->
      closed = {id, tag, attrs, elem_children ++ inner_children}
      [closed]
    end)
  end

  # Find the furthest block - first special element above the formatting element
  defp find_furthest_block(stack, fe_idx) do
    stack
    |> Enum.take(fe_idx)
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{_, tag, _, _}, idx} when tag in @special_elements -> idx
      {{_, {_, _}, _, _}, idx} -> idx  # Foreign elements are also special
      _ -> nil
    end)
  end

  # Simple case: pop elements and remove from active formatting
  # Elements above the formatting element are closed inside it
  defp pop_to_formatting_element(stack, af, af_idx, stack_idx) do
    # Split: elements above formatting element, formatting element, and rest
    {above_fe, [fe | rest]} = Enum.split(stack, stack_idx)

    # Close elements above the formatting element, nesting them inside each other
    # from innermost (top of stack) to formatting element
    # Don't reverse children here - reverse_all in finalization handles it
    closed_above =
      above_fe
      |> Enum.reverse()
      |> Enum.reduce(nil, fn {id, tag, attrs, children}, inner ->
        children = if inner, do: [inner | children], else: children
        {id, tag, attrs, children}
      end)

    # Add closed elements as children of the formatting element
    {fe_id, fe_tag, fe_attrs, fe_children} = fe
    fe_children = if closed_above, do: [closed_above | fe_children], else: fe_children
    closed_fe = {fe_id, fe_tag, fe_attrs, fe_children}

    # Add the closed formatting element to the rest of the stack
    final_stack = add_child(rest, closed_fe)

    # Remove from active formatting
    af = List.delete_at(af, af_idx)
    {final_stack, af}
  end

  # Reconstruct active formatting elements - reopens formatting elements that were
  # implicitly closed but are still in the active formatting list
  defp reconstruct_active_formatting(stack, af, nid) do
    # Find entries in AF that are not in the stack
    entries_to_reconstruct =
      af
      |> Enum.reverse()  # Process in order (oldest first)
      |> Enum.filter(fn {id, _tag, _attrs} ->
        find_in_stack_by_id(stack, id) == nil
      end)

    if entries_to_reconstruct == [] do
      {stack, af, nid}
    else
      reconstruct_entries(stack, af, nid, entries_to_reconstruct)
    end
  end

  defp reconstruct_entries(stack, af, nid, []), do: {stack, af, nid}

  defp reconstruct_entries(stack, af, nid, [{old_id, tag, attrs} | rest]) do
    # Create new element with new ID
    new_entry = {nid, tag, attrs, []}
    new_stack = [new_entry | stack]

    # Update AF: replace old entry with new one
    new_af = update_af_entry(af, old_id, {nid, tag, attrs})

    reconstruct_entries(new_stack, new_af, nid + 1, rest)
  end

  defp update_af_entry(af, old_id, new_entry) do
    Enum.map(af, fn
      {^old_id, _, _} -> new_entry
      entry -> entry
    end)
  end

  # Noah's Ark: limit active formatting elements with same tag/attrs to 3
  # If there are 4+ matching elements, remove the oldest (last in list)
  defp apply_noahs_ark(af, tag, attrs) do
    # Find matching entries (same tag and attrs)
    matching_indices =
      af
      |> Enum.with_index()
      |> Enum.filter(fn {{_id, t, a}, _idx} -> t == tag and a == attrs end)
      |> Enum.map(fn {_entry, idx} -> idx end)

    if length(matching_indices) > 3 do
      # Remove the oldest (highest index = last in list)
      oldest_idx = Enum.max(matching_indices)
      List.delete_at(af, oldest_idx)
    else
      af
    end
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  defp ensure_table_context(stack, nid) do
    {stack, nid} = ensure_tbody(stack, nid)
    ensure_tr(stack, nid)
  end

  defp ensure_tbody([{_, "table", _, _} | _] = stack, nid), do: push_element(stack, nid, "tbody", %{})
  defp ensure_tbody([{_, tag, _, _} | _] = stack, nid) when tag in @table_sections, do: {stack, nid}
  defp ensure_tbody([{_, "tr", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_tbody(stack, nid), do: {stack, nid}

  defp ensure_tr([{_, tag, _, _} | _] = stack, nid) when tag in @table_sections do
    push_element(stack, nid, "tr", %{})
  end

  defp ensure_tr([{_, "tr", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_tr(stack, nid), do: {stack, nid}

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(stack, tag) when tag in @closes_p do
    close_p_if_open(stack)
  end

  defp maybe_close_p(stack, _tag), do: stack

  # Close p if it exists in the stack, nesting elements above it inside p
  defp close_p_if_open(stack) do
    case find_p_in_stack(stack, []) do
      nil ->
        # No p found
        stack

      {above_p, {p_id, p_attrs, p_children}, below_p} ->
        # above_p is [b4, b3, b2, b1] from innermost to outermost
        # We want b1{b2{b3{b4{}}}} - outermost wraps innermost
        # So reduce from innermost (b4) outward
        nested_above =
          above_p
          |> Enum.reduce(nil, fn {id, tag, attrs, children}, inner ->
            children = if inner, do: [inner | children], else: children
            {id, tag, attrs, children}
          end)

        # Add nested structure to p's children
        p_children = if nested_above, do: [nested_above | p_children], else: p_children
        closed_p = {p_id, "p", p_attrs, p_children}

        # Add closed p to the element below (body, etc.)
        add_child(below_p, closed_p)
    end
  end

  defp find_p_in_stack([], _acc), do: nil

  defp find_p_in_stack([{id, "p", attrs, children} | rest], acc) do
    {Enum.reverse(acc), {id, attrs, children}, rest}
  end

  defp find_p_in_stack([elem | rest], acc) do
    find_p_in_stack(rest, [elem | acc])
  end

  for {tag, closes} <- @self_closing do
    defp maybe_close_same([{id, top_tag, attrs, children} | rest], unquote(tag))
         when top_tag in unquote(closes) do
      add_child(rest, {id, top_tag, attrs, children})
    end
  end

  defp maybe_close_same(stack, _tag), do: stack

  # --------------------------------------------------------------------------
  # Document structure
  # --------------------------------------------------------------------------

  defp in_body(stack, nid) do
    {stack, nid} = ensure_html(stack, nid)
    {stack, nid} = ensure_head(stack, nid)
    stack = close_head(stack)
    ensure_body(stack, nid)
  end

  defp ensure_html([], nid), do: {[{nid, "html", %{}, []}], nid + 1}
  defp ensure_html([{_, "html", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_html(stack, nid), do: {stack, nid}

  defp ensure_head([{_, "html", _, _}] = stack, nid), do: ensure_head_check(stack, stack, nid)
  defp ensure_head([{_, "head", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_head([{_, "body", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_head(stack, nid), do: {stack, nid}

  defp ensure_head_check([{_, "html", _, [{_, "head", _, _} | _]}], original, nid), do: {original, nid}

  defp ensure_head_check([{id, "html", attrs, [_ | rest]}], original, nid) do
    ensure_head_check([{id, "html", attrs, rest}], original, nid)
  end

  defp ensure_head_check([{_, "html", attrs, []}], [{html_id, "html", _, children}], nid) do
    {[{nid, "head", %{}, []}, {html_id, "html", attrs, children}], nid + 1}
  end

  defp close_head([{id, "head", attrs, children} | rest]) do
    add_child(rest, {id, "head", attrs, children})
  end

  defp close_head(stack), do: stack

  defp ensure_body([{_, "body", _, _} | _] = stack, nid), do: {stack, nid}

  defp ensure_body([{html_id, "html", attrs, children}], nid) do
    {[{nid, "body", %{}, []}, {html_id, "html", attrs, children}], nid + 1}
  end

  defp ensure_body([current | rest], nid) do
    {rest, nid} = ensure_body(rest, nid)
    {[current | rest], nid}
  end

  defp ensure_body([], nid), do: {[], nid}

  defp has_body?([{_, "body", _, _} | _]), do: true
  defp has_body?([_ | rest]), do: has_body?(rest)
  defp has_body?([]), do: false

  # --------------------------------------------------------------------------
  # Foster parenting
  # --------------------------------------------------------------------------

  defp foster_text(stack, text) do
    foster_content(stack, text, [], &add_foster_text/2)
  end

  defp foster_content([{id, "table", attrs, children} | rest], content, acc, add_fn) do
    rest = add_fn.(rest, content)
    rebuild_stack(acc, [{id, "table", attrs, children} | rest])
  end

  defp foster_content([current | rest], content, acc, add_fn) do
    foster_content(rest, content, [current | acc], add_fn)
  end

  defp foster_content([], _content, acc, _add_fn) do
    Enum.reverse(acc)
  end

  defp add_foster_text([{id, tag, attrs, [prev | children]} | rest], text) when is_binary(prev) do
    [{id, tag, attrs, [prev <> text | children]} | rest]
  end

  defp add_foster_text([{id, tag, attrs, children} | rest], text) do
    [{id, tag, attrs, [text | children]} | rest]
  end

  defp add_foster_text([], _text), do: []

  defp rebuild_stack([], stack), do: stack
  defp rebuild_stack([elem | rest], stack), do: rebuild_stack(rest, [elem | stack])

  # --------------------------------------------------------------------------
  # Stack operations
  # --------------------------------------------------------------------------

  defp push_element(stack, nid, tag, attrs) do
    {[{nid, tag, attrs, []} | stack], nid + 1}
  end

  defp push_foreign_element(stack, nid, ns, tag, attrs, self_closing \\ false)

  defp push_foreign_element(stack, nid, ns, tag, attrs, true) do
    {add_child(stack, {{ns, tag}, attrs, []}), nid}
  end

  defp push_foreign_element(stack, nid, ns, tag, attrs, _) do
    {[{nid, {ns, tag}, attrs, []} | stack], nid + 1}
  end

  defp foreign_namespace([{_, {ns, _}, _, _} | _]) when ns in [:svg, :math], do: ns
  defp foreign_namespace([_ | rest]), do: foreign_namespace(rest)
  defp foreign_namespace([]), do: nil

  defp add_child(stack, child)

  defp add_child([{id, tag, attrs, children} | rest], child) do
    [{id, tag, attrs, [child | children]} | rest]
  end

  defp add_child([], child) do
    [child]
  end

  defp add_text(stack, text)

  defp add_text([{id, tag, attrs, [prev_text | rest_children]} | rest], text)
       when is_binary(prev_text) do
    [{id, tag, attrs, [prev_text <> text | rest_children]} | rest]
  end

  defp add_text([{id, tag, attrs, children} | rest], text) do
    [{id, tag, attrs, [text | children]} | rest]
  end

  defp add_text([], _text), do: []

  defp close_tag(tag, stack) do
    case pop_until(tag, stack, []) do
      {:found, element, rest} -> add_child(rest, element)
      :not_found -> stack
    end
  end

  defp pop_until(_tag, [], _acc), do: :not_found

  defp pop_until(tag, [{id, tag, attrs, children} | rest], acc) do
    finalize_pop({id, tag, attrs, children}, acc, rest)
  end

  defp pop_until(tag, [{id, {:svg, tag}, attrs, children} | rest], acc) do
    finalize_pop({id, {:svg, tag}, attrs, children}, acc, rest)
  end

  defp pop_until(tag, [current | rest], acc) do
    pop_until(tag, rest, [current | acc])
  end

  defp finalize_pop({id, tag, attrs, children}, acc, rest) do
    # acc is in stack order: [closer_to_target, ..., top_of_stack]
    # We need to nest them: top inside next inside ... inside target
    # So reverse to get [top, ..., closer_to_target], then reduce
    nested_above =
      acc
      |> Enum.reverse()
      |> Enum.reduce(nil, fn {i, t, a, c}, inner ->
        c = if inner, do: [inner | c], else: c
        {i, t, a, c}
      end)

    # Add nested structure to target's children
    children = if nested_above, do: [nested_above | children], else: children
    {:found, {id, tag, attrs, children}, rest}
  end

  # --------------------------------------------------------------------------
  # Finalization
  # --------------------------------------------------------------------------

  defp finalize(stack) do
    stack
    |> close_through_head()
    |> ensure_body_final()
    |> do_finalize()
    |> strip_ids()
  end

  defp close_through_head([{_, "html", _, _}] = stack), do: stack
  defp close_through_head([{_, "body", _, _} | _] = stack), do: stack

  defp close_through_head([{id, tag, attrs, children} | rest]) do
    child = {id, tag, attrs, children}
    close_through_head(add_child(rest, child))
  end

  defp close_through_head([]), do: [{0, "html", %{}, [{1, "head", %{}, []}]}]

  # Ensure body exists during finalization (doesn't need nid tracking)
  defp ensure_body_final([{_, "body", _, _} | _] = stack), do: stack

  defp ensure_body_final([{html_id, "html", attrs, children}]) do
    [{0, "body", %{}, []}, {html_id, "html", attrs, children}]
  end

  defp ensure_body_final([current | rest]) do
    [current | ensure_body_final(rest)]
  end

  defp ensure_body_final([]), do: []

  defp do_finalize([{id, tag, attrs, children}]) do
    {id, tag, attrs, reverse_all(children)}
  end

  defp do_finalize([{id, tag, attrs, children} | rest]) do
    child = {id, tag, attrs, children}
    do_finalize(add_child(rest, child))
  end

  defp do_finalize([]), do: nil

  defp reverse_all(children) do
    children
    |> Enum.reverse()
    |> Enum.map(fn
      {id, {ns, tag}, attrs, kids} when is_integer(id) and is_list(kids) ->
        {id, {ns, tag}, attrs, reverse_all(kids)}

      {id, tag, attrs, kids} when is_integer(id) and is_list(kids) ->
        {id, tag, attrs, reverse_all(kids)}

      {{ns, tag}, attrs, kids} when is_list(kids) ->
        {{ns, tag}, attrs, reverse_all(kids)}

      {tag, attrs, kids} when is_binary(tag) and is_list(kids) ->
        {tag, attrs, reverse_all(kids)}

      {:comment, _} = comment ->
        comment

      text when is_binary(text) ->
        text
    end)
  end

  # Strip IDs from the final tree, converting 4-tuples back to 3-tuples
  defp strip_ids(nil), do: nil

  defp strip_ids({_id, {ns, tag}, attrs, children}) do
    {{ns, tag}, attrs, Enum.map(children, &strip_ids/1)}
  end

  defp strip_ids({id, tag, attrs, children}) when is_integer(id) do
    {tag, attrs, Enum.map(children, &strip_ids/1)}
  end

  # Already a 3-tuple (void elements, etc.)
  defp strip_ids({{ns, tag}, attrs, children}) do
    {{ns, tag}, attrs, Enum.map(children, &strip_ids/1)}
  end

  defp strip_ids({tag, attrs, children}) when is_binary(tag) do
    {tag, attrs, Enum.map(children, &strip_ids/1)}
  end

  defp strip_ids({:comment, text}), do: {:comment, text}
  defp strip_ids(text) when is_binary(text), do: text
end
