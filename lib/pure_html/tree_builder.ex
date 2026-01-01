defmodule PureHtml.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a stream of tokens.

  Uses:
  - State struct with stack, active formatting list, and insertion mode
  - make_ref() for element IDs (no counter to pass around)
  - Insertion modes for O(1) context checks

  Elements during parsing: %{ref: ref, tag: tag, attrs: map, children: list}
  Final output: {tag, attrs, children} tuples (Floki-compatible)
  """

  # --------------------------------------------------------------------------
  # State and Element structures
  # --------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct stack: [], af: [], mode: :initial, mode_stack: []
  end

  # Insertion modes (subset of HTML5 spec)
  # :initial      - No html yet
  # :before_head  - html exists, no head
  # :in_head      - Inside head element
  # :after_head   - Head closed, no body yet
  # :in_body      - Inside body element
  # :in_table     - Inside table
  # :in_select    - Inside select element
  # :in_template  - Inside template element

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)
  @table_cells ~w(td th)
  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @table_elements ~w(table caption colgroup col thead tbody tfoot tr td th script template style)

  @closes_p ~w(address article aside blockquote center details dialog dir div dl dd dt
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr li listing main menu nav ol p plaintext pre rb rp rt rtc section summary table ul)

  # Tags that implicitly close other tags (key always closes itself plus listed tags)
  @implicit_closes %{
    "li" => [],
    "dt" => ["dd"],
    "dd" => ["dt"],
    "button" => [],
    "option" => [],
    "optgroup" => ["option"],
    "tr" => [],
    "td" => ["th"],
    "th" => ["td"],
    "h1" => ["h2", "h3", "h4", "h5", "h6"],
    "h2" => ["h1", "h3", "h4", "h5", "h6"],
    "h3" => ["h1", "h2", "h4", "h5", "h6"],
    "h4" => ["h1", "h2", "h3", "h5", "h6"],
    "h5" => ["h1", "h2", "h3", "h4", "h6"],
    "h6" => ["h1", "h2", "h3", "h4", "h5"],
    "rb" => ["rt", "rtc", "rp"],
    "rt" => ["rb", "rp"],
    "rtc" => ["rb", "rt", "rp"],
    "rp" => ["rb", "rt"]
  }

  @tag_corrections %{"image" => "img"}

  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

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
  """
  def build(tokens) do
    {doctype, %State{stack: stack}, pre_html_comments} =
      Enum.reduce(tokens, {nil, %State{}, []}, fn
        {:doctype, name, public_id, system_id, _}, {_, state, comments} ->
          {{name, public_id, system_id}, state, comments}

        {:comment, text}, {doctype, %State{stack: []} = state, comments} ->
          {doctype, state, [{:comment, text} | comments]}

        token, {doctype, state, comments} ->
          {doctype, process(token, state), comments}
      end)

    html_node = finalize(stack)
    nodes = Enum.reverse(pre_html_comments) ++ [html_node]
    {doctype, nodes}
  end

  # --------------------------------------------------------------------------
  # Element creation helpers
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs \\ %{}) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  defp new_foreign_element(ns, tag, attrs) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: []}
  end

  # --------------------------------------------------------------------------
  # Token processing
  # --------------------------------------------------------------------------

  defp process({:start_tag, "html", attrs, _}, %State{stack: []} = state) do
    %{state | stack: [new_element("html", attrs)], mode: :before_head}
  end

  defp process({:start_tag, "html", _attrs, _}, state), do: state

  defp process({:start_tag, "head", attrs, _}, state) do
    state
    |> ensure_html()
    |> push_element("head", attrs)
    |> set_mode(:in_head)
  end

  defp process({:start_tag, "body", attrs, _}, state) do
    state
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> then(fn
      %State{mode: :after_head} = s ->
        s
        |> push_element("body", attrs)
        |> set_mode(:in_body)

      s ->
        s
    end)
  end

  defp process({:start_tag, "svg", attrs, self_closing}, state) do
    state
    |> in_body()
    |> push_foreign_element(:svg, "svg", attrs, self_closing)
  end

  defp process({:start_tag, "math", attrs, self_closing}, state) do
    state
    |> in_body()
    |> push_foreign_element(:math, "math", attrs, self_closing)
  end

  defp process({:start_tag, tag, attrs, self_closing}, %State{stack: stack} = state) do
    tag = Map.get(@tag_corrections, tag, tag)
    ns = foreign_namespace(stack)

    cond do
      is_nil(ns) or html_integration_point?(stack) ->
        process_html_start_tag(tag, attrs, self_closing, state)

      html_breakout_tag?(tag) ->
        state = close_foreign_content(state)
        process_html_start_tag(tag, attrs, self_closing, state)

      true ->
        push_foreign_element(state, ns, tag, attrs, self_closing)
    end
  end

  defp process({:end_tag, "html"}, state) do
    state
    |> close_head()
    |> ensure_body()
  end

  defp process({:end_tag, "head"}, state), do: close_head(state)
  defp process({:end_tag, "body"}, state), do: state

  defp process({:end_tag, tag}, %State{stack: stack, af: af} = state) when tag in @table_cells do
    %{state | stack: close_tag(tag, stack), af: clear_af_to_marker(af)}
  end

  defp process({:end_tag, "table"}, %State{stack: stack} = state) do
    stack = clear_to_table_context(stack)
    %{state | stack: close_tag("table", stack)} |> pop_mode()
  end

  defp process({:end_tag, tag}, state) when tag in @formatting_elements do
    run_adoption_agency(state, tag)
  end

  defp process({:end_tag, "p"}, %State{stack: stack, mode: :in_body} = state) do
    case close_p_in_scope(stack) do
      {:found, new_stack} -> %{state | stack: new_stack}
      :not_found -> add_child_to_stack(state, new_element("p"))
    end
  end

  defp process({:end_tag, "p"}, %State{stack: stack} = state) do
    case close_p_in_scope(stack) do
      {:found, new_stack} -> %{state | stack: new_stack}
      :not_found -> state
    end
  end

  defp process({:end_tag, "br"}, state) do
    process({:start_tag, "br", %{}, true}, state)
  end

  defp process({:end_tag, "select"}, %State{stack: stack} = state) do
    %{state | stack: close_tag("select", stack)} |> pop_mode()
  end

  defp process({:end_tag, "template"}, %State{stack: stack, af: af} = state) do
    %{state | stack: close_tag("template", stack), af: clear_af_to_marker(af)} |> pop_mode()
  end

  defp process({:end_tag, tag}, %State{stack: stack} = state) do
    %{state | stack: close_tag(tag, stack)}
  end

  defp process({:character, text}, %State{stack: []} = state) do
    state
    |> ensure_html()
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
  end

  defp process({:character, text}, %State{stack: [%{tag: tag} | _]} = state)
       when tag in @head_elements do
    add_text_to_stack(state, text)
  end

  defp process({:character, text}, %State{stack: [%{tag: tag} | _]} = state)
       when tag in @table_context do
    {state, reconstructed} = foster_reconstruct_active_formatting(state)

    if reconstructed do
      add_text_to_stack(state, text)
    else
      foster_text_to_stack(state, text)
    end
  end

  # Whitespace-only text before body - ignore
  defp process({:character, text}, %State{mode: mode} = state)
       when mode in [:initial, :before_head, :in_head, :after_head] do
    case String.trim(text) do
      "" ->
        state

      _ ->
        state
        |> in_body()
        |> reconstruct_active_formatting()
        |> add_text_to_stack(text)
    end
  end

  # In body modes - process text
  defp process({:character, text}, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
  end

  defp process({:comment, _text}, %State{stack: []} = state), do: state

  defp process({:comment, text}, state) do
    add_child_to_stack(state, {:comment, text})
  end

  defp process({:error, _}, state), do: state

  # --------------------------------------------------------------------------
  # HTML start tag processing
  # --------------------------------------------------------------------------

  defp process_html_start_tag(tag, attrs, self_closing, %State{stack: stack} = state)
       when tag not in @table_elements do
    # Foster parent in table context, unless inside select (which creates a boundary)
    if in_table_context?(stack) and not in_select?(stack) do
      process_foster_start_tag(tag, attrs, self_closing, state)
    else
      do_process_html_start_tag(tag, attrs, self_closing, state)
    end
  end

  defp process_html_start_tag(tag, attrs, self_closing, state) do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  # Head elements in body modes - just process
  defp do_process_html_start_tag(tag, attrs, self_closing, %State{mode: mode} = state)
       when tag in @head_elements and mode in [:in_template, :in_body, :in_table, :in_select] do
    process_start_tag(state, tag, attrs, self_closing)
  end

  # Head elements with body in stack but different mode (e.g., foster parenting)
  defp do_process_html_start_tag(tag, attrs, self_closing, %State{stack: stack} = state)
       when tag in @head_elements do
    if has_tag?(stack, "body") do
      process_start_tag(state, tag, attrs, self_closing)
    else
      state
      |> ensure_html()
      |> ensure_head()
      |> maybe_reopen_head()
      |> process_start_tag(tag, attrs, self_closing)
    end
  end

  # Frameset is only valid before body content - ignore if body exists or has content
  defp do_process_html_start_tag("frameset", _, _, %State{mode: :in_body} = state), do: state

  defp do_process_html_start_tag("frameset", attrs, _, %State{stack: stack} = state) do
    if has_tag?(stack, "body") or has_body_content?(stack) do
      state
    else
      state
      |> ensure_html()
      |> close_head()
      |> push_element("frameset", attrs)
    end
  end

  # <frame> is only valid in frameset, ignore in body
  defp do_process_html_start_tag("frame", _, _, state), do: state

  # <col> is only valid in colgroup/table/template context
  defp do_process_html_start_tag("col", attrs, _, %State{mode: mode} = state)
       when mode in [:in_template, :in_table] do
    add_child_to_stack(state, {"col", attrs, []})
  end

  defp do_process_html_start_tag("col", attrs, _, %State{stack: stack} = state) do
    if in_template?(stack) or in_table_context?(stack) do
      add_child_to_stack(state, {"col", attrs, []})
    else
      state
    end
  end

  # <hr> in select context should close option/optgroup first
  defp do_process_html_start_tag("hr", attrs, _, %State{mode: :in_select} = state) do
    state
    |> close_option_optgroup_in_select()
    |> add_child_to_stack({"hr", attrs, []})
  end

  defp do_process_html_start_tag("hr", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("hr")
    |> add_child_to_stack({"hr", attrs, []})
  end

  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @void_elements do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
  end

  defp do_process_html_start_tag(tag, attrs, true, state) do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
  end

  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @table_cells do
    state
    |> in_body()
    |> clear_to_table_body_context()
    |> ensure_table_context()
    |> push_element(tag, attrs)
    |> then(fn s -> %{s | af: [:marker | s.af]} end)
  end

  defp do_process_html_start_tag("tr", attrs, _, state) do
    state
    |> in_body()
    |> clear_to_table_body_context()
    |> ensure_tbody()
    |> push_element("tr", attrs)
  end

  defp do_process_html_start_tag("a", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_existing_a()
    |> push_element("a", attrs)
    |> add_formatting_entry("a", attrs)
  end

  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @formatting_elements do
    state
    |> in_body()
    |> push_element(tag, attrs)
    |> add_formatting_entry(tag, attrs)
  end

  # Table, select, and template push mode onto stack
  defp do_process_html_start_tag("table", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("table")
    |> push_element("table", attrs)
    |> push_mode(:in_table)
  end

  defp do_process_html_start_tag("select", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element("select", attrs)
    |> push_mode(:in_select)
  end

  defp do_process_html_start_tag("template", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> then(fn s -> %{s | af: [:marker | s.af]} end)
  end

  defp do_process_html_start_tag(tag, attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> maybe_close_same(tag)
    |> push_element(tag, attrs)
    |> reconstruct_active_formatting()
  end

  defp process_start_tag(state, tag, attrs, true) do
    add_child_to_stack(state, {tag, attrs, []})
  end

  defp process_start_tag(state, tag, attrs, _) when tag in @void_elements do
    add_child_to_stack(state, {tag, attrs, []})
  end

  defp process_start_tag(state, tag, attrs, _) do
    push_element(state, tag, attrs)
  end

  # --------------------------------------------------------------------------
  # Scope helpers
  # --------------------------------------------------------------------------

  defp in_scope?(nodes, target_tags, boundary_tags) do
    Enum.reduce_while(nodes, false, fn
      %{tag: tag}, _acc ->
        cond do
          tag in target_tags -> {:halt, true}
          tag in boundary_tags -> {:halt, false}
          true -> {:cont, false}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp in_table_context?(stack) do
    in_scope?(stack, ["table" | @table_context], ["template", "body", "html"])
  end

  defp in_select?(stack) do
    in_scope?(stack, ["select"], ["template", "body", "html"])
  end

  # Close option/optgroup if we're in select context
  # <hr> in select should close option first, then optgroup
  defp close_option_optgroup_in_select(%State{stack: [%{tag: tag} = elem | rest]} = state)
       when tag in ["option", "optgroup"] do
    if in_select?(rest) do
      new_state = %{state | stack: foster_aware_add_child(rest, elem)}
      # Recursively close optgroup if option was closed
      close_option_optgroup_in_select(new_state)
    else
      state
    end
  end

  defp close_option_optgroup_in_select(state), do: state

  # --------------------------------------------------------------------------
  # Adoption agency algorithm
  # --------------------------------------------------------------------------

  defp run_adoption_agency(state, subject) do
    run_adoption_agency_outer_loop(state, subject, 0)
  end

  defp run_adoption_agency_outer_loop(state, _subject, iteration) when iteration >= 8, do: state

  defp run_adoption_agency_outer_loop(%State{stack: stack, af: af} = state, subject, iteration) do
    case find_formatting_entry(af, subject) do
      nil ->
        if iteration == 0 do
          %{state | stack: close_tag(subject, stack)}
        else
          state
        end

      {af_idx, {fe_ref, _fe_tag, _fe_attrs}} ->
        case find_in_stack_by_ref(stack, fe_ref) do
          nil ->
            %{state | af: List.delete_at(af, af_idx)}

          stack_idx ->
            case find_furthest_block(stack, stack_idx) do
              nil ->
                {new_stack, new_af} = pop_to_formatting_element(stack, af, af_idx, stack_idx)
                %{state | stack: new_stack, af: new_af}

              fb_idx ->
                {_, fe_tag, fe_attrs} = Enum.at(af, af_idx)

                state =
                  run_adoption_agency_with_furthest_block(
                    state,
                    {af_idx, fe_ref, fe_tag, fe_attrs},
                    stack_idx,
                    fb_idx
                  )

                run_adoption_agency_outer_loop(state, subject, iteration + 1)
            end
        end
    end
  end

  defp find_formatting_entry(af, tag) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{ref, ^tag, attrs}, idx} -> {idx, {ref, tag, attrs}}
      _ -> nil
    end)
  end

  defp has_formatting_entry?(af, tag) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.any?(fn
      {_, ^tag, _} -> true
      _ -> false
    end)
  end

  defp remove_formatting_entry(af, tag) do
    Enum.reject(af, fn
      {_, ^tag, _} -> true
      _ -> false
    end)
  end

  defp find_in_stack_by_ref(stack, target_ref) do
    Enum.find_index(stack, fn
      %{ref: ref} -> ref == target_ref
      _ -> false
    end)
  end

  defp run_adoption_agency_with_furthest_block(
         %State{stack: stack, af: af} = state,
         {af_idx, fe_ref, fe_tag, fe_attrs},
         fe_stack_idx,
         fb_idx
       ) do
    {above_fb, rest1} = Enum.split(stack, fb_idx)
    [fb | rest2] = rest1
    between_count = fe_stack_idx - fb_idx - 1
    {between, [fe | below_fe]} = Enum.split(rest2, between_count)

    %{ref: fb_ref, tag: fb_tag, attrs: fb_attrs, children: fb_children} = fb

    {formatting_between, block_between} = partition_between_elements(between, af)
    {formatting_to_clone_list, _formatting_to_close} = Enum.split(formatting_between, 3)

    %{children: fe_children} = fe
    fe_children = close_elements_into(formatting_between, fe_children)
    closed_fe = %{ref: fe_ref, tag: fe_tag, attrs: fe_attrs, children: fe_children}
    below_fe = foster_aware_add_child(below_fe, closed_fe)

    new_fe_clone = %{ref: make_ref(), tag: fe_tag, attrs: fe_attrs, children: fb_children}

    fb_empty = %{ref: fb_ref, tag: fb_tag, attrs: fb_attrs, children: []}

    formatting_to_clone = Enum.map(formatting_to_clone_list, &{&1.tag, &1.attrs})

    formatting_stack_elements = create_formatting_stack_elements(formatting_to_clone)

    block_with_clones = wrap_children_with_fe_clone(block_between, fe_tag, fe_attrs)

    final_stack =
      above_fb ++
        [new_fe_clone, fb_empty | formatting_stack_elements] ++
        Enum.reverse(block_with_clones) ++ below_fe

    af = remove_formatting_from_af(af, af_idx, formatting_between)
    af = [{new_fe_clone.ref, fe_tag, fe_attrs} | af]

    %{state | stack: final_stack, af: af}
  end

  defp partition_between_elements(between, af) do
    Enum.split_with(between, fn %{ref: elem_ref} ->
      find_af_entry_by_ref(af, elem_ref) != nil
    end)
  end

  defp find_af_entry_by_ref(af, target_ref) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{^target_ref, tag, attrs}, idx} -> {idx, {target_ref, tag, attrs}}
      _ -> nil
    end)
  end

  defp remove_formatting_from_af(af, fe_idx, formatting_between) do
    af = List.delete_at(af, fe_idx)
    formatting_refs = MapSet.new(formatting_between, & &1.ref)

    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(formatting_refs, ref)
    end)
  end

  defp wrap_children_with_fe_clone(elements, fe_tag, fe_attrs) do
    Enum.map(elements, fn %{ref: ref, tag: tag, attrs: attrs, children: children} ->
      wrapped_children = [{fe_tag, fe_attrs, children}]
      %{ref: ref, tag: tag, attrs: attrs, children: wrapped_children}
    end)
  end

  defp create_formatting_stack_elements(formatting_to_clone) do
    Enum.map(formatting_to_clone, fn {tag, attrs} ->
      new_element(tag, attrs)
    end)
  end

  defp find_furthest_block(stack, fe_idx) do
    elements =
      stack
      |> Enum.take(fe_idx)
      |> Enum.with_index()

    elements
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{tag: tag}, idx} when is_binary(tag) and tag in @special_elements -> idx
      _ -> nil
    end)
  end

  defp pop_to_formatting_element(stack, af, af_idx, stack_idx) do
    {above_fe, [fe | rest]} = Enum.split(stack, stack_idx)

    closed_above =
      Enum.reduce(above_fe, nil, fn elem, inner ->
        children = if inner, do: [inner | elem.children], else: elem.children
        %{elem | children: children}
      end)

    %{ref: fe_ref, tag: fe_tag, attrs: fe_attrs, children: fe_children} = fe
    fe_children = if closed_above, do: [closed_above | fe_children], else: fe_children
    closed_fe = %{ref: fe_ref, tag: fe_tag, attrs: fe_attrs, children: fe_children}

    final_stack = add_child(rest, closed_fe)
    af = List.delete_at(af, af_idx)
    {final_stack, af}
  end

  defp close_elements_into([], children), do: children

  defp close_elements_into(elements, fe_original_children) do
    nested = nest_formatting_elements(elements)
    [nested | fe_original_children]
  end

  defp nest_formatting_elements(elements) do
    elements
    |> Enum.reverse()
    |> do_nest_formatting()
  end

  defp do_nest_formatting([elem]), do: elem

  defp do_nest_formatting([elem | rest]) do
    inner = do_nest_formatting(rest)
    %{elem | children: [inner | elem.children]}
  end

  # --------------------------------------------------------------------------
  # Reconstruct active formatting
  # --------------------------------------------------------------------------

  defp reconstruct_active_formatting(%State{stack: stack, af: af} = state) do
    entries_to_reconstruct =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {ref, _tag, _attrs} ->
        find_in_stack_by_ref(stack, ref) == nil
      end)

    if entries_to_reconstruct == [] do
      state
    else
      reconstruct_entries(state, entries_to_reconstruct)
    end
  end

  defp reconstruct_entries(state, []), do: state

  defp reconstruct_entries(%State{stack: stack, af: af} = state, [{old_ref, tag, attrs} | rest]) do
    new_elem = new_element(tag, attrs)
    new_stack = [new_elem | stack]
    new_af = update_af_entry(af, old_ref, {new_elem.ref, tag, attrs})
    reconstruct_entries(%{state | stack: new_stack, af: new_af}, rest)
  end

  defp update_af_entry(af, old_ref, new_entry) do
    Enum.map(af, fn
      {^old_ref, _, _} -> new_entry
      entry -> entry
    end)
  end

  defp add_formatting_entry(%State{stack: [%{ref: ref} | _], af: af} = state, tag, attrs) do
    %{state | af: apply_noahs_ark([{ref, tag, attrs} | af], tag, attrs)}
  end

  defp maybe_close_existing_a(%State{af: af} = state) do
    if has_formatting_entry?(af, "a") do
      state
      |> run_adoption_agency("a")
      |> then(fn s -> %{s | af: remove_formatting_entry(s.af, "a")} end)
    else
      state
    end
  end

  defp apply_noahs_ark(af, tag, attrs) do
    matching_indices =
      af
      |> Enum.with_index()
      |> Enum.filter(fn
        {:marker, _idx} -> false
        {{_ref, t, a}, _idx} -> t == tag and a == attrs
      end)
      |> Enum.map(fn {_entry, idx} -> idx end)

    if length(matching_indices) > 3 do
      oldest_idx = Enum.max(matching_indices)
      List.delete_at(af, oldest_idx)
    else
      af
    end
  end

  defp clear_af_to_marker(af) do
    af
    |> Enum.drop_while(&(&1 != :marker))
    |> Enum.drop(1)
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  defp clear_to_table_body_context(%State{stack: stack} = state) do
    %{state | stack: do_clear_to_table_body_context(stack)}
  end

  defp do_clear_to_table_body_context([%{tag: tag} | _] = stack)
       when tag in @table_sections or tag in ["table", "template", "html"] do
    stack
  end

  defp do_clear_to_table_body_context([elem | rest]) do
    do_clear_to_table_body_context(foster_aware_add_child(rest, elem))
  end

  defp do_clear_to_table_body_context([]), do: []

  defp clear_to_table_context([%{tag: "table"} | _] = stack), do: stack
  defp clear_to_table_context([%{tag: "template"} | _] = stack), do: stack
  defp clear_to_table_context([%{tag: "html"} | _] = stack), do: stack

  defp clear_to_table_context([elem | rest]) do
    clear_to_table_context(foster_aware_add_child(rest, elem))
  end

  defp clear_to_table_context([]), do: []

  defp ensure_table_context(state) do
    state
    |> ensure_tbody()
    |> ensure_tr()
  end

  defp ensure_tbody(%State{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "tbody", %{})
  end

  defp ensure_tbody(%State{stack: [%{tag: tag} | _]} = state) when tag in @table_sections,
    do: state

  defp ensure_tbody(%State{stack: [%{tag: "tr"} | _]} = state), do: state
  defp ensure_tbody(state), do: state

  defp ensure_tr(%State{stack: [%{tag: tag} | _]} = state) when tag in @table_sections do
    push_element(state, "tr", %{})
  end

  defp ensure_tr(%State{stack: [%{tag: "tr"} | _]} = state), do: state
  defp ensure_tr(state), do: state

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(%State{stack: stack} = state, tag) when tag in @closes_p do
    %{state | stack: close_p_if_open(stack)}
  end

  defp maybe_close_p(state, _tag), do: state

  defp close_p_if_open(stack) do
    case find_p_in_stack(stack, []) do
      nil ->
        stack

      {above_p, %{ref: p_ref, attrs: p_attrs, children: p_children}, below_p} ->
        nested_above =
          above_p
          |> Enum.reduce(nil, fn elem, inner ->
            children = if inner, do: [inner | elem.children], else: elem.children
            %{elem | children: children}
          end)

        p_children = if nested_above, do: [nested_above | p_children], else: p_children
        closed_p = %{ref: p_ref, tag: "p", attrs: p_attrs, children: p_children}

        add_child(below_p, closed_p)
    end
  end

  # Button scope boundaries for closing <p>
  @button_scope_boundaries ~w(applet caption html table td th marquee object template button)

  # Close <p> respecting button scope (for </p> end tag)
  defp close_p_in_scope(stack) do
    case find_p_in_stack(stack, []) do
      nil ->
        :not_found

      {above_p, p_elem, below_p} ->
        nested_above =
          above_p
          |> Enum.reduce(nil, fn elem, inner ->
            children = if inner, do: [inner | elem.children], else: elem.children
            %{elem | children: children}
          end)

        p_children = if nested_above, do: [nested_above | p_elem.children], else: p_elem.children
        closed_p = %{p_elem | children: p_children}
        {:found, foster_aware_add_child(below_p, closed_p)}
    end
  end

  defp find_p_in_stack([], _acc), do: nil

  defp find_p_in_stack([%{ref: ref, tag: "p", attrs: attrs, children: children} | rest], acc) do
    {Enum.reverse(acc), %{ref: ref, tag: "p", attrs: attrs, children: children}, rest}
  end

  defp find_p_in_stack([%{tag: tag} | _rest], _acc) when tag in @button_scope_boundaries do
    nil
  end

  # Foreign elements (SVG/MathML) are also scope boundaries
  defp find_p_in_stack([%{tag: {ns, _}} | _rest], _acc) when ns in [:svg, :math] do
    nil
  end

  defp find_p_in_stack([elem | rest], acc) do
    find_p_in_stack(rest, [elem | acc])
  end

  # Scope boundaries that prevent implicit closing
  @implicit_close_boundaries ~w(table template body html)

  for {tag, also_closes} <- @implicit_closes do
    closes = [tag | also_closes]

    defp maybe_close_same(%State{stack: stack} = state, unquote(tag)) do
      case pop_to_implicit_close(stack, unquote(closes), []) do
        {:ok, new_stack} -> %{state | stack: new_stack}
        :not_found -> state
      end
    end
  end

  defp maybe_close_same(state, _tag), do: state

  defp pop_to_implicit_close([], _closes, _acc), do: :not_found

  defp pop_to_implicit_close([%{tag: tag} | _], _closes, _acc)
       when tag in @implicit_close_boundaries,
       do: :not_found

  defp pop_to_implicit_close([%{tag: tag} = elem | rest], closes, acc) do
    if tag in closes do
      # Found match - first close accumulated elements into the target, then close target
      closed_elem = Enum.reduce(acc, elem, &add_child_to_elem/2)
      {:ok, add_child(rest, closed_elem)}
    else
      pop_to_implicit_close(rest, closes, [elem | acc])
    end
  end

  defp add_child_to_elem(child, parent) do
    %{parent | children: [close_element(child) | parent.children]}
  end

  defp close_element(%{children: children} = elem) do
    %{elem | children: Enum.reverse(children)}
  end

  defp close_element(other), do: other

  # --------------------------------------------------------------------------
  # Mode transitions
  # --------------------------------------------------------------------------

  # Already in body - fast path (O(1) instead of scanning stack)
  defp transition_to(%State{mode: mode} = state, :in_body)
       when mode in [:in_body, :in_select, :in_table, :in_template],
       do: state

  # Transition to in_body from earlier modes
  defp transition_to(%State{mode: :initial} = state, :in_body) do
    state
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> ensure_body()
    |> set_mode(:in_body)
  end

  defp transition_to(%State{mode: :before_head} = state, :in_body) do
    state
    |> ensure_head()
    |> close_head()
    |> ensure_body()
    |> set_mode(:in_body)
  end

  defp transition_to(%State{mode: :in_head} = state, :in_body) do
    state
    |> close_head()
    |> ensure_body()
    |> set_mode(:in_body)
  end

  defp transition_to(%State{mode: :after_head} = state, :in_body) do
    state
    |> ensure_body()
    |> set_mode(:in_body)
  end

  defp set_mode(state, mode), do: %{state | mode: mode}

  defp push_mode(%State{mode: current_mode, mode_stack: stack} = state, new_mode) do
    %{state | mode: new_mode, mode_stack: [current_mode | stack]}
  end

  defp pop_mode(%State{mode_stack: [prev_mode | rest]} = state) do
    %{state | mode: prev_mode, mode_stack: rest}
  end

  defp pop_mode(%State{mode_stack: []} = state) do
    %{state | mode: :in_body}
  end

  # --------------------------------------------------------------------------
  # Document structure
  # --------------------------------------------------------------------------

  defp in_body(%State{mode: mode} = state)
       when mode in [:in_body, :in_select, :in_table, :in_template] do
    state
  end

  defp in_body(%State{stack: stack} = state) do
    if in_template?(stack) do
      state
    else
      transition_to(state, :in_body)
    end
  end

  defp in_template?(stack) do
    in_scope?(stack, ["template"], ["html", "body", "head"])
  end

  defp ensure_html(%State{stack: []} = state) do
    %{state | stack: [new_element("html")], mode: :before_head}
  end

  defp ensure_html(%State{stack: [%{tag: "html"} | _]} = state), do: state
  defp ensure_html(state), do: state

  defp ensure_head(%State{stack: [%{tag: "html"} = html]} = state) do
    ensure_head_check([html], state)
  end

  defp ensure_head(%State{stack: [%{tag: "head"} | _]} = state), do: state
  defp ensure_head(%State{stack: [%{tag: "body"} | _]} = state), do: state
  defp ensure_head(state), do: state

  defp ensure_head_check([%{tag: "html", children: [%{tag: "head"} | _]}], state), do: state

  defp ensure_head_check([%{tag: "html", children: [_ | rest]} = html], state) do
    ensure_head_check([%{html | children: rest}], state)
  end

  defp ensure_head_check([%{tag: "html", children: []}], %State{stack: [html]} = state) do
    head = new_element("head")
    %{state | stack: [head, html], mode: :in_head}
  end

  defp close_head(%State{stack: [%{tag: "head"} = head | rest]} = state) do
    %{state | stack: add_child(rest, head), mode: :after_head}
  end

  defp close_head(state), do: state

  defp ensure_body(%State{stack: [%{tag: "body"} | _]} = state), do: state

  defp ensure_body(%State{stack: [%{tag: "html"} = html]} = state) do
    body = new_element("body")
    %{state | stack: [body, html], mode: :in_body}
  end

  defp ensure_body(%State{stack: [current | rest]} = state) do
    %State{stack: new_rest} = ensure_body(%{state | stack: rest})
    %{state | stack: [current | new_rest]}
  end

  defp ensure_body(%State{stack: []} = state), do: state

  defp has_tag?(nodes, tag) do
    Enum.any?(nodes, fn
      %{tag: t} -> t == tag
      _ -> false
    end)
  end

  # Check if stack has any body content (elements other than html/head, or text)
  defp has_body_content?(stack) do
    Enum.any?(stack, fn
      %{tag: tag} -> tag not in ["html", "head"]
      _ -> true
    end)
  end

  defp reopen_head_for_element([%{tag: "html", children: children} = html]) do
    case Enum.split_while(children, &(not match?(%{tag: "head"}, &1))) do
      {before, [head | after_head]} ->
        remaining_children = Enum.reverse(before) ++ after_head
        [head, %{html | children: remaining_children}]

      _ ->
        [new_element("head"), html]
    end
  end

  defp reopen_head_for_element([current | rest]) do
    [current | reopen_head_for_element(rest)]
  end

  defp reopen_head_for_element([]), do: []

  defp maybe_reopen_head(%State{mode: :in_head} = state), do: state

  defp maybe_reopen_head(%State{stack: stack} = state) do
    %{state | stack: reopen_head_for_element(stack)}
  end

  # --------------------------------------------------------------------------
  # Foster parenting
  # --------------------------------------------------------------------------

  defp process_foster_start_tag(tag, attrs, self_closing, %State{stack: stack, af: af} = state) do
    if self_closing or tag in @void_elements do
      %{state | stack: foster_element(stack, {tag, attrs, []})}
    else
      {new_stack, new_ref} = foster_push_element(stack, tag, attrs)

      new_af =
        if tag in @formatting_elements do
          apply_noahs_ark([{new_ref, tag, attrs} | af], tag, attrs)
        else
          af
        end

      %{state | stack: new_stack, af: new_af}
    end
  end

  defp foster_push_element(stack, tag, attrs) do
    new_elem = new_element(tag, attrs)
    {do_foster_push(stack, new_elem, []), new_elem.ref}
  end

  defp do_foster_push([%{tag: "table"} = table | rest], new_elem, acc) do
    table_and_below = [table | rest]
    [new_elem | rebuild_stack(acc, table_and_below)]
  end

  defp do_foster_push([current | rest], new_elem, acc) do
    do_foster_push(rest, new_elem, [current | acc])
  end

  defp do_foster_push([], new_elem, acc) do
    Enum.reverse([new_elem | acc])
  end

  defp foster_element(stack, element) do
    foster_content(stack, element, [], &add_foster_child/2)
  end

  defp add_foster_child(stack, element) do
    add_child(stack, element)
  end

  defp foster_text(stack, text) do
    foster_content(stack, text, [], &add_foster_text/2)
  end

  defp foster_content([%{tag: "table"} = table | rest], content, acc, add_fn) do
    rest = add_fn.(rest, content)
    rebuild_stack(acc, [table | rest])
  end

  defp foster_content([current | rest], content, acc, add_fn) do
    foster_content(rest, content, [current | acc], add_fn)
  end

  defp foster_content([], _content, acc, _add_fn) do
    Enum.reverse(acc)
  end

  defp add_foster_text([%{children: [prev | children]} = elem | rest], text)
       when is_binary(prev) do
    [%{elem | children: [prev <> text | children]} | rest]
  end

  defp add_foster_text([%{children: children} = elem | rest], text) do
    [%{elem | children: [text | children]} | rest]
  end

  defp add_foster_text([], _text), do: []

  defp foster_reconstruct_active_formatting(%State{stack: stack, af: af} = state) do
    entries_to_reconstruct =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {ref, _tag, _attrs} ->
        find_in_stack_by_ref(stack, ref) == nil
      end)

    if entries_to_reconstruct == [] do
      {state, false}
    else
      {foster_reconstruct_entries(state, entries_to_reconstruct), true}
    end
  end

  defp foster_reconstruct_entries(state, []), do: state

  defp foster_reconstruct_entries(%State{stack: stack, af: af} = state, [
         {old_ref, tag, attrs} | rest
       ]) do
    {new_stack, new_ref} = foster_push_element(stack, tag, attrs)
    new_af = update_af_entry(af, old_ref, {new_ref, tag, attrs})
    foster_reconstruct_entries(%{state | stack: new_stack, af: new_af}, rest)
  end

  defp rebuild_stack([], stack), do: stack
  defp rebuild_stack([elem | rest], stack), do: rebuild_stack(rest, [elem | stack])

  # --------------------------------------------------------------------------
  # Stack operations
  # --------------------------------------------------------------------------

  defp push_element(%State{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  defp push_foreign_element(state, ns, tag, attrs, self_closing \\ false)

  defp push_foreign_element(%State{stack: stack} = state, ns, tag, attrs, true) do
    %{state | stack: add_child(stack, {{ns, tag}, attrs, []})}
  end

  defp push_foreign_element(%State{stack: stack} = state, ns, tag, attrs, _) do
    %{state | stack: [new_foreign_element(ns, tag, attrs) | stack]}
  end

  defp foreign_namespace(stack) do
    Enum.find_value(stack, fn
      %{tag: {ns, _}} when ns in [:svg, :math] -> ns
      _ -> nil
    end)
  end

  # HTML integration points allow HTML content inside foreign elements
  @html_integration_encodings ["text/html", "application/xhtml+xml"]

  defp html_integration_point?([%{tag: {:svg, tag}} | _])
       when tag in ~w(foreignObject desc title),
       do: true

  defp html_integration_point?([
         %{tag: {:math, "annotation-xml"}, attrs: %{"encoding" => encoding}} | _
       ]) do
    String.downcase(encoding) in @html_integration_encodings
  end

  # MathML text integration points
  defp html_integration_point?([%{tag: {:math, tag}} | _]) when tag in ~w(mi mo mn ms mtext),
    do: true

  defp html_integration_point?(_), do: false

  # Tags that break out of foreign content (SVG/MathML) back to HTML
  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  defp html_breakout_tag?(tag), do: tag in @html_breakout_tags

  defp close_foreign_content(%State{stack: stack} = state) do
    {foreign, rest} =
      Enum.split_while(stack, fn
        %{tag: {ns, _}} when ns in [:svg, :math] -> true
        _ -> false
      end)

    closed =
      Enum.reduce(foreign, nil, fn elem, inner ->
        children = if inner, do: [inner | elem.children], else: elem.children
        %{elem | children: children}
      end)

    new_stack = if closed, do: add_child(rest, closed), else: rest
    %{state | stack: new_stack}
  end

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], child) do
    [child]
  end

  defp add_text([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text([], _text), do: []

  defp add_text_to_stack(%State{stack: stack} = state, text) do
    %{state | stack: add_text(stack, text)}
  end

  defp add_child_to_stack(%State{stack: stack} = state, child) do
    %{state | stack: add_child(stack, child)}
  end

  defp foster_text_to_stack(%State{stack: stack} = state, text) do
    %{state | stack: foster_text(stack, text)}
  end

  defp close_tag(tag, stack) do
    case pop_until(tag, stack, []) do
      {:found, element, rest} -> foster_aware_add_child(rest, element)
      :not_found -> stack
    end
  end

  defp pop_until(_target, [], _acc), do: :not_found

  defp pop_until(target, [%{tag: elem_tag} = elem | rest], acc) when elem_tag == target do
    finalize_pop(elem, acc, rest)
  end

  defp pop_until(target, [%{tag: {:svg, svg_tag}} = elem | rest], acc) when svg_tag == target do
    finalize_pop(elem, acc, rest)
  end

  defp pop_until(_target, [%{tag: "template"} | _], _acc), do: :not_found

  defp pop_until(target, [current | rest], acc) do
    pop_until(target, rest, [current | acc])
  end

  defp finalize_pop(elem, acc, rest) do
    nested_above =
      acc
      |> Enum.reverse()
      |> Enum.reduce(nil, fn e, inner ->
        children = if inner, do: [inner | e.children], else: e.children
        %{e | children: children}
      end)

    children = if nested_above, do: [nested_above | elem.children], else: elem.children
    {:found, %{elem | children: children}, rest}
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
    |> convert_to_tuples()
  end

  defp close_through_head([%{tag: "html"}] = stack), do: stack
  defp close_through_head([%{tag: "body"} | _] = stack), do: stack

  defp close_through_head([elem | rest]) do
    close_through_head(foster_aware_add_child(rest, elem))
  end

  defp close_through_head([]) do
    [%{new_element("html") | children: [new_element("head")]}]
  end

  defp ensure_head_final([%{tag: "html", children: children} = html]) do
    if has_tag?(children, "head") do
      [html]
    else
      [%{html | children: children ++ [new_element("head")]}]
    end
  end

  defp ensure_head_final([current | rest]) do
    [current | ensure_head_final(rest)]
  end

  defp ensure_head_final([]), do: []

  defp ensure_body_final([%{tag: "body"} | _] = stack), do: stack
  defp ensure_body_final([%{tag: "frameset"} | _] = stack), do: stack

  defp ensure_body_final([%{tag: "html", children: children} = html]) do
    if has_tag?(children, "frameset") do
      [html]
    else
      [new_element("body"), html]
    end
  end

  defp ensure_body_final([current | rest]) do
    [current | ensure_body_final(rest)]
  end

  defp ensure_body_final([]), do: []

  defp do_finalize([]), do: nil

  defp do_finalize([elem]) do
    %{elem | children: reverse_all(elem.children)}
  end

  defp do_finalize([elem | rest]) do
    do_finalize(foster_aware_add_child(rest, elem))
  end

  defp foster_aware_add_child([%{tag: next_tag} | _] = rest, child)
       when next_tag in @table_context do
    case child do
      %{tag: child_tag} when child_tag in @table_elements ->
        add_child(rest, child)

      _ ->
        if has_tag?(rest, "body") do
          foster_add_to_body(rest, child, [])
        else
          add_child(rest, child)
        end
    end
  end

  defp foster_aware_add_child(rest, child) do
    add_child(rest, child)
  end

  defp foster_add_to_body([%{tag: "body"} | _] = stack, child, acc) do
    rebuild_stack(acc, add_child(stack, child))
  end

  defp foster_add_to_body([current | rest], child, acc) do
    foster_add_to_body(rest, child, [current | acc])
  end

  defp foster_add_to_body([], child, acc) do
    Enum.reverse([child | acc])
  end

  defp reverse_all(children) do
    children
    |> Enum.reverse()
    |> Enum.map(fn
      %{children: kids} = elem ->
        %{elem | children: reverse_all(kids)}

      {:comment, _} = comment ->
        comment

      text when is_binary(text) ->
        text

      {tag, attrs, kids} ->
        {tag, attrs, reverse_all(kids)}
    end)
  end

  defp convert_to_tuples(nil), do: nil

  defp convert_to_tuples(%{tag: {ns, tag}, attrs: attrs, children: children}) do
    {{ns, tag}, attrs, Enum.map(children, &convert_to_tuples/1)}
  end

  defp convert_to_tuples(%{tag: "template", attrs: attrs, children: children}) do
    stripped_children = Enum.map(children, &convert_to_tuples/1)
    {"template", attrs, [{:content, stripped_children}]}
  end

  defp convert_to_tuples(%{tag: tag, attrs: attrs, children: children}) do
    {tag, attrs, Enum.map(children, &convert_to_tuples/1)}
  end

  defp convert_to_tuples({{ns, tag}, attrs, children}) do
    {{ns, tag}, attrs, Enum.map(children, &convert_to_tuples/1)}
  end

  defp convert_to_tuples({tag, attrs, children}) when is_binary(tag) do
    {tag, attrs, Enum.map(children, &convert_to_tuples/1)}
  end

  defp convert_to_tuples({:comment, text}), do: {:comment, text}
  defp convert_to_tuples(text) when is_binary(text), do: text
end
