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
    # frameset_ok: true until we see content that disables frameset
    defstruct stack: [], af: [], mode: :initial, mode_stack: [], frameset_ok: true
  end

  # Insertion modes (subset of HTML5 spec)
  # :initial        - No html yet
  # :before_head    - html exists, no head
  # :in_head        - Inside head element
  # :after_head     - Head closed, no body yet
  # :in_body        - Inside body element
  # :in_table       - Inside table
  # :in_select      - Inside select element
  # :in_template    - Inside template element
  # :in_frameset    - Inside frameset element
  # :after_frameset - After frameset closed

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)
  @table_cells ~w(td th)
  @table_sections ~w(tbody thead tfoot)
  @table_row_context ~w(tr tbody thead tfoot)
  @table_context ~w(table tbody thead tfoot tr)
  @table_elements ~w(table caption colgroup col thead tbody tfoot tr td th script template style)

  # Scope boundaries for "have an element in scope" - adoption agency check
  @scope_boundaries ~w(applet caption html marquee object table td th template)

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

  # Elements that set the frameset-ok flag to "not ok" (per HTML5 spec)
  @frameset_disabling_elements ~w(pre listing form textarea xmp iframe noembed noframes select embed
                                  keygen applet marquee object table button img input hr br wbr area
                                  dd dt li plaintext rb rtc)

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
        # Doctype only matters in initial mode
        {:doctype, name, public_id, system_id, _}, {_, %State{mode: :initial} = state, comments} ->
          {{name, public_id, system_id}, state, comments}

        # Doctype after initial mode is ignored
        {:doctype, _, _, _, _}, acc ->
          acc

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

  defp process({:start_tag, "html", attrs, _}, state), do: merge_html_attrs(state, attrs)

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
        |> set_frameset_not_ok()

      s ->
        # Seeing <body> token always sets frameset_ok to false
        set_frameset_not_ok(s)
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

  defp process({:end_tag, "table"}, %State{stack: stack, af: af} = state) do
    # Find elements that will be closed (everything above and including the table)
    closed_refs = get_refs_to_close_for_table(stack)
    af = reject_refs_from_af(af, closed_refs)

    stack = do_clear_to_table_context(stack)
    %{state | stack: close_tag("table", stack), af: af} |> pop_mode()
  end

  defp process({:end_tag, tag}, state) when tag in @formatting_elements do
    run_adoption_agency(state, tag)
  end

  defp process({:end_tag, "p"}, %State{stack: stack, mode: mode} = state) do
    case close_p_in_scope(stack) do
      {:found, new_stack} ->
        %{state | stack: new_stack}

      :not_found when mode == :in_body ->
        add_child_to_stack(state, new_element("p"))

      :not_found ->
        state
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

  defp process({:end_tag, "frameset"}, %State{stack: stack} = state) do
    %{state | stack: close_tag("frameset", stack), mode: :after_frameset}
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

  # In colgroup: whitespace stays, non-whitespace closes colgroup and reprocesses
  defp process({:character, text}, %State{stack: [%{tag: "colgroup"} | _]} = state) do
    case String.trim(text) do
      "" -> add_text_to_stack(state, text)
      _ -> process({:character, text}, close_current_element(state))
    end
  end

  defp process({:character, text}, %State{stack: [%{tag: tag} | _]} = state)
       when tag in @table_context do
    # Whitespace-only text goes directly into table, non-whitespace is foster parented
    if String.trim(text) == "" do
      add_text_to_stack(state, text)
    else
      case foster_reconstruct_active_formatting(state) do
        {state, true} -> add_text_to_stack(state, text)
        {state, false} -> foster_text_to_stack(state, text)
      end
    end
  end

  # Text in pre-body modes: whitespace stays, non-whitespace triggers body transition
  defp process({:character, text}, %State{stack: [], mode: mode} = state)
       when mode in [:initial, :before_head, :in_head, :after_head] do
    process_text_to_body(state, text)
  end

  defp process({:character, text}, %State{mode: mode} = state)
       when mode in [:initial, :before_head, :in_head, :after_head] do
    case String.trim_leading(text) do
      "" ->
        add_text_to_stack(state, text)

      trimmed ->
        leading_ws = String.slice(text, 0, String.length(text) - String.length(trimmed))

        state
        |> maybe_add_leading_whitespace(leading_ws)
        |> process_text_to_body(trimmed)
    end
  end

  # In frameset/after frameset modes - only whitespace is kept, non-whitespace is ignored
  defp process({:character, text}, %State{mode: mode} = state)
       when mode in [:in_frameset, :after_frameset] do
    case extract_whitespace(text) do
      "" -> state
      whitespace -> add_text_to_stack(state, whitespace)
    end
  end

  # In body modes - process text
  defp process({:character, text}, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
    |> maybe_set_frameset_not_ok(text)
  end

  defp process({:comment, _text}, %State{stack: []} = state), do: state

  defp process({:comment, text}, state) do
    add_child_to_stack(state, {:comment, text})
  end

  defp process({:error, _}, state), do: state

  # Character processing helpers
  defp maybe_add_leading_whitespace(state, ""), do: state
  defp maybe_add_leading_whitespace(state, ws), do: add_text_to_stack(state, ws)

  defp process_text_to_body(state, text) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
    |> set_frameset_not_ok()
  end

  # --------------------------------------------------------------------------
  # HTML start tag processing
  # --------------------------------------------------------------------------

  # Frameset and frame should never be foster parented
  defp process_html_start_tag(tag, attrs, self_closing, state)
       when tag in ["frameset", "frame"] do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  defp process_html_start_tag(tag, attrs, self_closing, %State{stack: stack} = state)
       when tag not in @table_elements do
    # Foster parent in table context, unless inside select (which creates a boundary)
    if in_table_context?(stack) and not in_select?(stack) do
      process_foster_start_tag(tag, attrs, self_closing, state)
    else
      do_process_html_start_tag(tag, attrs, self_closing, state)
    end
  end

  # Table elements and other tags that don't need foster parenting
  defp process_html_start_tag(tag, attrs, self_closing, state) do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  # Template in body mode needs special handling (push mode)
  defp do_process_html_start_tag("template", attrs, _, %State{mode: mode} = state)
       when mode in [:in_body, :in_table, :in_select] do
    state
    |> reconstruct_active_formatting()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> push_af_marker()
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

  # Frameset in body mode - only allowed if frameset_ok is true
  defp do_process_html_start_tag(
         "frameset",
         attrs,
         _,
         %State{mode: :in_body, frameset_ok: true} = state
       ) do
    state
    |> close_body_for_frameset()
    |> push_element("frameset", attrs)
    |> set_mode(:in_frameset)
  end

  defp do_process_html_start_tag("frameset", _, _, %State{mode: :in_body} = state), do: state

  defp do_process_html_start_tag("frameset", attrs, _, %State{stack: stack} = state) do
    if has_tag?(stack, "body") or has_body_content?(stack) do
      state
    else
      state
      |> ensure_html()
      |> ensure_head()
      |> close_head()
      |> push_element("frameset", attrs)
      |> set_mode(:in_frameset)
    end
  end

  # <frame> is valid only in frameset context
  defp do_process_html_start_tag(
         "frame",
         attrs,
         _,
         %State{stack: [%{tag: "frameset"} | _]} = state
       ) do
    add_child_to_stack(state, {"frame", attrs, []})
  end

  defp do_process_html_start_tag("frame", _, _, state), do: state

  # <col> needs colgroup wrapper in table context
  defp do_process_html_start_tag("col", attrs, _, %State{mode: :in_table} = state) do
    state
    |> ensure_colgroup()
    |> add_child_to_stack({"col", attrs, []})
  end

  defp do_process_html_start_tag("col", attrs, _, %State{mode: :in_template} = state) do
    add_child_to_stack(state, {"col", attrs, []})
  end

  defp do_process_html_start_tag("col", _, _, state), do: state

  # <hr> in select context should close option/optgroup first
  defp do_process_html_start_tag("hr", attrs, _, %State{mode: :in_select} = state) do
    state
    |> close_option_optgroup_in_select()
    |> add_child_to_stack({"hr", attrs, []})
  end

  # <input>, <keygen>, <textarea> in select context close the select
  defp do_process_html_start_tag(tag, attrs, self_closing, %State{mode: :in_select} = state)
       when tag in ["input", "keygen", "textarea"] do
    state
    |> close_select()
    |> then(&do_process_html_start_tag(tag, attrs, self_closing, &1))
  end

  defp do_process_html_start_tag("hr", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("hr")
    |> add_child_to_stack({"hr", attrs, []})
    |> set_frameset_not_ok()
  end

  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @void_elements do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
    |> maybe_set_frameset_not_ok_for_element(tag)
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
    |> clear_to_table_row_context()
    |> ensure_table_context()
    |> push_element(tag, attrs)
    |> push_af_marker()
  end

  # Table sections, caption, colgroup in template mode are ignored
  defp do_process_html_start_tag(tag, _, _, %State{mode: :in_template} = state)
       when tag in @table_sections or tag in ["caption", "colgroup"] do
    state
  end

  # Table sections close any open colgroup
  defp do_process_html_start_tag(tag, attrs, _, %State{mode: :in_table} = state)
       when tag in @table_sections do
    state
    |> clear_to_table_context()
    |> push_element(tag, attrs)
  end

  # Caption closes open rows/sections back to table level
  defp do_process_html_start_tag("caption", attrs, _, %State{mode: :in_table} = state) do
    state
    |> clear_to_table_context()
    |> push_element("caption", attrs)
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
    |> maybe_close_existing_formatting("a")
    |> reconstruct_active_formatting()
    |> push_element("a", attrs)
    |> add_formatting_entry("a", attrs)
  end

  defp do_process_html_start_tag("nobr", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> maybe_close_existing_formatting("nobr")
    |> push_element("nobr", attrs)
    |> add_formatting_entry("nobr", attrs)
  end

  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @formatting_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
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
    |> set_frameset_not_ok()
  end

  defp do_process_html_start_tag("select", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element("select", attrs)
    |> push_mode(:in_select)
    |> set_frameset_not_ok()
  end

  defp do_process_html_start_tag(tag, attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> maybe_close_same(tag)
    |> push_element(tag, attrs)
    |> reconstruct_active_formatting()
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  defp maybe_set_frameset_not_ok_for_element(state, tag)
       when tag in @frameset_disabling_elements do
    set_frameset_not_ok(state)
  end

  defp maybe_set_frameset_not_ok_for_element(state, _tag), do: state

  defp process_start_tag(state, tag, attrs, self_closing) do
    if self_closing or tag in @void_elements do
      add_child_to_stack(state, {tag, attrs, []})
    else
      push_element(state, tag, attrs)
    end
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
    # td/th are scope boundaries - content inside cells shouldn't be foster parented
    in_scope?(stack, ["table" | @table_context], [
      "td",
      "th",
      "caption",
      "template",
      "body",
      "html"
    ])
  end

  defp in_select?(stack) do
    in_scope?(stack, ["select"], ["template", "body", "html"])
  end

  # Close option/optgroup if we're in select context
  defp close_option_optgroup_in_select(%State{stack: [%{tag: tag} = elem | rest]} = state)
       when tag in ["option", "optgroup"] do
    %{state | stack: foster_aware_add_child(rest, elem)}
    |> close_option_optgroup_in_select()
  end

  defp close_option_optgroup_in_select(state), do: state

  # Close select element and pop mode
  defp close_select(%State{stack: stack} = state) do
    %{state | stack: close_tag("select", stack)} |> pop_mode()
  end

  # --------------------------------------------------------------------------
  # Adoption agency algorithm
  # --------------------------------------------------------------------------

  defp run_adoption_agency(state, subject) do
    run_adoption_agency_outer_loop(state, subject, 0)
  end

  defp run_adoption_agency_outer_loop(state, _subject, iteration) when iteration >= 8, do: state

  defp run_adoption_agency_outer_loop(%State{stack: stack, af: af} = state, subject, iteration) do
    case locate_formatting_element(af, stack, subject) do
      :not_in_af ->
        handle_no_formatting_entry(state, subject, iteration)

      {:not_in_stack, af_idx} ->
        %{state | af: List.delete_at(af, af_idx)}

      :not_in_scope ->
        state

      {:no_furthest_block, af_idx, stack_idx} ->
        {new_stack, new_af} = pop_to_formatting_element(stack, af, af_idx, stack_idx)
        %{state | stack: new_stack, af: new_af}

      {:has_furthest_block, af_idx, fe_ref, fe_tag, fe_attrs, stack_idx, fb_idx} ->
        state
        |> run_adoption_agency_with_furthest_block(
          {af_idx, fe_ref, fe_tag, fe_attrs},
          stack_idx,
          fb_idx
        )
        |> run_adoption_agency_outer_loop(subject, iteration + 1)
    end
  end

  # Locate formatting element and determine what action to take.
  # Uses `with` to express the "happy path" declaratively:
  # 1. Find the formatting entry in AF
  # 2. Find its position in the stack
  # 3. Verify it's in scope
  # Then determine if there's a furthest block.
  defp locate_formatting_element(af, stack, subject) do
    with {:ok, af_idx, {fe_ref, fe_tag, fe_attrs}} <- find_formatting_entry_result(af, subject),
         {:ok, stack_idx} <- find_in_stack_result(stack, fe_ref, af_idx),
         :ok <- check_in_scope(stack, stack_idx) do
      case find_furthest_block(stack, stack_idx) do
        nil -> {:no_furthest_block, af_idx, stack_idx}
        fb_idx -> {:has_furthest_block, af_idx, fe_ref, fe_tag, fe_attrs, stack_idx, fb_idx}
      end
    end
  end

  defp find_formatting_entry_result(af, subject) do
    case find_formatting_entry(af, subject) do
      nil -> :not_in_af
      {af_idx, entry} -> {:ok, af_idx, entry}
    end
  end

  defp find_in_stack_result(stack, fe_ref, af_idx) do
    case find_in_stack_by_ref(stack, fe_ref) do
      nil -> {:not_in_stack, af_idx}
      stack_idx -> {:ok, stack_idx}
    end
  end

  defp check_in_scope(stack, stack_idx) do
    if element_in_scope?(stack, stack_idx), do: :ok, else: :not_in_scope
  end

  # Check if the element at stack_idx is in scope
  defp element_in_scope?(stack, target_idx) do
    stack
    |> Enum.take(target_idx)
    |> Enum.all?(fn %{tag: tag} -> tag not in @scope_boundaries end)
  end

  # First iteration with no formatting entry - close the tag
  defp handle_no_formatting_entry(%State{stack: stack} = state, subject, 0) do
    %{state | stack: close_tag(subject, stack)}
  end

  # Subsequent iterations with no formatting entry - done
  defp handle_no_formatting_entry(state, _subject, _iteration), do: state

  defp find_formatting_entry(af, tag) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{ref, ^tag, attrs}, idx} -> {idx, {ref, tag, attrs}}
      _ -> nil
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
    {above_fb, [fb | rest2]} = Enum.split(stack, fb_idx)
    between_count = fe_stack_idx - fb_idx - 1
    {between, [fe | below_fe]} = Enum.split(rest2, between_count)

    %{ref: fb_ref, tag: fb_tag, attrs: fb_attrs, children: fb_children} = fb
    %{children: fe_children} = fe

    {formatting_between, block_between} = partition_between_elements(between, af)
    {formatting_to_clone_list, _} = Enum.split(formatting_between, 3)

    # Close formatting elements into the original formatting element
    closed_fe = %{
      ref: fe_ref,
      tag: fe_tag,
      attrs: fe_attrs,
      children: close_elements_into(formatting_between, fe_children)
    }

    below_fe = foster_aware_add_child(below_fe, closed_fe)

    # Create clones for the new stack
    new_fe_clone = %{ref: make_ref(), tag: fe_tag, attrs: fe_attrs, children: fb_children}
    fb_empty = %{ref: fb_ref, tag: fb_tag, attrs: fb_attrs, children: []}

    formatting_stack_elements =
      Enum.map(formatting_to_clone_list, fn %{tag: t, attrs: a} -> new_element(t, a) end)

    block_with_clones = wrap_children_with_fe_clone(block_between, fe_tag, fe_attrs)

    final_stack =
      above_fb ++
        [new_fe_clone, fb_empty | formatting_stack_elements] ++
        Enum.reverse(block_with_clones) ++ below_fe

    new_af =
      af
      |> remove_formatting_from_af(af_idx, formatting_between)
      |> then(&[{new_fe_clone.ref, fe_tag, fe_attrs} | &1])

    %{state | stack: final_stack, af: new_af}
  end

  defp partition_between_elements(between, af) do
    Enum.split_with(between, fn %{ref: elem_ref} ->
      ref_in_af?(af, elem_ref)
    end)
  end

  defp ref_in_af?(af, target_ref) do
    Enum.any?(af, fn
      {^target_ref, _, _} -> true
      _ -> false
    end)
  end

  defp remove_formatting_from_af(af, fe_idx, formatting_between) do
    af = List.delete_at(af, fe_idx)
    formatting_refs = MapSet.new(formatting_between, & &1.ref)
    reject_refs_from_af(af, formatting_refs)
  end

  defp wrap_children_with_fe_clone(elements, fe_tag, fe_attrs) do
    Enum.map(elements, fn elem ->
      %{elem | children: [{fe_tag, fe_attrs, elem.children}]}
    end)
  end

  defp find_furthest_block(stack, fe_idx) do
    stack
    |> Enum.take(fe_idx)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{tag: tag}, idx} when is_binary(tag) and tag in @special_elements -> idx
      _ -> nil
    end)
  end

  defp pop_to_formatting_element(stack, af, af_idx, stack_idx) do
    {above_fe, [fe | rest]} = Enum.split(stack, stack_idx)

    closed_above = nest_elements(above_fe)
    fe_children = if closed_above, do: [closed_above | fe.children], else: fe.children
    closed_fe = %{fe | children: fe_children}

    final_stack = add_child(rest, closed_fe)

    # Remove the formatting element and any formatting elements that were above it
    above_refs = MapSet.new(above_fe, & &1.ref)
    af = List.delete_at(af, af_idx) |> reject_refs_from_af(above_refs)

    {final_stack, af}
  end

  defp close_elements_into([], children), do: children

  defp close_elements_into(elements, fe_original_children) do
    [nest_elements(elements) | fe_original_children]
  end

  # --------------------------------------------------------------------------
  # Reconstruct active formatting
  # --------------------------------------------------------------------------

  defp reconstruct_active_formatting(%State{stack: stack, af: af} = state) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.reverse()
    |> Enum.filter(fn {ref, _tag, _attrs} ->
      find_in_stack_by_ref(stack, ref) == nil
    end)
    |> then(&reconstruct_entries(state, &1))
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

  defp maybe_close_existing_formatting(%State{af: af} = state, tag) do
    if find_formatting_entry(af, tag) do
      state = run_adoption_agency(state, tag)
      %{state | af: remove_formatting_entry(state.af, tag)}
    else
      state
    end
  end

  defp apply_noahs_ark(af, tag, attrs) do
    matching_indices =
      af
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{_ref, ^tag, ^attrs}, idx} -> [idx]
        _ -> []
      end)

    if length(matching_indices) > 3 do
      List.delete_at(af, Enum.max(matching_indices))
    else
      af
    end
  end

  defp push_af_marker(%State{af: af} = state), do: %{state | af: [:marker | af]}

  defp clear_af_to_marker(af) do
    af
    |> Enum.drop_while(&(&1 != :marker))
    |> Enum.drop(1)
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  @table_body_boundaries @table_sections ++ ["table", "template", "html"]
  @table_row_boundaries @table_row_context ++ ["table", "template", "html"]
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_body_context(%State{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_body_boundaries)}
  end

  defp clear_to_table_row_context(%State{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_row_boundaries)}
  end

  defp clear_to_table_context(%State{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_boundaries)}
  end

  defp clear_to_context([%{tag: tag} | _] = stack, boundaries) do
    if tag in boundaries, do: stack, else: clear_to_context_close(stack, boundaries)
  end

  defp clear_to_context([], _boundaries), do: []

  defp clear_to_context_close([elem | rest], boundaries) do
    clear_to_context(foster_aware_add_child(rest, elem), boundaries)
  end

  # Clears to table context but preserves single-element stacks (for end_tag table)
  defp do_clear_to_table_context([%{tag: tag} | _] = stack) when tag in @table_boundaries,
    do: stack

  defp do_clear_to_table_context([_] = stack), do: stack
  defp do_clear_to_table_context([]), do: []

  defp do_clear_to_table_context([elem | rest]) do
    do_clear_to_table_context(foster_aware_add_child(rest, elem))
  end

  # Get refs of all elements that will be closed when table closes
  defp get_refs_to_close_for_table(stack), do: do_get_refs_to_close_for_table(stack, MapSet.new())

  defp do_get_refs_to_close_for_table([%{tag: "table", ref: ref} | _], acc),
    do: MapSet.put(acc, ref)

  defp do_get_refs_to_close_for_table([%{tag: tag} | _], acc) when tag in ["template", "html"],
    do: acc

  defp do_get_refs_to_close_for_table([_], acc), do: acc
  defp do_get_refs_to_close_for_table([], acc), do: acc

  defp do_get_refs_to_close_for_table([%{ref: ref} | rest], acc) do
    do_get_refs_to_close_for_table(rest, MapSet.put(acc, ref))
  end

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

  # Template with existing table row structure - create new tr for td/th
  defp ensure_tr(%State{stack: [%{tag: "template", children: children} | _]} = state) do
    if has_table_row_structure?(children) do
      push_element(state, "tr", %{})
    else
      state
    end
  end

  defp ensure_tr(state), do: state

  defp has_table_row_structure?(children) do
    Enum.any?(children, fn
      %{tag: tag} when tag in ~w(tr tbody thead tfoot) -> true
      _ -> false
    end)
  end

  @colgroup_close_tags ["td", "th", "tr"] ++ @table_sections

  defp ensure_colgroup(%State{stack: [%{tag: "colgroup"} | _]} = state), do: state

  defp ensure_colgroup(%State{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "colgroup", %{})
  end

  defp ensure_colgroup(%State{stack: [%{tag: tag} = elem | rest]} = state)
       when tag in @colgroup_close_tags do
    ensure_colgroup(%{state | stack: add_child(rest, elem)})
  end

  defp ensure_colgroup(state), do: state

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(%State{stack: stack, af: af} = state, tag) when tag in @closes_p do
    {new_stack, new_af} = close_p_if_open_with_af(stack, af)
    %{state | stack: new_stack, af: new_af}
  end

  defp maybe_close_p(state, _tag), do: state

  # Close p and clear AF entries for non-formatting elements only
  # Formatting elements stay in AF for reconstruction
  defp close_p_if_open_with_af(stack, af) do
    case find_p_in_stack(stack, []) do
      nil ->
        {stack, af}

      {above_p, p_elem, below_p} ->
        # Only clear refs for non-formatting elements (p itself and non-formatting above)
        non_formatting_refs =
          [p_elem | above_p]
          |> Enum.reject(fn %{tag: tag} -> tag in @formatting_elements end)
          |> Enum.map(& &1.ref)
          |> MapSet.new()

        new_af = reject_refs_from_af(af, non_formatting_refs)
        closed_p = close_with_elements_above(p_elem, above_p)
        {add_child(below_p, closed_p), new_af}
    end
  end

  defp reject_refs_from_af(af, refs) do
    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(refs, ref)
    end)
  end

  # Button scope boundaries for closing <p>
  @button_scope_boundaries ~w(applet caption html table td th marquee object template button)

  # Close <p> respecting button scope (for </p> end tag)
  defp close_p_in_scope(stack) do
    case find_p_in_stack(stack, []) do
      nil ->
        :not_found

      {above_p, p_elem, below_p} ->
        closed_p = close_with_elements_above(p_elem, above_p)
        {:found, foster_aware_add_child(below_p, closed_p)}
    end
  end

  # Nest elements into each other and add to parent's children
  defp close_with_elements_above(parent, []), do: parent

  defp close_with_elements_above(parent, [first | rest]) do
    nested =
      Enum.reduce(rest, first, fn elem, inner -> %{elem | children: [inner | elem.children]} end)

    %{parent | children: [nested | parent.children]}
  end

  defp find_p_in_stack([], _acc), do: nil

  defp find_p_in_stack([%{tag: "p"} = p_elem | rest], acc) do
    {Enum.reverse(acc), p_elem, rest}
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
  @li_scope_boundaries ~w(ol ul table template body html)

  # li has special scope boundaries (list item scope)
  defp maybe_close_same(%State{stack: stack} = state, "li") do
    case pop_to_implicit_close(stack, ["li"], [], @li_scope_boundaries) do
      {:ok, new_stack} -> %{state | stack: new_stack}
      :not_found -> state
    end
  end

  # Ruby elements need to close multiple elements (e.g., rb closes both rt and rtc)
  @ruby_elements ~w(rb rt rtc rp)

  for {tag, also_closes} <- @implicit_closes, tag != "li" do
    closes = [tag | also_closes]

    if tag in @ruby_elements do
      defp maybe_close_same(%State{stack: stack} = state, unquote(tag)) do
        case pop_to_implicit_close_all(stack, unquote(closes), @implicit_close_boundaries) do
          {:ok, new_stack} -> %{state | stack: new_stack}
          :not_found -> state
        end
      end
    else
      defp maybe_close_same(%State{stack: stack} = state, unquote(tag)) do
        case pop_to_implicit_close(stack, unquote(closes), [], @implicit_close_boundaries) do
          {:ok, new_stack} -> %{state | stack: new_stack}
          :not_found -> state
        end
      end
    end
  end

  defp maybe_close_same(state, _tag), do: state

  defp pop_to_implicit_close([], _closes, _acc, _boundaries), do: :not_found

  defp pop_to_implicit_close([%{tag: tag} = elem | rest], closes, acc, boundaries) do
    cond do
      tag in boundaries ->
        :not_found

      tag in closes ->
        # Found match - first close accumulated elements into the target, then close target
        closed_elem = Enum.reduce(acc, elem, &add_child_to_elem/2)
        {:ok, add_child(rest, closed_elem)}

      true ->
        pop_to_implicit_close(rest, closes, [elem | acc], boundaries)
    end
  end

  # Close ALL matching elements (for ruby elements that need to close multiple)
  defp pop_to_implicit_close_all(stack, closes, boundaries) do
    do_pop_to_implicit_close_all(stack, closes, boundaries, false)
  end

  defp do_pop_to_implicit_close_all(stack, closes, boundaries, found_any) do
    case pop_to_implicit_close(stack, closes, [], boundaries) do
      {:ok, new_stack} ->
        do_pop_to_implicit_close_all(new_stack, closes, boundaries, true)

      :not_found when found_any ->
        {:ok, stack}

      :not_found ->
        :not_found
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

  # Frameset modes - ensure body exists (no-op if frameset already present)
  defp transition_to(%State{mode: mode} = state, :in_body)
       when mode in [:in_frameset, :after_frameset] do
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

  defp in_body(%State{mode: mode, stack: []} = state)
       when mode in [:in_body, :in_select, :in_table, :in_template] do
    # Mode says in_body but stack is empty - need to create structure
    transition_to(%{state | mode: :initial}, :in_body)
  end

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

  # Merge attributes onto existing html element (for second <html> tags)
  defp merge_html_attrs(state, new_attrs) when new_attrs == %{}, do: state

  defp merge_html_attrs(%State{stack: stack} = state, new_attrs) do
    %{state | stack: do_merge_html_attrs(stack, new_attrs)}
  end

  defp do_merge_html_attrs([%{tag: "html", attrs: attrs} = html | rest], new_attrs) do
    # Only add attributes that don't already exist
    merged = Map.merge(new_attrs, attrs)
    [%{html | attrs: merged} | rest]
  end

  defp do_merge_html_attrs([elem | rest], new_attrs) do
    [elem | do_merge_html_attrs(rest, new_attrs)]
  end

  defp do_merge_html_attrs([], _new_attrs), do: []

  defp ensure_head(%State{stack: [%{tag: "html", children: children} = html]} = state) do
    if has_tag?(children, "head") do
      state
    else
      head = new_element("head")
      %{state | stack: [head, html], mode: :in_head}
    end
  end

  defp ensure_head(%State{stack: [%{tag: "head"} | _]} = state), do: state
  defp ensure_head(%State{stack: [%{tag: "body"} | _]} = state), do: state
  defp ensure_head(state), do: state

  defp close_head(%State{stack: [%{tag: "head"} = head | rest]} = state) do
    %{state | stack: add_child(rest, head), mode: :after_head}
  end

  defp close_head(state), do: state

  # Close body and all elements above it for frameset insertion
  defp close_body_for_frameset(%State{stack: stack} = state) do
    %{state | stack: do_close_body_for_frameset(stack)}
  end

  defp do_close_body_for_frameset([%{tag: "body"} | rest]), do: rest
  defp do_close_body_for_frameset([%{tag: "html"} | _] = stack), do: stack
  defp do_close_body_for_frameset([_ | rest]), do: do_close_body_for_frameset(rest)
  defp do_close_body_for_frameset([]), do: []

  # Set frameset_ok to false when non-whitespace text is seen
  defp maybe_set_frameset_not_ok(%State{frameset_ok: false} = state, _text), do: state

  defp maybe_set_frameset_not_ok(state, text) do
    if String.trim(text) == "" do
      state
    else
      %{state | frameset_ok: false}
    end
  end

  defp set_frameset_not_ok(state), do: %{state | frameset_ok: false}

  # Extract only whitespace characters from text
  defp extract_whitespace(text), do: String.replace(text, ~r/[^ \t\n\r\f]/, "")

  defp ensure_body(%State{stack: [%{tag: "body"} | _]} = state), do: state
  defp ensure_body(%State{stack: [%{tag: "frameset"} | _]} = state), do: state

  defp ensure_body(%State{stack: [%{tag: "html", children: children} = html]} = state) do
    # Don't create body if frameset exists
    if has_tag?(children, "frameset") do
      state
    else
      body = new_element("body")
      %{state | stack: [body, html], mode: :in_body}
    end
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

  # Void/self-closing - foster as complete element
  defp process_foster_start_tag(tag, attrs, true, %State{stack: stack} = state) do
    %{state | stack: foster_element(stack, {tag, attrs, []})}
  end

  defp process_foster_start_tag(tag, attrs, _, %State{stack: stack} = state)
       when tag in @void_elements do
    %{state | stack: foster_element(stack, {tag, attrs, []})}
  end

  # Formatting element - push and update AF with noah's ark
  defp process_foster_start_tag(tag, attrs, _, %State{stack: stack, af: af} = state)
       when tag in @formatting_elements do
    {new_stack, new_ref} = foster_push_element(stack, tag, attrs)
    new_af = apply_noahs_ark([{new_ref, tag, attrs} | af], tag, attrs)
    %{state | stack: new_stack, af: new_af}
  end

  # Other element - just push
  defp process_foster_start_tag(tag, attrs, _, %State{stack: stack} = state) do
    {new_stack, _new_ref} = foster_push_element(stack, tag, attrs)
    %{state | stack: new_stack}
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
    foster_content(stack, element, [], &add_child/2)
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
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.reverse()
    |> Enum.filter(fn {ref, _tag, _attrs} ->
      find_in_stack_by_ref(stack, ref) == nil
    end)
    |> case do
      [] -> {state, false}
      entries -> {foster_reconstruct_entries(state, entries), true}
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

  defp rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)

  # --------------------------------------------------------------------------
  # Stack operations
  # --------------------------------------------------------------------------

  # Nest a list of elements from innermost to outermost.
  # Returns nil for empty list, or the nested element.
  defp nest_elements([]), do: nil

  defp nest_elements([first | rest]) do
    Enum.reduce(rest, first, fn elem, inner -> %{elem | children: [inner | elem.children]} end)
  end

  defp push_element(%State{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  defp close_current_element(%State{stack: [elem | rest]} = state) do
    %{state | stack: add_child(rest, elem)}
  end

  defp push_foreign_element(state, ns, tag, attrs, self_closing)

  defp push_foreign_element(%State{stack: stack} = state, ns, tag, attrs, true) do
    adjusted_tag = adjust_svg_tag(ns, tag)
    adjusted_attrs = adjust_foreign_attributes(ns, attrs)
    %{state | stack: add_child(stack, {{ns, adjusted_tag}, adjusted_attrs, []})}
  end

  defp push_foreign_element(%State{stack: stack} = state, ns, tag, attrs, _) do
    adjusted_tag = adjust_svg_tag(ns, tag)
    adjusted_attrs = adjust_foreign_attributes(ns, attrs)
    %{state | stack: [new_foreign_element(ns, adjusted_tag, adjusted_attrs) | stack]}
  end

  # Adjust attributes for foreign (SVG/MathML) content per HTML5 spec
  @foreign_attr_adjustments %{
    # xlink namespace
    "xlink:actuate" => {:xlink, "actuate"},
    "xlink:arcrole" => {:xlink, "arcrole"},
    "xlink:href" => {:xlink, "href"},
    "xlink:role" => {:xlink, "role"},
    "xlink:show" => {:xlink, "show"},
    "xlink:title" => {:xlink, "title"},
    "xlink:type" => {:xlink, "type"},
    # xml namespace
    "xml:lang" => {:xml, "lang"},
    "xml:space" => {:xml, "space"},
    # xmlns namespace
    "xmlns" => {:xmlns, ""},
    "xmlns:xlink" => {:xmlns, "xlink"}
  }

  # MathML attribute case adjustments (only applies to MathML, not SVG)
  @mathml_attr_case_adjustments %{
    "definitionurl" => "definitionURL"
  }

  defp adjust_foreign_attributes(ns, attrs) do
    Map.new(attrs, fn {key, value} ->
      {adjust_attr_key(ns, key), value}
    end)
  end

  defp adjust_attr_key(_ns, key) when is_map_key(@foreign_attr_adjustments, key) do
    @foreign_attr_adjustments[key]
  end

  defp adjust_attr_key(:math, key) when is_map_key(@mathml_attr_case_adjustments, key) do
    @mathml_attr_case_adjustments[key]
  end

  defp adjust_attr_key(_ns, key), do: key

  # SVG element tag name adjustments (case-sensitive per spec)
  @svg_tag_adjustments %{
    "altglyph" => "altGlyph",
    "altglyphdef" => "altGlyphDef",
    "altglyphitem" => "altGlyphItem",
    "animatecolor" => "animateColor",
    "animatemotion" => "animateMotion",
    "animatetransform" => "animateTransform",
    "clippath" => "clipPath",
    "feblend" => "feBlend",
    "fecolormatrix" => "feColorMatrix",
    "fecomponenttransfer" => "feComponentTransfer",
    "fecomposite" => "feComposite",
    "feconvolvematrix" => "feConvolveMatrix",
    "fediffuselighting" => "feDiffuseLighting",
    "fedisplacementmap" => "feDisplacementMap",
    "fedistantlight" => "feDistantLight",
    "fedropshadow" => "feDropShadow",
    "feflood" => "feFlood",
    "fefunca" => "feFuncA",
    "fefuncb" => "feFuncB",
    "fefuncg" => "feFuncG",
    "fefuncr" => "feFuncR",
    "fegaussianblur" => "feGaussianBlur",
    "feimage" => "feImage",
    "femerge" => "feMerge",
    "femergenode" => "feMergeNode",
    "femorphology" => "feMorphology",
    "feoffset" => "feOffset",
    "fepointlight" => "fePointLight",
    "fespecularlighting" => "feSpecularLighting",
    "fespotlight" => "feSpotLight",
    "fetile" => "feTile",
    "feturbulence" => "feTurbulence",
    "foreignobject" => "foreignObject",
    "glyphref" => "glyphRef",
    "lineargradient" => "linearGradient",
    "radialgradient" => "radialGradient",
    "textpath" => "textPath"
  }

  defp adjust_svg_tag(:svg, tag) when is_map_key(@svg_tag_adjustments, tag) do
    @svg_tag_adjustments[tag]
  end

  defp adjust_svg_tag(_ns, tag), do: tag

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

    new_stack =
      case nest_elements(foreign) do
        nil -> rest
        closed -> add_child(rest, closed)
      end

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

  defp pop_until(target, [%{tag: tag} = elem | rest], acc) do
    cond do
      tag_matches?(tag, target) ->
        finalize_pop(elem, acc, rest)

      # Template is a boundary - can't close elements across it (unless closing template itself)
      tag == "template" ->
        :not_found

      true ->
        pop_until(target, rest, [elem | acc])
    end
  end

  defp tag_matches?(tag, target) when tag == target, do: true
  defp tag_matches?({:svg, tag}, target) when tag == target, do: true
  defp tag_matches?({:math, tag}, target) when tag == target, do: true
  defp tag_matches?(_, _), do: false

  defp finalize_pop(elem, acc, rest) do
    nested_above = nest_elements(Enum.reverse(acc))
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
    |> Enum.map(&reverse_node/1)
  end

  defp reverse_node(%{children: kids} = elem), do: %{elem | children: reverse_all(kids)}
  defp reverse_node({tag, attrs, kids}), do: {tag, attrs, reverse_all(kids)}
  defp reverse_node(leaf), do: leaf

  defp convert_to_tuples(nil), do: nil

  defp convert_to_tuples(%{tag: {ns, tag}, attrs: attrs, children: children}) do
    {{ns, tag}, attrs, convert_children(children)}
  end

  defp convert_to_tuples(%{tag: "template", attrs: attrs, children: children}) do
    {"template", attrs, [{:content, convert_children(children)}]}
  end

  defp convert_to_tuples(%{tag: tag, attrs: attrs, children: children}) do
    {tag, attrs, convert_children(children)}
  end

  defp convert_to_tuples({{ns, tag}, attrs, children}) do
    {{ns, tag}, attrs, convert_children(children)}
  end

  defp convert_to_tuples({tag, attrs, children}) when is_binary(tag) do
    {tag, attrs, convert_children(children)}
  end

  defp convert_to_tuples({:comment, text}), do: {:comment, text}
  defp convert_to_tuples(text) when is_binary(text), do: text

  defp convert_children(children), do: Enum.map(children, &convert_to_tuples/1)
end
