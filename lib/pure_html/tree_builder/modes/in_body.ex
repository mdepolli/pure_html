defmodule PureHTML.TreeBuilder.Modes.InBody do
  @moduledoc """
  HTML5 "in body" insertion mode.

  This is the main parsing mode for document content inside <body>.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [
      new_element: 2,
      new_element: 3,
      push_element: 3,
      push_foreign_element: 4,
      add_child_to_stack: 2,
      add_text_to_stack: 2,
      set_mode: 2,
      pop_mode: 1,
      switch_template_mode: 2,
      push_af_marker: 1,
      correct_tag: 1,
      current_tag: 1,
      current_element: 1,
      pop_element: 1,
      pop_until_one_of: 2,
      foster_parent: 2,
      has_tag?: 2
    ]

  alias PureHTML.TreeBuilder.AdoptionAgency

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)
  @table_context ~w(table tbody thead tfoot tr)
  @table_sections ~w(tbody thead tfoot)
  @table_cells ~w(td th)
  @table_row_context ~w(tr tbody thead tfoot)
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)

  # Use shared special_elements from Helpers
  @special_elements PureHTML.TreeBuilder.Helpers.special_elements()

  @closes_p ~w(address article aside blockquote center details dialog dir div dl dd dt
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr li listing main menu nav ol p plaintext pre rb rp rt rtc search section summary table ul xmp)

  # Block-level end tags per HTML5 spec (generate implied end tags, then pop until match)
  # These do NOT use the "special element stops traversal" rule
  @block_end_tags ~w(address article aside blockquote button center details dialog dir div
                     dl fieldset figcaption figure footer form header hgroup listing main
                     menu nav ol pre search section summary ul)

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
    "rb" => ["rt", "rtc", "rp"],
    "rt" => ["rb", "rp"],
    "rtc" => ["rb", "rt", "rp"],
    "rp" => ["rb", "rt"]
  }

  # Note: input is handled specially - only non-hidden inputs disable frameset
  @frameset_disabling_elements ~w(pre listing form textarea xmp iframe noembed noframes select embed
                                  keygen applet marquee object table button img hr br wbr area
                                  dd dt li plaintext rb rtc)

  @adopt_on_duplicate_elements ~w(a nobr)
  @table_structure_elements @table_sections ++ ["caption", "colgroup"]
  @ruby_elements ~w(rb rt rtc rp)
  @newline_skipping_elements ~w(pre textarea listing)

  # Map for determining insertion mode from stack element tags
  @tag_to_mode %{
    "template" => :in_template,
    "tbody" => :in_table,
    "thead" => :in_table,
    "tfoot" => :in_table,
    "tr" => :in_table,
    "td" => :in_body,
    "th" => :in_body,
    "caption" => :in_body,
    "table" => :in_table,
    "body" => :in_body,
    "frameset" => :in_frameset,
    "head" => :in_head,
    "html" => :before_head,
    "select" => :in_select
  }

  # Scope boundary guards
  @scope_boundaries ~w(applet caption html table td th marquee object template)
  @button_scope_extras ~w(button)
  defguardp is_button_scope_boundary(tag)
            when tag in @scope_boundaries or tag in @button_scope_extras

  # --------------------------------------------------------------------------
  # Token processing
  # --------------------------------------------------------------------------

  @impl true
  # Character tokens
  def process({:character, text}, %{stack: []} = state) do
    state
    |> ensure_html()
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
    |> then(&{:ok, &1})
  end

  def process({:character, text}, state) do
    tag = current_tag(state)

    cond do
      tag in @head_elements ->
        {:ok, add_text_to_stack(state, text)}

      tag in @table_context ->
        if String.trim(text) == "" do
          {:ok, add_text_to_stack(state, text)}
        else
          {new_state, _} = foster_parent(state, {:text, text})
          {:ok, new_state}
        end

      true ->
        text = maybe_skip_leading_newline(state, text)

        if text == "" do
          {:ok, state}
        else
          state =
            state
            |> in_body()
            |> reconstruct_active_formatting()
            |> add_text_to_stack(text)
            |> maybe_set_frameset_not_ok(text)

          {:ok, state}
        end
    end
  end

  # Comment tokens
  def process({:comment, _text}, %{stack: []} = state), do: {:ok, state}

  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE - parse error, ignore
  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    {:ok, state}
  end

  # --------------------------------------------------------------------------
  # End tags
  # --------------------------------------------------------------------------

  # End tags that break out of foreign content
  def process({:end_tag, tag} = token, state) when tag in ~w(p br) do
    case foreign_namespace(state) do
      nil ->
        do_process_end_tag(token, state)

      _ns ->
        # Break out of foreign content first
        state = close_foreign_content(state)
        do_process_end_tag(token, state)
    end
  end

  def process({:end_tag, "body"}, state) do
    {:ok, %{state | mode: :after_body}}
  end

  def process({:end_tag, "html"}, state) do
    {:reprocess, %{state | mode: :after_body}}
  end

  def process({:end_tag, tag}, state) when tag in @formatting_elements do
    {:ok, AdoptionAgency.run(state, tag, &close_tag_ref/2)}
  end

  def process({:end_tag, tag}, %{af: af} = state) when tag in @table_cells do
    new_state = close_tag_ref_forced(state, tag)
    new_af = clear_af_to_marker(af)
    {:ok, %{new_state | af: new_af}}
  end

  def process({:end_tag, "table"}, %{af: af} = state) do
    closed_refs = get_refs_to_close_for_table(state)
    new_af = reject_refs_from_af(af, closed_refs)
    state = clear_to_table_context(state)
    {:ok, close_tag_ref_forced(%{state | af: new_af}, "table") |> pop_mode()}
  end

  def process({:end_tag, "select"}, state) do
    {:ok, close_tag_ref_forced(state, "select") |> pop_mode()}
  end

  def process({:end_tag, "template"}, %{af: af} = state) do
    new_state = close_tag_ref_forced(state, "template")
    new_af = clear_af_to_marker(af)
    {:ok, %{new_state | af: new_af} |> reset_insertion_mode()}
  end

  def process({:end_tag, "frameset"}, state) do
    {:ok, close_tag_ref_forced(state, "frameset") |> Map.put(:mode, :after_frameset)}
  end

  # Heading end tags: close ANY open heading element per spec
  @headings ~w(h1 h2 h3 h4 h5 h6)
  def process({:end_tag, tag}, state) when tag in @headings do
    {:ok, close_any_heading(state)}
  end

  # li end tag: only close if li is in list item scope (ul/ol are barriers)
  def process({:end_tag, "li"}, state) do
    {:ok, close_li_in_list_scope(state)}
  end

  # dd/dt end tags: only close if in scope
  def process({:end_tag, tag}, state) when tag in ~w(dd dt) do
    {:ok, close_dd_dt_in_scope(state, tag)}
  end

  # Block-level end tags: generate implied end tags, then pop until match
  # Per HTML5 spec, these do NOT use the "special element stops traversal" rule
  def process({:end_tag, tag}, state) when tag in @block_end_tags do
    {:ok, close_block_end_tag(state, tag)}
  end

  # Any other end tag: check special elements per HTML5 spec
  def process({:end_tag, tag}, state) do
    {:ok, close_tag_ref(state, tag)}
  end

  # --------------------------------------------------------------------------
  # Start tags
  # --------------------------------------------------------------------------

  def process({:start_tag, "html", attrs, _}, %{stack: []} = state) do
    {:ok, %{state | stack: [new_element("html", attrs)], mode: :before_head}}
  end

  # Per spec: "If there is a template element on the stack of open elements, then ignore the token"
  # Check template_mode_stack for O(1) template context detection
  def process({:start_tag, "html", _attrs, _}, %{template_mode_stack: [_ | _]} = state) do
    {:ok, state}
  end

  def process({:start_tag, "html", attrs, _}, state) do
    {:ok, merge_html_attrs(state, attrs)}
  end

  def process({:start_tag, "head", _attrs, _}, state) do
    # Parse error, ignore the token (head is only valid in before_head mode)
    {:ok, state}
  end

  # Body inside template: ignore (per spec)
  def process({:start_tag, "body", _, _}, %{template_mode_stack: [_ | _]} = state) do
    {:ok, state}
  end

  def process({:start_tag, "body", attrs, _}, state) do
    state =
      state
      |> ensure_html()
      |> ensure_head()
      |> close_head()
      |> then(fn
        %{mode: :after_head} = s ->
          s
          |> push_element("body", attrs)
          |> set_mode(:in_body)
          |> set_frameset_not_ok()

        s ->
          s
          |> merge_body_attrs(attrs)
          |> set_frameset_not_ok()
      end)

    {:ok, state}
  end

  def process({:start_tag, "svg", attrs, self_closing}, state) do
    {:ok, state |> in_body() |> do_push_foreign_element(:svg, "svg", attrs, self_closing)}
  end

  def process({:start_tag, "math", attrs, self_closing}, state) do
    {:ok, state |> in_body() |> do_push_foreign_element(:math, "math", attrs, self_closing)}
  end

  def process({:start_tag, tag, attrs, self_closing}, state) do
    tag = correct_tag(tag)
    ns = foreign_namespace(state)

    state =
      cond do
        # mglyph/malignmark stay in MathML namespace even at text integration points
        tag in ~w(mglyph malignmark) and mathml_text_integration_point?(state) ->
          do_push_foreign_element(state, :math, tag, attrs, self_closing)

        is_nil(ns) or html_integration_point?(state) ->
          do_process_html_start_tag(tag, attrs, self_closing, state)

        html_breakout_tag?(tag) ->
          state = close_foreign_content(state)
          do_process_html_start_tag(tag, attrs, self_closing, state)

        true ->
          do_push_foreign_element(state, ns, tag, attrs, self_closing)
      end

    {:ok, state}
  end

  # Error tokens - ignore
  def process({:error, _}, state), do: {:ok, state}

  # Helper for end tags that break out of foreign content
  defp do_process_end_tag({:end_tag, "p"}, state) do
    case close_p_in_scope_ref(state) do
      {:found, new_state} ->
        {:ok, new_state}

      :not_found ->
        {:ok, add_child_to_stack(state, {"p", %{}, []})}
    end
  end

  defp do_process_end_tag({:end_tag, "br"}, state) do
    element = {"br", %{}, []}

    state =
      state
      |> in_body()
      |> reconstruct_active_formatting()
      |> add_child_to_stack(element)

    {:ok, state}
  end

  # --------------------------------------------------------------------------
  # HTML start tag processing
  # --------------------------------------------------------------------------

  # Template in template mode
  defp do_process_html_start_tag("template", attrs, _, %{mode: :in_template} = state) do
    state
    |> reconstruct_active_formatting()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> push_af_marker()
  end

  # Template in body/table/select modes
  defp do_process_html_start_tag("template", attrs, _, %{mode: mode} = state)
       when mode in [:in_body, :in_table, :in_select, :in_select_in_table] do
    if has_tag?(state, "body") do
      state
      |> reconstruct_active_formatting()
      |> push_element("template", attrs)
      |> push_mode(:in_template)
      |> push_af_marker()
    else
      do_process_html_start_tag_head_context("template", attrs, state)
    end
  end

  # Head elements in body modes
  defp do_process_html_start_tag(tag, attrs, self_closing, %{mode: mode} = state)
       when tag in @head_elements and
              mode in [:in_template, :in_body, :in_table, :in_select, :in_select_in_table] do
    if has_tag?(state, "body") or mode == :in_template do
      process_start_tag(state, tag, attrs, self_closing)
    else
      state
      |> ensure_html()
      |> ensure_head()
      |> maybe_reopen_head()
      |> process_start_tag(tag, attrs, self_closing)
    end
  end

  # Template in other contexts
  defp do_process_html_start_tag("template", attrs, _, state) do
    if has_tag?(state, "body") do
      process_start_tag(state, "template", attrs, false)
    else
      do_process_html_start_tag_head_context("template", attrs, state)
    end
  end

  # Other head elements
  defp do_process_html_start_tag(tag, attrs, self_closing, state)
       when tag in @head_elements do
    if has_tag?(state, "body") do
      process_start_tag(state, tag, attrs, self_closing)
    else
      state
      |> ensure_html()
      |> ensure_head()
      |> maybe_reopen_head()
      |> process_start_tag(tag, attrs, self_closing)
    end
  end

  # Frameset in body mode with frameset_ok
  defp do_process_html_start_tag(
         "frameset",
         attrs,
         _,
         %{mode: :in_body, frameset_ok: true} = state
       ) do
    state
    |> close_body_for_frameset()
    |> push_element("frameset", attrs)
    |> set_mode(:in_frameset)
  end

  defp do_process_html_start_tag("frameset", _, _, %{mode: :in_body} = state), do: state

  defp do_process_html_start_tag("frameset", attrs, _, state) do
    if has_tag?(state, "body") or has_body_content?(state) do
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

  # Frame in frameset
  defp do_process_html_start_tag("frame", attrs, _, state) do
    if current_tag(state) == "frameset" do
      add_child_to_stack(state, {"frame", attrs, []})
    else
      state
    end
  end

  # Col in table mode
  defp do_process_html_start_tag("col", attrs, _, %{mode: :in_table} = state) do
    if has_tag?(state, "table") do
      state |> ensure_colgroup() |> add_child_to_stack({"col", attrs, []})
    else
      add_child_to_stack(state, {"col", attrs, []})
    end
  end

  # Hr in select
  defp do_process_html_start_tag("hr", attrs, _, %{mode: mode} = state)
       when mode in [:in_select, :in_select_in_table] do
    state
    |> close_option_optgroup_in_select()
    |> add_child_to_stack({"hr", attrs, []})
  end

  # Input/keygen/textarea in select
  defp do_process_html_start_tag(tag, attrs, self_closing, %{mode: mode} = state)
       when tag in ["input", "keygen", "textarea"] and mode in [:in_select, :in_select_in_table] do
    state
    |> close_select()
    |> then(&do_process_html_start_tag(tag, attrs, self_closing, &1))
  end

  # Input element - only non-hidden inputs disable frameset
  defp do_process_html_start_tag("input", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_child_to_stack({"input", attrs, []})
    |> maybe_set_frameset_not_ok_for_input(attrs)
  end

  # Void elements
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @void_elements do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  # Self-closing
  defp do_process_html_start_tag(tag, attrs, true, state) do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
  end

  # Table structure in template
  defp do_process_html_start_tag(tag, attrs, _, %{mode: :in_template} = state)
       when tag in @table_structure_elements do
    state
    |> switch_template_mode(:in_table)
    |> push_element(tag, attrs)
  end

  # Col in template - switch to in_column_group and add col void element
  defp do_process_html_start_tag("col", attrs, _, %{mode: :in_template} = state) do
    state
    |> switch_template_mode(:in_column_group)
    |> add_child_to_stack({"col", attrs, []})
  end

  # Col in other contexts
  defp do_process_html_start_tag("col", _, _, state), do: state

  # Tr in template
  defp do_process_html_start_tag("tr", attrs, _, %{mode: :in_template} = state) do
    state
    |> switch_template_mode(:in_table)
    |> push_element("tr", attrs)
  end

  # Td/th in template
  defp do_process_html_start_tag(tag, attrs, self_closing, %{mode: :in_template} = state)
       when tag in ["td", "th"] do
    state = switch_template_mode(state, :in_body)
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  # Table structure in body mode (ignored)
  defp do_process_html_start_tag(tag, _, _, %{mode: :in_body} = state)
       when tag in @table_structure_elements do
    state
  end

  # Table cells
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @table_cells do
    state
    |> in_body()
    |> clear_to_table_row_context()
    |> ensure_table_context()
    |> push_element(tag, attrs)
    |> push_af_marker()
  end

  # Table structure in table mode
  defp do_process_html_start_tag(tag, attrs, _, %{mode: :in_table} = state)
       when tag in @table_structure_elements do
    if has_tag?(state, "table") do
      state
      |> clear_to_table_context()
      |> push_element(tag, attrs)
    else
      state
    end
  end

  # Tr
  defp do_process_html_start_tag("tr", attrs, _, state) do
    state
    |> in_body()
    |> clear_to_table_body_context()
    |> ensure_tbody()
    |> push_element("tr", attrs)
  end

  # Adopt-on-duplicate formatting elements
  defp do_process_html_start_tag(tag, attrs, _, state)
       when tag in @adopt_on_duplicate_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> maybe_close_existing_formatting(tag)
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> add_formatting_entry(tag, attrs)
  end

  # Formatting elements
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @formatting_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> add_formatting_entry(tag, attrs)
  end

  # Table
  defp do_process_html_start_tag("table", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("table")
    |> push_element("table", attrs)
    |> push_mode(:in_table)
    |> set_frameset_not_ok()
  end

  # Form - ignore if form_element is set and no template on stack
  defp do_process_html_start_tag(
         "form",
         _attrs,
         _,
         %{form_element: f, template_mode_stack: []} = state
       )
       when not is_nil(f) do
    state
  end

  defp do_process_html_start_tag("form", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("form")
    |> push_element("form", attrs)
    |> then(fn
      %{template_mode_stack: [], stack: [form_ref | _]} = new_state ->
        %{new_state | form_element: form_ref}

      new_state ->
        new_state
    end)
  end

  # Select - use in_select_in_table if there's a table ancestor
  defp do_process_html_start_tag("select", attrs, _, state) do
    state = state |> in_body() |> reconstruct_active_formatting() |> push_element("select", attrs)

    mode =
      if has_table_ancestor?(state.stack, state.elements),
        do: :in_select_in_table,
        else: :in_select

    state
    |> push_mode(mode)
    |> set_frameset_not_ok()
  end

  # Generic - block-level elements close p, inline elements reconstruct AF
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @closes_p do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> maybe_close_same(tag)
    |> maybe_close_current_heading(tag)
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  defp do_process_html_start_tag(tag, attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> maybe_close_same(tag)
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  # Per HTML5 spec: if current node is a heading and we're inserting a heading,
  # pop the current node first
  defp maybe_close_current_heading(state, tag) when tag in @headings do
    case current_tag(state) do
      current when current in @headings ->
        pop_element(state)

      _ ->
        state
    end
  end

  defp maybe_close_current_heading(state, _tag), do: state

  defp do_process_html_start_tag_head_context("template", attrs, state) do
    state
    |> ensure_html()
    |> ensure_head()
    |> maybe_reopen_head()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> push_af_marker()
  end

  defp process_start_tag(state, tag, attrs, self_closing) do
    if self_closing or tag in @void_elements do
      add_child_to_stack(state, {tag, attrs, []})
    else
      push_element(state, tag, attrs)
    end
  end

  # --------------------------------------------------------------------------
  # Foreign content
  # --------------------------------------------------------------------------

  # Push foreign element with adjustments (local version with self_closing handling)
  defp do_push_foreign_element(state, ns, tag, attrs, self_closing) do
    adjusted_tag = adjust_svg_tag(ns, tag)
    adjusted_attrs = adjust_foreign_attributes(ns, attrs)

    if self_closing do
      # Self-closing: add as child, don't push to stack
      add_child_to_stack(state, {{ns, adjusted_tag}, adjusted_attrs, []})
    else
      # Non-self-closing: push to stack
      push_foreign_element(state, ns, adjusted_tag, adjusted_attrs)
    end
  end

  @foreign_attr_adjustments %{
    "xlink:actuate" => {:xlink, "actuate"},
    "xlink:arcrole" => {:xlink, "arcrole"},
    "xlink:href" => {:xlink, "href"},
    "xlink:role" => {:xlink, "role"},
    "xlink:show" => {:xlink, "show"},
    "xlink:title" => {:xlink, "title"},
    "xlink:type" => {:xlink, "type"},
    "xml:lang" => {:xml, "lang"},
    "xml:space" => {:xml, "space"},
    "xmlns" => {:xmlns, ""},
    "xmlns:xlink" => {:xmlns, "xlink"}
  }

  @mathml_attr_case_adjustments %{"definitionurl" => "definitionURL"}

  # SVG attributes that need case adjustment (per HTML5 spec)
  @svg_attr_case_adjustments %{
    "attributename" => "attributeName",
    "attributetype" => "attributeType",
    "basefrequency" => "baseFrequency",
    "baseprofile" => "baseProfile",
    "calcmode" => "calcMode",
    "clippathunits" => "clipPathUnits",
    "diffuseconstant" => "diffuseConstant",
    "edgemode" => "edgeMode",
    "filterunits" => "filterUnits",
    "glyphref" => "glyphRef",
    "gradienttransform" => "gradientTransform",
    "gradientunits" => "gradientUnits",
    "kernelmatrix" => "kernelMatrix",
    "kernelunitlength" => "kernelUnitLength",
    "keypoints" => "keyPoints",
    "keysplines" => "keySplines",
    "keytimes" => "keyTimes",
    "lengthadjust" => "lengthAdjust",
    "limitingconeangle" => "limitingConeAngle",
    "markerheight" => "markerHeight",
    "markerunits" => "markerUnits",
    "markerwidth" => "markerWidth",
    "maskcontentunits" => "maskContentUnits",
    "maskunits" => "maskUnits",
    "numoctaves" => "numOctaves",
    "pathlength" => "pathLength",
    "patterncontentunits" => "patternContentUnits",
    "patterntransform" => "patternTransform",
    "patternunits" => "patternUnits",
    "pointsatx" => "pointsAtX",
    "pointsaty" => "pointsAtY",
    "pointsatz" => "pointsAtZ",
    "preservealpha" => "preserveAlpha",
    "preserveaspectratio" => "preserveAspectRatio",
    "primitiveunits" => "primitiveUnits",
    "refx" => "refX",
    "refy" => "refY",
    "repeatcount" => "repeatCount",
    "repeatdur" => "repeatDur",
    "requiredextensions" => "requiredExtensions",
    "requiredfeatures" => "requiredFeatures",
    "specularconstant" => "specularConstant",
    "specularexponent" => "specularExponent",
    "spreadmethod" => "spreadMethod",
    "startoffset" => "startOffset",
    "stddeviation" => "stdDeviation",
    "stitchtiles" => "stitchTiles",
    "surfacescale" => "surfaceScale",
    "systemlanguage" => "systemLanguage",
    "tablevalues" => "tableValues",
    "targetx" => "targetX",
    "targety" => "targetY",
    "textlength" => "textLength",
    "viewbox" => "viewBox",
    "viewtarget" => "viewTarget",
    "xchannelselector" => "xChannelSelector",
    "ychannelselector" => "yChannelSelector",
    "zoomandpan" => "zoomAndPan"
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

  defp adjust_attr_key(:svg, key) when is_map_key(@svg_attr_case_adjustments, key) do
    @svg_attr_case_adjustments[key]
  end

  defp adjust_attr_key(_ns, key), do: key

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

  defp foreign_namespace(%{stack: stack, elements: elements}) do
    Enum.find_value(stack, fn ref ->
      case elements[ref] do
        %{tag: {ns, _}} when ns in [:svg, :math] -> ns
        _ -> nil
      end
    end)
  end

  @html_integration_encodings ["text/html", "application/xhtml+xml"]

  defp html_integration_point?(%{stack: [], elements: _}), do: false

  defp html_integration_point?(%{stack: [ref | _], elements: elements}) do
    elem = elements[ref]

    case elem.tag do
      {:svg, tag} when tag in ~w(foreignObject desc title) ->
        true

      {:math, "annotation-xml"} ->
        case elem.attrs["encoding"] do
          nil -> false
          enc -> String.downcase(enc) in @html_integration_encodings
        end

      {:math, tag} when tag in ~w(mi mo mn ms mtext) ->
        true

      _ ->
        false
    end
  end

  defp mathml_text_integration_point?(%{stack: [ref | _], elements: elements}) do
    case elements[ref].tag do
      {:math, tag} when tag in ~w(mi mo mn ms mtext) -> true
      _ -> false
    end
  end

  defp mathml_text_integration_point?(_), do: false

  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  defp html_breakout_tag?(tag), do: tag in @html_breakout_tags

  defp close_foreign_content(%{stack: stack, elements: elements} = state) do
    # Pop all foreign elements from the stack
    # With ref-only architecture, children are already in elements map
    {new_stack, parent_ref} = pop_foreign_elements(stack, elements)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
  end

  defp pop_foreign_elements([], _elements), do: {[], nil}

  defp pop_foreign_elements([ref | rest] = stack, elements) do
    case elements[ref].tag do
      {ns, _} when ns in [:svg, :math] ->
        pop_foreign_elements(rest, elements)

      _ ->
        # Return the ref itself as parent - new elements should be children
        # of this non-foreign element (e.g., body), not its parent
        {stack, ref}
    end
  end

  # --------------------------------------------------------------------------
  # Document structure
  # --------------------------------------------------------------------------

  defp ensure_html(%{stack: []} = state) do
    # Create html element and add to elements map
    elem = new_element("html", %{}, nil)
    elements = Map.put(state.elements, elem.ref, elem)

    %{
      state
      | stack: [elem.ref],
        elements: elements,
        current_parent_ref: elem.ref,
        mode: :before_head
    }
  end

  defp ensure_html(state), do: state

  defp ensure_head(state) do
    case current_tag(state) do
      tag when tag in ["head", "body"] ->
        state

      "html" ->
        html_elem = current_element(state)

        if has_tag_in_children?(state, html_elem.children, "head") do
          state
        else
          state
          |> push_element("head", %{})
          |> set_mode(:in_head)
        end

      _ ->
        state
    end
  end

  defp has_tag_in_children?(%{elements: elements}, children, tag) do
    Enum.any?(children, fn
      ref when is_reference(ref) -> elements[ref].tag == tag
      _ -> false
    end)
  end

  defp close_head(state) do
    if current_tag(state) == "head" do
      state
      |> pop_element()
      |> set_mode(:after_head)
    else
      state
    end
  end

  defp ensure_body(state) do
    case current_tag(state) do
      tag when tag in ["body", "frameset", nil] ->
        state

      "html" ->
        html_elem = current_element(state)

        if has_tag_in_children?(state, html_elem.children, "frameset") do
          state
        else
          state
          |> push_element("body", %{})
          |> set_mode(:in_body)
        end

      _ ->
        state
    end
  end

  defp has_body_content?(%{stack: stack, elements: elements}) do
    Enum.any?(stack, fn ref ->
      elements[ref].tag not in ["html", "head"]
    end)
  end

  # Modes that can delegate to InBody without mode being changed
  @body_modes [
    :in_body,
    :in_select,
    :in_select_in_table,
    :in_table,
    :in_template,
    :in_cell,
    :in_row,
    :in_caption,
    :in_table_body
  ]

  defp in_body(%{mode: mode, stack: []} = state) when mode in @body_modes do
    transition_to(%{state | mode: :initial}, :in_body)
  end

  defp in_body(%{mode: mode} = state) when mode in @body_modes, do: state

  defp in_body(state) do
    if in_template?(state) do
      state
    else
      transition_to(state, :in_body)
    end
  end

  defp in_template?(%{stack: stack, elements: elements}), do: do_in_template?(stack, elements)

  defp do_in_template?([], _elements), do: false

  defp do_in_template?([ref | rest], elements) do
    case elements[ref].tag do
      "template" -> true
      tag when tag in ~w(html body head) -> false
      _ -> do_in_template?(rest, elements)
    end
  end

  defp transition_to(%{mode: mode} = state, :in_body) do
    case mode do
      m when m in @body_modes ->
        state

      m when m in [:in_frameset, :after_frameset] ->
        state
        |> ensure_body()
        |> set_mode(:in_body)

      _ ->
        state
        |> ensure_body_context()
        |> set_mode(:in_body)
    end
  end

  defp ensure_body_context(state) do
    state
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> ensure_body()
  end

  defp merge_html_attrs(state, new_attrs) when new_attrs == %{}, do: state

  defp merge_html_attrs(%{stack: stack, elements: elements} = state, new_attrs) do
    # Find html element ref and merge attrs
    case find_html_ref(stack, elements) do
      nil ->
        state

      html_ref ->
        html_elem = elements[html_ref]
        merged = Map.merge(new_attrs, html_elem.attrs)
        new_elements = Map.put(elements, html_ref, %{html_elem | attrs: merged})
        %{state | elements: new_elements}
    end
  end

  defp find_html_ref([], _elements), do: nil

  defp find_html_ref([ref | rest], elements) do
    case elements[ref].tag do
      "html" -> ref
      _ -> find_html_ref(rest, elements)
    end
  end

  # Reopen head element (put it back on the stack)
  defp maybe_reopen_head(state) do
    if current_tag(state) == "head" do
      state
    else
      do_reopen_head(state)
    end
  end

  defp do_reopen_head(%{stack: stack, elements: elements} = state) do
    # Find html element in stack
    case find_html_ref(stack, elements) do
      nil ->
        # No html, just push a new head
        push_element(state, "head", %{})

      html_ref ->
        html_elem = elements[html_ref]

        # Find head ref in html's children
        case find_head_ref_in_children(html_elem.children, elements) do
          nil ->
            # No head exists, push new one
            push_element(state, "head", %{})

          head_ref ->
            # Reopen existing head by pushing it to stack
            %{state | stack: [head_ref | stack], current_parent_ref: head_ref}
        end
    end
  end

  defp find_head_ref_in_children([], _elements), do: nil

  defp find_head_ref_in_children([child | rest], elements) do
    case child do
      ref when is_reference(ref) ->
        if elements[ref].tag == "head" do
          ref
        else
          find_head_ref_in_children(rest, elements)
        end

      _ ->
        find_head_ref_in_children(rest, elements)
    end
  end

  # Merge attributes from second <body> onto existing body element
  # Per HTML5: adds attributes that don't already exist
  defp merge_body_attrs(%{stack: stack, elements: elements} = state, new_attrs) do
    case find_body_ref(stack, elements) do
      nil ->
        state

      body_ref ->
        body_elem = elements[body_ref]
        # Only add attrs that don't already exist on the body
        merged_attrs = Map.merge(new_attrs, body_elem.attrs)
        updated_body = %{body_elem | attrs: merged_attrs}
        %{state | elements: Map.put(elements, body_ref, updated_body)}
    end
  end

  defp find_body_ref([], _elements), do: nil

  defp find_body_ref([ref | rest], elements) do
    case elements[ref] do
      %{tag: "body"} -> ref
      _ -> find_body_ref(rest, elements)
    end
  end

  defp close_body_for_frameset(%{stack: stack, elements: elements} = state) do
    {new_stack, new_elements, parent_ref} = do_close_body_for_frameset(stack, elements)
    %{state | stack: new_stack, elements: new_elements, current_parent_ref: parent_ref}
  end

  defp do_close_body_for_frameset([], elements), do: {[], elements, nil}

  defp do_close_body_for_frameset([ref | rest] = stack, elements) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    case tag do
      "body" ->
        new_elements = remove_child_from_parent(elements, ref, parent_ref)
        {rest, new_elements, parent_ref}

      "html" ->
        {stack, elements, ref}

      _ ->
        do_close_body_for_frameset(rest, elements)
    end
  end

  defp remove_child_from_parent(elements, _child_ref, nil), do: elements

  defp remove_child_from_parent(elements, child_ref, parent_ref) do
    Map.update!(elements, parent_ref, fn parent ->
      %{parent | children: List.delete(parent.children, child_ref)}
    end)
  end

  # --------------------------------------------------------------------------
  # Mode transitions
  # --------------------------------------------------------------------------

  defp push_mode(%{mode: current_mode, template_mode_stack: stack} = state, new_mode) do
    %{state | mode: new_mode, template_mode_stack: [current_mode | stack]}
  end

  defp reset_insertion_mode(
         %{stack: stack, elements: elements, template_mode_stack: template_mode_stack} = state
       ) do
    mode = determine_mode_from_stack(stack, elements)
    %{state | mode: mode, template_mode_stack: Enum.drop(template_mode_stack, 1)}
  end

  defp determine_mode_from_stack([], _elements), do: :in_body

  defp determine_mode_from_stack([ref | rest], elements) do
    tag = elements[ref].tag

    case Map.get(@tag_to_mode, tag) do
      nil ->
        determine_mode_from_stack(rest, elements)

      # Per HTML5 spec: if select and table ancestor exists, use in_select_in_table
      :in_select ->
        if has_table_ancestor?(rest, elements) do
          :in_select_in_table
        else
          :in_select
        end

      mode ->
        mode
    end
  end

  defp has_table_ancestor?([], _elements), do: false

  defp has_table_ancestor?([ref | rest], elements) do
    case elements[ref].tag do
      "table" -> true
      "template" -> false
      _ -> has_table_ancestor?(rest, elements)
    end
  end

  defp maybe_skip_leading_newline(state, <<?\n, rest::binary>>) do
    case current_element(state) do
      %{tag: tag, children: []} when tag in @newline_skipping_elements ->
        rest

      _ ->
        <<?\n, rest::binary>>
    end
  end

  defp maybe_skip_leading_newline(_state, text), do: text

  # --------------------------------------------------------------------------
  # Frameset-ok flag
  # --------------------------------------------------------------------------

  defp maybe_set_frameset_not_ok(%{frameset_ok: false} = state, _text), do: state

  defp maybe_set_frameset_not_ok(state, text) do
    if String.trim(text) == "" do
      state
    else
      %{state | frameset_ok: false}
    end
  end

  defp set_frameset_not_ok(state), do: %{state | frameset_ok: false}

  defp maybe_set_frameset_not_ok_for_element(state, tag)
       when tag in @frameset_disabling_elements do
    set_frameset_not_ok(state)
  end

  defp maybe_set_frameset_not_ok_for_element(state, _tag), do: state

  # Per HTML5 spec: only set frameset-ok to "not ok" if input is NOT type="hidden"
  defp maybe_set_frameset_not_ok_for_input(state, attrs) do
    if hidden_input?(attrs) do
      state
    else
      set_frameset_not_ok(state)
    end
  end

  defp hidden_input?(attrs) do
    Enum.any?(attrs, fn
      {"type", value} -> String.downcase(value) == "hidden"
      _ -> false
    end)
  end

  # --------------------------------------------------------------------------
  # Scope helpers
  # --------------------------------------------------------------------------

  defp close_option_optgroup_in_select(state) do
    if current_tag(state) in ["option", "optgroup"] do
      state
      |> pop_element()
      |> close_option_optgroup_in_select()
    else
      state
    end
  end

  defp close_select(state) do
    close_tag_ref(state, "select") |> pop_mode()
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  @table_body_boundaries @table_sections ++ ["table", "template", "html"]
  @table_row_boundaries @table_row_context ++ ["table", "template", "html"]
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_body_context(state) do
    pop_until_one_of(state, @table_body_boundaries)
  end

  defp clear_to_table_row_context(state) do
    pop_until_one_of(state, @table_row_boundaries)
  end

  defp clear_to_table_context(state) do
    pop_until_one_of(state, @table_boundaries)
  end

  defp get_refs_to_close_for_table(%{stack: stack, elements: elements}) do
    do_get_refs_to_close_for_table(stack, elements, MapSet.new())
  end

  defp do_get_refs_to_close_for_table([], _elements, acc), do: acc

  defp do_get_refs_to_close_for_table([ref | rest], elements, acc) do
    case elements[ref].tag do
      "table" -> MapSet.put(acc, ref)
      tag when tag in ["template", "html"] -> acc
      _ -> do_get_refs_to_close_for_table(rest, elements, MapSet.put(acc, ref))
    end
  end

  defp ensure_table_context(state) do
    state
    |> ensure_tbody()
    |> ensure_tr()
  end

  defp ensure_tbody(state) do
    case current_tag(state) do
      "table" -> push_element(state, "tbody", %{})
      tag when tag in @table_sections -> state
      "tr" -> state
      _ -> state
    end
  end

  defp ensure_tr(state) do
    case current_tag(state) do
      tag when tag in @table_sections ->
        push_element(state, "tr", %{})

      "tr" ->
        state

      "template" ->
        elem = current_element(state)

        if has_table_row_structure?(state, elem.children) do
          push_element(state, "tr", %{})
        else
          state
        end

      _ ->
        state
    end
  end

  defp has_table_row_structure?(%{elements: elements}, children) do
    Enum.any?(children, fn
      ref when is_reference(ref) -> elements[ref].tag in ~w(tr tbody thead tfoot)
      _ -> false
    end)
  end

  @colgroup_close_tags ["td", "th", "tr"] ++ @table_sections

  defp ensure_colgroup(state) do
    case current_tag(state) do
      "colgroup" -> state
      "table" -> push_element(state, "colgroup", %{})
      tag when tag in @colgroup_close_tags -> state |> pop_element() |> ensure_colgroup()
      _ -> state
    end
  end

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(%{af: af} = state, tag) when tag in @closes_p do
    case find_p_in_scope_ref(state) do
      nil ->
        state

      {p_ref, refs_above} ->
        # Remove non-formatting refs from af
        non_formatting_refs =
          [p_ref | refs_above]
          |> Enum.reject(fn ref -> state.elements[ref].tag in @formatting_elements end)
          |> MapSet.new()

        new_af = reject_refs_from_af(af, non_formatting_refs)

        # Pop to p element (children already in elements map)
        {new_stack, parent_ref} = pop_to_ref(state.stack, state.elements, p_ref)
        %{state | stack: new_stack, af: new_af, current_parent_ref: parent_ref}
    end
  end

  defp maybe_close_p(state, _tag), do: state

  defp close_p_in_scope_ref(state) do
    case find_p_in_scope_ref(state) do
      nil ->
        :not_found

      {p_ref, _refs_above} ->
        {new_stack, parent_ref} = pop_to_ref(state.stack, state.elements, p_ref)
        {:found, %{state | stack: new_stack, current_parent_ref: parent_ref}}
    end
  end

  defp find_p_in_scope_ref(%{stack: stack, elements: elements}) do
    do_find_p_in_scope_ref(stack, elements, [])
  end

  defp do_find_p_in_scope_ref([], _elements, _above), do: nil

  defp do_find_p_in_scope_ref([ref | rest], elements, above) when is_map_key(elements, ref) do
    case elements[ref].tag do
      "p" ->
        {ref, Enum.reverse(above)}

      tag when is_button_scope_boundary(tag) ->
        nil

      {ns, _} when ns in [:svg, :math] ->
        nil

      _ ->
        do_find_p_in_scope_ref(rest, elements, [ref | above])
    end
  end

  defp do_find_p_in_scope_ref([_ref | rest], elements, above) do
    do_find_p_in_scope_ref(rest, elements, above)
  end

  defp pop_to_ref([], _elements, _target), do: {[], nil}
  defp pop_to_ref([ref | rest], elements, ref), do: {rest, elements[ref].parent_ref}
  defp pop_to_ref([_ | rest], elements, target), do: pop_to_ref(rest, elements, target)

  @implicit_close_boundaries ~w(table template body html)
  @li_scope_boundaries ~w(ol ul table template body html)

  defp maybe_close_same(%{stack: stack, elements: elements} = state, tag) do
    case get_implicit_close_config(tag) do
      nil ->
        state

      {closes, boundaries, close_all?} ->
        result =
          if close_all? do
            pop_to_implicit_close_all_ref(stack, elements, closes, boundaries)
          else
            pop_to_implicit_close_ref(stack, elements, closes, boundaries)
          end

        case result do
          {:ok, new_stack, parent_ref} ->
            %{state | stack: new_stack, current_parent_ref: parent_ref}

          :not_found ->
            state
        end
    end
  end

  defp get_implicit_close_config("li"), do: {["li"], @li_scope_boundaries, false}

  for {tag, also_closes} <- @implicit_closes, tag != "li" do
    closes = [tag | also_closes]
    close_all? = tag in @ruby_elements

    defp get_implicit_close_config(unquote(tag)) do
      {unquote(closes), @implicit_close_boundaries, unquote(close_all?)}
    end
  end

  defp get_implicit_close_config(_), do: nil

  defp pop_to_implicit_close_ref([], _elements, _closes, _boundaries), do: :not_found

  defp pop_to_implicit_close_ref([ref | rest], elements, closes, boundaries) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag in boundaries -> :not_found
      tag in closes -> {:ok, rest, parent_ref}
      true -> pop_to_implicit_close_ref(rest, elements, closes, boundaries)
    end
  end

  defp pop_to_implicit_close_all_ref(stack, elements, closes, boundaries) do
    do_pop_to_implicit_close_all_ref(stack, elements, closes, boundaries, false)
  end

  defp do_pop_to_implicit_close_all_ref(stack, elements, closes, boundaries, found_any) do
    case pop_to_implicit_close_ref(stack, elements, closes, boundaries) do
      {:ok, new_stack, _parent_ref} ->
        do_pop_to_implicit_close_all_ref(new_stack, elements, closes, boundaries, true)

      :not_found when found_any ->
        # Return the top of stack as the new parent
        parent_ref = List.first(stack)
        {:ok, stack, parent_ref}

      :not_found ->
        :not_found
    end
  end

  # --------------------------------------------------------------------------
  # Close tag
  # --------------------------------------------------------------------------

  # Tags that are implicitly closed (popped) when generating implied end tags
  @implied_end_tag_tags ~w(dd dt li optgroup option p rb rp rt rtc)

  # Close tag using ref-only stack architecture (respects special element stops)
  # Used for "any other end tag" per HTML5 spec
  defp close_tag_ref(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_tag_ref(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  # Close tag for specifically-handled end tags (template, table, select, frameset)
  # Does NOT respect special element stops - only template is a barrier
  defp close_tag_ref_forced(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_tag_ref_block(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  # Close block-level end tag: generate implied end tags, then pop until match
  # Does NOT use special element stops - only template is a barrier
  defp close_block_end_tag(state, tag) do
    state
    |> generate_implied_end_tags()
    |> do_close_block_end_tag(tag)
  end

  defp do_close_block_end_tag(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_tag_ref_block(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  # Generate implied end tags per HTML5 spec
  defp generate_implied_end_tags(%{stack: [ref | rest], elements: elements} = state)
       when is_map_key(elements, ref) do
    case elements[ref] do
      %{tag: tag} when tag in @implied_end_tag_tags ->
        parent_ref = elements[ref].parent_ref
        generate_implied_end_tags(%{state | stack: rest, current_parent_ref: parent_ref})

      _ ->
        state
    end
  end

  defp generate_implied_end_tags(state), do: state

  # Close any heading element (h1-h6) per HTML5 spec
  # Any heading end tag closes any open heading element
  defp close_any_heading(%{stack: stack, elements: elements} = state) do
    case pop_until_any_heading(stack, elements) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  defp pop_until_any_heading([], _elements), do: :not_found

  defp pop_until_any_heading([ref | rest], elements) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag in @headings -> {:found, rest, parent_ref}
      tag == "template" -> :not_found
      true -> pop_until_any_heading(rest, elements)
    end
  end

  # Close li only if li is in list item scope (ul/ol are barriers)
  # List item scope barriers: ol, ul, plus standard scope barriers
  @list_item_scope_barriers ~w(ol ul applet caption html table td th marquee object template)
  defp close_li_in_list_scope(%{stack: stack, elements: elements} = state) do
    case find_li_in_list_scope(stack, elements) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  defp find_li_in_list_scope([], _elements), do: :not_found

  defp find_li_in_list_scope([ref | rest], elements) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag == "li" -> {:found, rest, parent_ref}
      tag in @list_item_scope_barriers -> :not_found
      true -> find_li_in_list_scope(rest, elements)
    end
  end

  defp find_li_in_list_scope([_ | rest], elements), do: find_li_in_list_scope(rest, elements)

  # Close dd/dt only if in scope (dl is not a barrier for dd/dt unlike ul/ol for li)
  defp close_dd_dt_in_scope(%{stack: stack, elements: elements} = state, target) do
    case find_dd_dt_in_scope(stack, elements, target) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  @scope_barriers ~w(applet caption html table td th marquee object template)
  defp find_dd_dt_in_scope([], _elements, _target), do: :not_found

  defp find_dd_dt_in_scope([ref | rest], elements, target) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag == target -> {:found, rest, parent_ref}
      tag in @scope_barriers -> :not_found
      true -> find_dd_dt_in_scope(rest, elements, target)
    end
  end

  defp find_dd_dt_in_scope([_ | rest], elements, target),
    do: find_dd_dt_in_scope(rest, elements, target)

  defp pop_until_tag_ref(stack, elements, target) do
    do_pop_until_tag_ref(stack, elements, target)
  end

  defp do_pop_until_tag_ref([], _elements, _target), do: :not_found

  defp do_pop_until_tag_ref([ref | rest], elements, target) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    case tag do
      ^target ->
        {:found, rest, parent_ref}

      {:svg, ^target} ->
        {:found, rest, parent_ref}

      {:math, ^target} ->
        {:found, rest, parent_ref}

      # Per HTML5 spec: if node is in special category, stop (parse error)
      special when is_binary(special) and special in @special_elements ->
        :not_found

      _ ->
        do_pop_until_tag_ref(rest, elements, target)
    end
  end

  defp do_pop_until_tag_ref([_ref | rest], elements, target) do
    do_pop_until_tag_ref(rest, elements, target)
  end

  # Pop until tag for block-level end tags - only template is a barrier
  defp pop_until_tag_ref_block([], _elements, _target), do: :not_found

  defp pop_until_tag_ref_block([ref | rest], elements, target)
       when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    case tag do
      ^target -> {:found, rest, parent_ref}
      {:svg, ^target} -> {:found, rest, parent_ref}
      {:math, ^target} -> {:found, rest, parent_ref}
      "template" -> :not_found
      _ -> pop_until_tag_ref_block(rest, elements, target)
    end
  end

  defp pop_until_tag_ref_block([_ref | rest], elements, target) do
    pop_until_tag_ref_block(rest, elements, target)
  end

  # --------------------------------------------------------------------------
  # Active formatting elements
  # --------------------------------------------------------------------------

  defp reconstruct_active_formatting(%{stack: stack, af: af} = state) do
    af
    |> get_entries_to_reconstruct(stack)
    |> reconstruct_entries(state)
  end

  defp get_entries_to_reconstruct(af, stack) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.reverse()
    |> Enum.filter(fn {ref, _tag, _attrs} -> find_in_stack_by_ref(stack, ref) == nil end)
  end

  defp find_in_stack_by_ref(stack, target_ref) do
    Enum.find_index(stack, &(&1 == target_ref))
  end

  defp reconstruct_entries([], state), do: state

  defp reconstruct_entries(
         [{old_ref, tag, attrs} | rest],
         %{stack: stack, af: af, elements: elements, current_parent_ref: parent_ref} = state
       ) do
    # Create new element with proper parent
    new_elem = new_element(tag, attrs, parent_ref)

    # Add to elements map
    new_elements = Map.put(elements, new_elem.ref, new_elem)

    # Add as child of current parent
    new_elements =
      if parent_ref && is_map_key(new_elements, parent_ref) do
        Map.update!(new_elements, parent_ref, fn p ->
          %{p | children: [new_elem.ref | p.children]}
        end)
      else
        new_elements
      end

    # Push ref onto stack (not the whole element)
    new_stack = [new_elem.ref | stack]

    # Update AF entry to point to new ref
    new_af = update_af_entry(af, old_ref, {new_elem.ref, tag, attrs})

    # Continue with updated state, new element becomes current parent
    reconstruct_entries(rest, %{
      state
      | stack: new_stack,
        af: new_af,
        elements: new_elements,
        current_parent_ref: new_elem.ref
    })
  end

  defp update_af_entry(af, old_ref, new_entry) do
    Enum.map(af, fn
      {^old_ref, _, _} -> new_entry
      entry -> entry
    end)
  end

  defp add_formatting_entry(%{stack: [ref | _], af: af} = state, tag, attrs) do
    %{state | af: apply_noahs_ark([{ref, tag, attrs} | af], tag, attrs)}
  end

  defp maybe_close_existing_formatting(%{af: af} = state, tag) do
    if find_formatting_entry(af, tag) do
      state = AdoptionAgency.run(state, tag, &close_tag_ref/2)
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

  defp clear_af_to_marker(af) do
    af
    |> Enum.drop_while(&(&1 != :marker))
    |> Enum.drop(1)
  end

  defp reject_refs_from_af(af, refs) do
    Enum.reject(af, fn
      :marker -> false
      {ref, _, _} -> MapSet.member?(refs, ref)
    end)
  end

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
end
