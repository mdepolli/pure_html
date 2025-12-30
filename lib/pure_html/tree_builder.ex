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
  # Elements that are valid in table context (don't need foster parenting)
  @table_elements ~w(table caption colgroup col thead tbody tfoot tr td th script template style)

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
    "th" => ["td", "th"],
    # Heading elements close other heading elements
    "h1" => ["h1", "h2", "h3", "h4", "h5", "h6"],
    "h2" => ["h1", "h2", "h3", "h4", "h5", "h6"],
    "h3" => ["h1", "h2", "h3", "h4", "h5", "h6"],
    "h4" => ["h1", "h2", "h3", "h4", "h5", "h6"],
    "h5" => ["h1", "h2", "h3", "h4", "h5", "h6"],
    "h6" => ["h1", "h2", "h3", "h4", "h5", "h6"]
  }

  # Tag name corrections per HTML5 spec
  @tag_corrections %{
    "image" => "img"
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

  Returns `{doctype, nodes}` where nodes is a list of top-level nodes.
  The list typically contains comments (if any) followed by the html element.
  """
  def build(tokens) do
    # Accumulator: {doctype, stack, af, nid, pre_html_comments}
    {doctype, stack, _af, _next_id, pre_html_comments} =
      Enum.reduce(tokens, {nil, [], [], 0, []}, fn
        {:doctype, name, public_id, system_id, _}, {_, stack, af, nid, comments} ->
          {{name, public_id, system_id}, stack, af, nid, comments}

        {:comment, text}, {doctype, [], af, nid, comments} ->
          # Comment before html element - collect it
          {doctype, [], af, nid, [{:comment, text} | comments]}

        token, {doctype, stack, af, nid, comments} ->
          {new_stack, new_af, new_nid} = process(token, stack, af, nid)
          {doctype, new_stack, new_af, new_nid, comments}
      end)

    # Finalize and prepend pre-html comments
    html_node = finalize(stack)
    nodes = Enum.reverse(pre_html_comments) ++ [html_node]
    {doctype, nodes}
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

  # Explicit body tag - ignore if body already exists
  defp process({:start_tag, "body", attrs, _}, stack, af, nid) do
    {stack, nid} = ensure_html(stack, nid)
    {stack, nid} = ensure_head(stack, nid)
    stack = close_head(stack)

    if has_tag?(stack, "body") do
      # Body already exists - ignore this tag (HTML5 spec allows adopting attrs but we skip that)
      {stack, af, nid}
    else
      {stack, nid} = push_element(stack, nid, "body", attrs)
      {stack, af, nid}
    end
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
    # Apply tag name corrections (e.g., image -> img)
    tag = Map.get(@tag_corrections, tag, tag)

    case foreign_namespace(stack) do
      nil ->
        process_html_start_tag(tag, attrs, self_closing, stack, af, nid)

      ns ->
        {stack, nid} = push_foreign_element(stack, nid, ns, tag, attrs, self_closing)
        {stack, af, nid}
    end
  end

  # End tags for implicit elements
  defp process({:end_tag, "html"}, stack, af, nid), do: {stack, af, nid}
  defp process({:end_tag, "head"}, stack, af, nid), do: {close_head(stack), af, nid}
  defp process({:end_tag, "body"}, stack, af, nid), do: {stack, af, nid}

  # End tag for table cells - clear af up to marker
  defp process({:end_tag, tag}, stack, af, nid) when tag in @table_cells do
    {close_tag(tag, stack), clear_af_to_marker(af), nid}
  end

  # End tag for table - first close any foster-parented elements
  defp process({:end_tag, "table"}, stack, af, nid) do
    # Close any non-table elements that were foster-parented
    stack = clear_to_table_context(stack)
    {close_tag("table", stack), af, nid}
  end

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
  defp process({:character, text}, [{_, tag, _, _} | _] = stack, af, nid)
       when tag in @head_elements do
    {add_text(stack, text), af, nid}
  end

  # Character data in table context - foster parent (add before table)
  # Also reconstruct active formatting elements before the table
  defp process({:character, text}, [{_, tag, _, _} | _] = stack, af, nid)
       when tag in @table_context do
    {stack, af, nid, reconstructed} = foster_reconstruct_active_formatting(stack, af, nid)

    if reconstructed do
      # Text goes into the reconstructed formatting element (now on top of stack)
      {add_text(stack, text), af, nid}
    else
      # No formatting to reconstruct, just foster the text
      {foster_text(stack, text), af, nid}
    end
  end

  # Character data - whitespace before body is ignored
  defp process({:character, text}, stack, af, nid) do
    case {has_tag?(stack, "body"), String.trim(text)} do
      {false, ""} ->
        {stack, af, nid}

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
  # First check if we're in table context and need to foster-parent
  defp process_html_start_tag(tag, attrs, self_closing, stack, af, nid)
       when tag not in @table_elements do
    if in_table_context?(stack) do
      # Foster-parent: push element before the table, then process
      process_foster_start_tag(tag, attrs, self_closing, stack, af, nid)
    else
      do_process_html_start_tag(tag, attrs, self_closing, stack, af, nid)
    end
  end

  # Table elements bypass foster parenting check
  defp process_html_start_tag(tag, attrs, self_closing, stack, af, nid) do
    do_process_html_start_tag(tag, attrs, self_closing, stack, af, nid)
  end

  # Generic scope check: search for target_tags, stopping at boundary_tags
  defp in_scope?(nodes, target_tags, boundary_tags) do
    Enum.reduce_while(nodes, false, fn {_, tag, _, _}, _acc ->
      cond do
        tag in target_tags -> {:halt, true}
        tag in boundary_tags -> {:halt, false}
        true -> {:cont, false}
      end
    end)
  end

  # Check if we're inside a table (need foster parenting for non-table elements)
  # Stop at template boundaries - template creates isolated parsing context
  defp in_table_context?(stack) do
    in_scope?(stack, ["table" | @table_context], ["template", "body", "html"])
  end

  defp do_process_html_start_tag(tag, attrs, self_closing, stack, af, nid)
       when tag in @head_elements do
    cond do
      in_template?(stack) ->
        # Inside template - use process_start_tag which handles void elements
        process_start_tag(stack, af, nid, tag, attrs, self_closing)

      has_tag?(stack, "body") ->
        # Already in body context - use process_start_tag which handles void elements
        process_start_tag(stack, af, nid, tag, attrs, self_closing)

      true ->
        # In head context - ensure we're in head and reopen if needed
        {stack, nid} = ensure_html(stack, nid)
        {stack, nid} = ensure_head(stack, nid)

        # If head was closed, reopen it to add the element inside
        {stack, nid} =
          if has_tag?(stack, "head") do
            {stack, nid}
          else
            reopen_head(stack, nid)
          end

        process_start_tag(stack, af, nid, tag, attrs, self_closing)
    end
  end

  defp do_process_html_start_tag(tag, attrs, _, stack, af, nid) when tag in @void_elements do
    {stack, nid} = in_body(stack, nid)
    stack = maybe_close_p(stack, tag)
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp do_process_html_start_tag(tag, attrs, true, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    stack = maybe_close_p(stack, tag)
    {add_child(stack, {tag, attrs, []}), af, nid}
  end

  defp do_process_html_start_tag(tag, attrs, _, stack, af, nid) when tag in @table_cells do
    {stack, nid} = in_body(stack, nid)
    # Clear any foster-parented elements before ensuring table context
    stack = clear_to_table_body_context(stack)
    {stack, nid} = ensure_table_context(stack, nid)
    {stack, nid} = push_element(stack, nid, tag, attrs)
    # Push a scope marker - formatting elements won't be reconstructed past this
    {stack, [:marker | af], nid}
  end

  defp do_process_html_start_tag("tr", attrs, _, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)
    # Clear any foster-parented elements before ensuring tbody
    stack = clear_to_table_body_context(stack)
    {stack, nid} = ensure_tbody(stack, nid)
    {stack, nid} = push_element(stack, nid, "tr", attrs)
    {stack, af, nid}
  end

  # Special handling for <a> - if already active, run adoption agency first
  defp do_process_html_start_tag("a", attrs, _, stack, af, nid) do
    {stack, nid} = in_body(stack, nid)

    # Per HTML5 spec: if <a> is in AF, run adoption agency and remove it
    {stack, af, nid} =
      if has_formatting_entry?(af, "a") do
        {stack, af, nid} = run_adoption_agency("a", stack, af, nid)
        # Remove any remaining <a> from AF (in case adoption agency didn't)
        af = remove_formatting_entry(af, "a")
        {stack, af, nid}
      else
        {stack, af, nid}
      end

    {stack, nid} = push_element(stack, nid, "a", attrs)
    [{id, _, _, _} | _] = stack
    af = apply_noahs_ark([{id, "a", attrs} | af], "a", attrs)
    {stack, af, nid}
  end

  # Formatting elements - track in active formatting list
  defp do_process_html_start_tag(tag, attrs, _, stack, af, nid)
       when tag in @formatting_elements do
    {stack, nid} = in_body(stack, nid)
    {stack, nid} = push_element(stack, nid, tag, attrs)
    # Get the ID of the element we just pushed
    [{id, _, _, _} | _] = stack
    # Noah's Ark: limit to 3 elements with same tag/attrs
    af = apply_noahs_ark([{id, tag, attrs} | af], tag, attrs)
    {stack, af, nid}
  end

  defp do_process_html_start_tag(tag, attrs, _, stack, af, nid) do
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
  # The outer loop runs up to 8 times per the HTML5 spec
  defp run_adoption_agency(subject, stack, af, nid) do
    run_adoption_agency_outer_loop(subject, stack, af, nid, 0)
  end

  defp run_adoption_agency_outer_loop(_subject, stack, af, nid, iteration) when iteration >= 8 do
    # Outer loop limit reached
    {stack, af, nid}
  end

  defp run_adoption_agency_outer_loop(subject, stack, af, nid, iteration) do
    case find_formatting_entry(af, subject) do
      nil ->
        # No formatting element with this tag in active formatting list
        if iteration == 0 do
          # First iteration - just close normally
          {close_tag(subject, stack), af, nid}
        else
          # Subsequent iterations - we're done
          {stack, af, nid}
        end

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

                {new_stack, new_af, new_nid} =
                  run_adoption_agency_with_furthest_block(
                    stack,
                    af,
                    nid,
                    {af_idx, fe_id, fe_tag, fe_attrs},
                    stack_idx,
                    fb_idx
                  )

                # Continue outer loop
                run_adoption_agency_outer_loop(subject, new_stack, new_af, new_nid, iteration + 1)
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

  # Check if a formatting element exists in AF (before any marker)
  defp has_formatting_entry?(af, tag) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.any?(fn
      {_, ^tag, _} -> true
      _ -> false
    end)
  end

  # Remove a formatting element entry from AF
  defp remove_formatting_entry(af, tag) do
    Enum.reject(af, fn
      {_, ^tag, _} -> true
      _ -> false
    end)
  end

  # Find an element in the stack by its ID
  defp find_in_stack_by_id(stack, target_id) do
    Enum.find_index(stack, fn {id, _, _, _} -> id == target_id end)
  end

  # Full adoption agency algorithm when there's a furthest block
  # For <a>1<div>2<div>3</a>, stack is [div2{3}, div1{2}, a{1}, body]
  # We want: a{1} closed, div1{a{2}}, div2{a{3}} stay on stack
  defp run_adoption_agency_with_furthest_block(
         stack,
         af,
         nid,
         {af_idx, fe_id, fe_tag, fe_attrs},
         fe_stack_idx,
         fb_idx
       ) do
    # Split stack: [above_fb..., fb, between..., fe, below_fe...]
    {above_fb, rest1} = Enum.split(stack, fb_idx)
    [fb | rest2] = rest1
    between_count = fe_stack_idx - fb_idx - 1
    {between, [fe | below_fe]} = Enum.split(rest2, between_count)

    # Keep FB's original children (don't close above_fb into it - they stay on stack)
    {fb_id, fb_tag, fb_attrs, fb_children} = fb

    # Separate between elements: formatting (in AF) vs non-formatting (blocks)
    {formatting_between, block_between} = partition_between_elements(between, af)

    # HTML5 spec: only clone first 3 formatting elements (inner loop counter limit)
    # Elements beyond 3 are removed from AF and closed into FE without cloning
    {formatting_to_clone_list, _formatting_to_close} = Enum.split(formatting_between, 3)

    # 1. Close ALL formatting elements between into FE (original versions)
    {_fe_id, _fe_tag, _fe_attrs, fe_children} = fe
    fe_children = close_elements_into(formatting_between, fe_children)
    closed_fe = {fe_id, fe_tag, fe_attrs, fe_children}
    # Use foster-aware add so FE goes to body, not table
    below_fe = foster_aware_add_child(below_fe, closed_fe)

    # 2. Create new FE clone as a stack element (with new ID)
    # Per HTML5 spec step 27: insert new element into stack below furthest block
    # The FE clone takes FB's original children
    new_fe_clone_id = nid
    new_fe_clone = {new_fe_clone_id, fe_tag, fe_attrs, fb_children}
    nid = nid + 1

    # 3. FB's children have been moved to the FE clone, so FB is now empty
    # When FE clone is closed during finalization, it becomes a child of FB
    fb_empty = {fb_id, fb_tag, fb_attrs, []}

    # 4. Create formatting clones as separate stack elements (not wrapping FB)
    # Stack order: [a-clone, p, b-clone, ...] so closing a-clone goes into p, p goes into b-clone
    formatting_to_clone =
      Enum.map(formatting_to_clone_list, fn {_id, tag, attrs, _} -> {tag, attrs} end)

    {formatting_stack_elements, nid} = create_formatting_stack_elements(formatting_to_clone, nid)

    # 5. Block elements stay on stack with FE clone inside their children
    block_with_clones = wrap_children_with_fe_clone(block_between, fe_tag, fe_attrs)

    # 6. Rebuild stack:
    # - above_fb elements stay on stack ABOVE the new FE clone (they're still open)
    # - Stack order: [above_fb..., a-clone, FB, formatting_clones..., block_clones..., below_fe...]
    # The outer loop will process above_fb elements in subsequent iterations
    final_stack =
      above_fb ++
        [new_fe_clone, fb_empty | formatting_stack_elements] ++
        Enum.reverse(block_with_clones) ++ below_fe

    # 7. Update AF: remove old FE and between formatting elements,
    # add new FE clone so outer loop can find it
    af = remove_formatting_from_af(af, af_idx, formatting_between)
    af = [{new_fe_clone_id, fe_tag, fe_attrs} | af]

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

  # Create formatting clones as stack elements (4-tuples with IDs)
  # Returns a list of elements to put on the stack BELOW the furthest block
  # formatting_to_clone is [closest_to_fb, ..., closest_to_fe] (in stack order)
  defp create_formatting_stack_elements([], nid), do: {[], nid}

  defp create_formatting_stack_elements(formatting_to_clone, nid) do
    # Create stack elements - each is empty, children will be added during finalization
    {elements, new_nid} =
      Enum.reduce(formatting_to_clone, {[], nid}, fn {tag, attrs}, {acc, current_nid} ->
        elem = {current_nid, tag, attrs, []}
        {[elem | acc], current_nid + 1}
      end)

    # Reverse to maintain order: closest_to_fb first (will be closed last)
    {Enum.reverse(elements), new_nid}
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

  defp close_elements_into(elements, fe_original_children) do
    # Close each formatting element between (keeping their own children)
    # Nest them if multiple: innermost first
    # Then prepend to FE's original children as siblings
    nested = nest_formatting_elements(elements)
    [nested | fe_original_children]
  end

  # Nest multiple formatting elements: first in list (closest to FB) becomes innermost
  # Stack order is [top..., closest_to_fe], we want closest_to_fe to be outermost
  defp nest_formatting_elements(elements) do
    # Reverse so closest to FE (deepest in stack) is first, then fold
    elements
    |> Enum.reverse()
    |> do_nest_formatting()
  end

  defp do_nest_formatting([{id, tag, attrs, children}]), do: {id, tag, attrs, children}

  defp do_nest_formatting([{id, tag, attrs, children} | rest]) do
    inner = do_nest_formatting(rest)
    {id, tag, attrs, [inner | children]}
  end

  # Find the furthest block - the special element CLOSEST to the formatting element
  # (i.e., the first special element opened AFTER the FE)
  # "Furthest" refers to its position in the DOM tree (furthest from the root),
  # not its position in the stack.
  # Note: Foreign elements (SVG, MathML) are NOT treated as special for adoption agency
  defp find_furthest_block(stack, fe_idx) do
    # Elements between top of stack and FE (opened after FE)
    elements =
      stack
      |> Enum.take(fe_idx)
      |> Enum.with_index()

    # Find the special element closest to FE (highest index in this range)
    # Only HTML elements are considered special, not foreign (SVG/MathML) elements
    elements
    |> Enum.reverse()
    |> Enum.find_value(fn
      {{_, tag, _, _}, idx} when is_binary(tag) and tag in @special_elements -> idx
      _ -> nil
    end)
  end

  # Simple case: pop elements and remove from active formatting
  # Elements above the formatting element are closed inside it
  defp pop_to_formatting_element(stack, af, af_idx, stack_idx) do
    # Split: elements above formatting element, formatting element, and rest
    {above_fe, [fe | rest]} = Enum.split(stack, stack_idx)

    # Close elements above the formatting element, nesting them inside each other
    # above_fe is [top, ..., closest_to_fe] - top should be innermost, closest_to_fe outermost
    # Example: [input, tr, svg] -> svg{tr{input{}}}
    closed_above =
      Enum.reduce(above_fe, nil, fn {id, tag, attrs, children}, inner ->
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
    # Stop at markers - don't reconstruct past scope boundaries
    entries_to_reconstruct =
      af
      # Take only entries before the first marker
      |> Enum.take_while(&(&1 != :marker))
      # Process in order (oldest first)
      |> Enum.reverse()
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

  # Clear active formatting list up to the last marker
  defp clear_af_to_marker(af) do
    af
    |> Enum.drop_while(&(&1 != :marker))
    |> Enum.drop(1)
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  # Clear the stack back to a table body context per HTML5 spec
  # Pop elements until we reach tbody, thead, tfoot, table, template, or html
  defp clear_to_table_body_context([{_, tag, _, _} | _] = stack)
       when tag in @table_sections or tag in ["table", "template", "html"] do
    stack
  end

  defp clear_to_table_body_context([{id, tag, attrs, children} | rest]) do
    # Close this element (foster-aware so it goes to body if needed)
    child = {id, tag, attrs, children}
    clear_to_table_body_context(foster_aware_add_child(rest, child))
  end

  defp clear_to_table_body_context([]), do: []

  # Clear the stack to the table element itself (for </table>)
  # Foster-close any non-table elements to body
  defp clear_to_table_context([{_, "table", _, _} | _] = stack), do: stack
  defp clear_to_table_context([{_, "template", _, _} | _] = stack), do: stack
  defp clear_to_table_context([{_, "html", _, _} | _] = stack), do: stack

  defp clear_to_table_context([{id, tag, attrs, children} | rest]) do
    child = {id, tag, attrs, children}
    clear_to_table_context(foster_aware_add_child(rest, child))
  end

  defp clear_to_table_context([]), do: []

  defp ensure_table_context(stack, nid) do
    {stack, nid} = ensure_tbody(stack, nid)
    ensure_tr(stack, nid)
  end

  defp ensure_tbody([{_, "table", _, _} | _] = stack, nid),
    do: push_element(stack, nid, "tbody", %{})

  defp ensure_tbody([{_, tag, _, _} | _] = stack, nid) when tag in @table_sections,
    do: {stack, nid}

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
    if in_template?(stack) do
      # Inside template - don't mess with head/body structure
      # Content stays inside the template
      {stack, nid}
    else
      {stack, nid} = ensure_html(stack, nid)
      {stack, nid} = ensure_head(stack, nid)
      stack = close_head(stack)
      ensure_body(stack, nid)
    end
  end

  # Check if we're currently inside a template element
  defp in_template?(stack) do
    in_scope?(stack, ["template"], ["html", "body", "head"])
  end

  defp ensure_html([], nid), do: {[{nid, "html", %{}, []}], nid + 1}
  defp ensure_html([{_, "html", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_html(stack, nid), do: {stack, nid}

  defp ensure_head([{_, "html", _, _}] = stack, nid), do: ensure_head_check(stack, stack, nid)
  defp ensure_head([{_, "head", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_head([{_, "body", _, _} | _] = stack, nid), do: {stack, nid}
  defp ensure_head(stack, nid), do: {stack, nid}

  defp ensure_head_check([{_, "html", _, [{_, "head", _, _} | _]}], original, nid),
    do: {original, nid}

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

  # Generic helper to check if a tag exists in a list of stack elements
  defp has_tag?(nodes, tag) do
    Enum.any?(nodes, fn {_, t, _, _} -> t == tag end)
  end

  # Reopen head by finding it in html's children and pushing it back onto stack
  defp reopen_head([{html_id, "html", html_attrs, children}], nid) do
    case find_and_remove_head(children, []) do
      {head_tuple, remaining_children} ->
        # Found head - push it back onto stack
        {head_id, head_attrs, head_children} = head_tuple

        stack = [
          {head_id, "head", head_attrs, head_children},
          {html_id, "html", html_attrs, remaining_children}
        ]

        {stack, nid}

      nil ->
        # No head found, create one
        {[{nid, "head", %{}, []}, {html_id, "html", html_attrs, children}], nid + 1}
    end
  end

  defp reopen_head([current | rest], nid) do
    {rest, nid} = reopen_head(rest, nid)
    {[current | rest], nid}
  end

  defp reopen_head([], nid), do: {[], nid}

  # Find head in children list and return it along with remaining children
  defp find_and_remove_head([], _acc), do: nil

  defp find_and_remove_head([{id, "head", attrs, children} | rest], acc) do
    {{id, attrs, children}, Enum.reverse(acc) ++ rest}
  end

  defp find_and_remove_head([child | rest], acc) do
    find_and_remove_head(rest, [child | acc])
  end

  # --------------------------------------------------------------------------
  # Foster parenting
  # --------------------------------------------------------------------------

  # Foster-parent a start tag: insert element before table in DOM, but keep on stack
  defp process_foster_start_tag(tag, attrs, self_closing, stack, af, nid) do
    if self_closing or tag in @void_elements do
      # Self-closing/void: just add as foster child, don't push to stack
      {foster_element(stack, {tag, attrs, []}), af, nid}
    else
      # Non-void: add to stack before table context, and as foster child
      {stack, nid, new_id} = foster_push_element(stack, nid, tag, attrs)
      # Track formatting elements in AF
      af =
        if tag in @formatting_elements do
          apply_noahs_ark([{new_id, tag, attrs} | af], tag, attrs)
        else
          af
        end

      {stack, af, nid}
    end
  end

  # Push element onto stack in foster parent position (before table context)
  # Also adds the element as a foster child of the element before table
  defp foster_push_element(stack, nid, tag, attrs) do
    new_elem = {nid, tag, attrs, []}
    do_foster_push(stack, new_elem, nid + 1, [])
  end

  defp do_foster_push([{id, "table", tbl_attrs, tbl_children} | rest], new_elem, nid, acc) do
    # Found table - insert new element at TOP of stack to receive content
    # Previously foster-parented elements (in acc) go BELOW the new element
    # Stack order: [new_elem, acc (reversed), table, rest]
    table_and_below = [{id, "table", tbl_attrs, tbl_children} | rest]
    stack = [new_elem | rebuild_stack(acc, table_and_below)]
    {new_id, _, _, _} = new_elem
    {stack, nid, new_id}
  end

  defp do_foster_push([current | rest], new_elem, nid, acc) do
    do_foster_push(rest, new_elem, nid, [current | acc])
  end

  defp do_foster_push([], new_elem, nid, acc) do
    # No table found - just push normally
    {new_id, _, _, _} = new_elem
    {Enum.reverse([new_elem | acc]), nid, new_id}
  end

  # Foster-parent a void/self-closing element (add before table, don't push to stack)
  defp foster_element(stack, element) do
    foster_content(stack, element, [], &add_foster_child/2)
  end

  defp add_foster_child(stack, element) do
    add_child(stack, element)
  end

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

  # Reconstruct active formatting elements in foster parent context
  # Returns {stack, af, nid, reconstructed?}
  defp foster_reconstruct_active_formatting(stack, af, nid) do
    # Find entries in AF that are not on the stack (before any marker)
    entries_to_reconstruct =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {id, _tag, _attrs} ->
        find_in_stack_by_id(stack, id) == nil
      end)

    if entries_to_reconstruct == [] do
      {stack, af, nid, false}
    else
      {stack, af, nid} = foster_reconstruct_entries(stack, af, nid, entries_to_reconstruct)
      {stack, af, nid, true}
    end
  end

  defp foster_reconstruct_entries(stack, af, nid, []), do: {stack, af, nid}

  defp foster_reconstruct_entries(stack, af, nid, [{old_id, tag, attrs} | rest]) do
    # Foster-push the new element
    {stack, nid, new_id} = foster_push_element(stack, nid, tag, attrs)
    # Update AF: replace old entry with new one
    new_af = update_af_entry(af, old_id, {new_id, tag, attrs})
    foster_reconstruct_entries(stack, new_af, nid, rest)
  end

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

  defp foreign_namespace(stack) do
    Enum.find_value(stack, fn
      {_, {ns, _}, _, _} when ns in [:svg, :math] -> ns
      _ -> nil
    end)
  end

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
      {:found, element, rest} -> foster_aware_add_child(rest, element)
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

  # Template creates a scope boundary - don't look beyond it
  defp pop_until(_tag, [{_, "template", _, _} | _], _acc), do: :not_found

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
    |> ensure_head_final()
    |> ensure_body_final()
    |> do_finalize()
    |> strip_ids()
  end

  defp close_through_head([{_, "html", _, _}] = stack), do: stack
  defp close_through_head([{_, "body", _, _} | _] = stack), do: stack

  defp close_through_head([{id, tag, attrs, children} | rest]) do
    child = {id, tag, attrs, children}
    # Use foster-aware closing so elements don't get put inside table
    close_through_head(foster_aware_add_child(rest, child))
  end

  defp close_through_head([]), do: [{0, "html", %{}, [{1, "head", %{}, []}]}]

  # Ensure head exists during finalization
  defp ensure_head_final([{html_id, "html", attrs, children}]) do
    if has_tag?(children, "head") do
      [{html_id, "html", attrs, children}]
    else
      # Add empty head to html's children
      [{html_id, "html", attrs, [{0, "head", %{}, []} | children]}]
    end
  end

  defp ensure_head_final([current | rest]) do
    [current | ensure_head_final(rest)]
  end

  defp ensure_head_final([]), do: []

  # Ensure body exists during finalization (doesn't need nid tracking)
  defp ensure_body_final([{_, "body", _, _} | _] = stack), do: stack

  defp ensure_body_final([{html_id, "html", attrs, children}]) do
    [{0, "body", %{}, []}, {html_id, "html", attrs, children}]
  end

  defp ensure_body_final([current | rest]) do
    [current | ensure_body_final(rest)]
  end

  defp ensure_body_final([]), do: []

  defp do_finalize([]), do: nil

  defp do_finalize([{id, tag, attrs, children}]) do
    {id, tag, attrs, reverse_all(children)}
  end

  defp do_finalize([{id, tag, attrs, children} | rest]) do
    child = {id, tag, attrs, children}
    # Check if we need foster-closing (next element is in table context)
    do_finalize(foster_aware_add_child(rest, child))
  end

  # Add child to parent, but if parent is in table context and child is NOT
  # a valid table element, skip to body (foster-parenting)
  defp foster_aware_add_child([{_, next_tag, _, _} | _] = rest, child)
       when next_tag in @table_context do
    # Only foster-parent if child is not a valid table element
    # But check if we have a body to foster to first
    case child do
      {_, child_tag, _, _} when child_tag in @table_elements ->
        add_child(rest, child)

      _ ->
        if has_tag?(rest, "body") do
          foster_add_to_body(rest, child, [])
        else
          # No body to foster to (e.g., inside template in head) - add normally
          add_child(rest, child)
        end
    end
  end

  defp foster_aware_add_child(rest, child) do
    add_child(rest, child)
  end

  # Skip over table context elements and add child to body
  defp foster_add_to_body([{_, "body", _, _} | _] = stack, child, acc) do
    rebuild_stack(acc, add_child(stack, child))
  end

  defp foster_add_to_body([current | rest], child, acc) do
    foster_add_to_body(rest, child, [current | acc])
  end

  defp foster_add_to_body([], child, acc) do
    # No body found, just add normally
    Enum.reverse([child | acc])
  end

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

  defp strip_ids({id, "template", attrs, children}) when is_integer(id) do
    # Template elements have their children wrapped in a content document fragment
    stripped_children = Enum.map(children, &strip_ids/1)
    {"template", attrs, [{:content, stripped_children}]}
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
