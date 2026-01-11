defmodule PureHTML.TreeBuilder.Modes.InBody do
  @moduledoc """
  HTML5 "in body" insertion mode.

  This is the main parsing mode for document content inside <body>.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)
  @special_elements ~w(
    address applet area article aside base basefont bgsound blockquote body br button
    caption center col colgroup dd details dialog dir div dl dt embed fieldset
    figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hgroup
    hr html iframe img input keygen li link listing main marquee menu menuitem meta
    nav noembed noframes noscript object ol p param plaintext pre ruby script section
    select source style summary table tbody td template textarea tfoot th thead title
    tr track ul wbr xmp
  )
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)
  @table_context ~w(table tbody thead tfoot tr)
  @table_elements ~w(table caption colgroup col thead tbody tfoot tr td th script template style)
  @table_sections ~w(tbody thead tfoot)
  @table_cells ~w(td th)
  @table_row_context ~w(tr tbody thead tfoot)
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)

  @closes_p ~w(address article aside blockquote center details dialog dir div dl dd dt
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr li listing main menu nav ol p plaintext pre rb rp rt rtc section summary table ul)

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

  @frameset_disabling_elements ~w(pre listing form textarea xmp iframe noembed noframes select embed
                                  keygen applet marquee object table button img input hr br wbr area
                                  dd dt li plaintext rb rtc)

  @adopt_on_duplicate_elements ~w(a nobr)
  @table_structure_elements @table_sections ++ ["caption", "colgroup"]
  @ruby_elements ~w(rb rt rtc rp)

  # Scope boundary guards
  @scope_boundaries ~w(applet caption html table td th marquee object template)
  defguardp is_scope_boundary(tag) when tag in @scope_boundaries

  @button_scope_extras ~w(button)
  defguardp is_button_scope_boundary(tag)
            when tag in @scope_boundaries or tag in @button_scope_extras

  defguardp is_table_scope_boundary(tag)
            when tag in ~w(td th caption template body html)

  defguardp is_select_scope_boundary(tag)
            when tag in ~w(template body html)

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

  def process({:character, text}, %{stack: [%{tag: tag} | _]} = state)
      when tag in @head_elements do
    {:ok, add_text_to_stack(state, text)}
  end

  def process({:character, text}, %{stack: [%{tag: tag} | _]} = state)
      when tag in @table_context do
    if String.trim(text) == "" do
      {:ok, add_text_to_stack(state, text)}
    else
      {:ok, foster_text_to_stack(state, text)}
    end
  end

  def process({:character, text}, state) do
    state =
      state
      |> in_body()
      |> reconstruct_active_formatting()
      |> add_text_to_stack(text)
      |> maybe_set_frameset_not_ok(text)

    {:ok, state}
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
  def process({:end_tag, tag} = token, %{stack: stack} = state) when tag in ~w(p br) do
    case foreign_namespace(stack) do
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
    {:ok, run_adoption_agency(state, tag)}
  end

  def process({:end_tag, tag}, %{stack: stack, af: af} = state) when tag in @table_cells do
    {:ok, %{state | stack: close_tag(tag, stack), af: clear_af_to_marker(af)}}
  end

  def process({:end_tag, "table"}, %{stack: stack, af: af} = state) do
    closed_refs = get_refs_to_close_for_table(stack)
    af = reject_refs_from_af(af, closed_refs)
    stack = do_clear_to_table_context(stack)
    {:ok, %{state | stack: close_tag("table", stack), af: af} |> pop_mode()}
  end

  def process({:end_tag, "select"}, %{stack: stack} = state) do
    {:ok, %{state | stack: close_tag("select", stack)} |> pop_mode()}
  end

  def process({:end_tag, "template"}, %{stack: stack, af: af} = state) do
    new_stack = close_tag("template", stack)
    {:ok, %{state | stack: new_stack, af: clear_af_to_marker(af)} |> reset_insertion_mode()}
  end

  def process({:end_tag, "frameset"}, %{stack: stack} = state) do
    {:ok, %{state | stack: close_tag("frameset", stack), mode: :after_frameset}}
  end

  def process({:end_tag, tag}, %{stack: stack} = state) do
    {:ok, %{state | stack: close_tag(tag, stack)}}
  end

  # --------------------------------------------------------------------------
  # Start tags
  # --------------------------------------------------------------------------

  def process({:start_tag, "html", attrs, _}, %{stack: []} = state) do
    {:ok, %{state | stack: [new_element("html", attrs)], mode: :before_head}}
  end

  def process({:start_tag, "html", attrs, _}, state) do
    {:ok, merge_html_attrs(state, attrs)}
  end

  def process({:start_tag, "head", attrs, _}, state) do
    state =
      state
      |> ensure_html()
      |> push_element("head", attrs)
      |> set_mode(:in_head)

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
          set_frameset_not_ok(s)
      end)

    {:ok, state}
  end

  def process({:start_tag, "svg", attrs, self_closing}, state) do
    {:ok, state |> in_body() |> push_foreign_element(:svg, "svg", attrs, self_closing)}
  end

  def process({:start_tag, "math", attrs, self_closing}, state) do
    {:ok, state |> in_body() |> push_foreign_element(:math, "math", attrs, self_closing)}
  end

  def process({:start_tag, tag, attrs, self_closing}, %{stack: stack} = state) do
    tag = correct_tag(tag)
    ns = foreign_namespace(stack)

    state =
      cond do
        is_nil(ns) or html_integration_point?(stack) ->
          process_html_start_tag(tag, attrs, self_closing, state)

        html_breakout_tag?(tag) ->
          state = close_foreign_content(state)
          process_html_start_tag(tag, attrs, self_closing, state)

        true ->
          push_foreign_element(state, ns, tag, attrs, self_closing)
      end

    {:ok, state}
  end

  # Error tokens - ignore
  def process({:error, _}, state), do: {:ok, state}

  # Helper for end tags that break out of foreign content
  defp do_process_end_tag({:end_tag, "p"}, %{stack: stack} = state) do
    case close_p_in_scope(stack) do
      {:found, new_stack} ->
        {:ok, %{state | stack: new_stack}}

      :not_found ->
        {:ok, add_child_to_stack(state, new_element("p"))}
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

  defp process_html_start_tag(tag, attrs, self_closing, state)
       when tag in ["frameset", "frame"] do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  defp process_html_start_tag(tag, attrs, self_closing, %{stack: stack} = state)
       when tag not in @table_elements do
    if in_table_context?(stack) and not in_select?(stack) do
      process_foster_start_tag(tag, attrs, self_closing, state)
    else
      do_process_html_start_tag(tag, attrs, self_closing, state)
    end
  end

  defp process_html_start_tag(tag, attrs, self_closing, state) do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  # Template in template mode
  defp do_process_html_start_tag("template", attrs, _, %{mode: :in_template} = state) do
    state
    |> reconstruct_active_formatting()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> push_af_marker()
  end

  # Template in body/table/select modes
  defp do_process_html_start_tag("template", attrs, _, %{mode: mode, stack: stack} = state)
       when mode in [:in_body, :in_table, :in_select] do
    if has_tag?(stack, "body") do
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
  defp do_process_html_start_tag(tag, attrs, self_closing, %{mode: mode, stack: stack} = state)
       when tag in @head_elements and mode in [:in_template, :in_body, :in_table, :in_select] do
    if has_tag?(stack, "body") or mode == :in_template do
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
  defp do_process_html_start_tag("template", attrs, _, %{stack: stack} = state) do
    if has_tag?(stack, "body") do
      process_start_tag(state, "template", attrs, false)
    else
      do_process_html_start_tag_head_context("template", attrs, state)
    end
  end

  # Other head elements
  defp do_process_html_start_tag(tag, attrs, self_closing, %{stack: stack} = state)
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

  defp do_process_html_start_tag("frameset", attrs, _, %{stack: stack} = state) do
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

  # Frame in frameset
  defp do_process_html_start_tag("frame", attrs, _, %{stack: [%{tag: "frameset"} | _]} = state) do
    add_child_to_stack(state, {"frame", attrs, []})
  end

  defp do_process_html_start_tag("frame", _, _, state), do: state

  # Col in table mode
  defp do_process_html_start_tag("col", attrs, _, %{mode: :in_table, stack: stack} = state) do
    if has_tag?(stack, "table") do
      state |> ensure_colgroup() |> add_child_to_stack({"col", attrs, []})
    else
      add_child_to_stack(state, {"col", attrs, []})
    end
  end

  # Hr in select
  defp do_process_html_start_tag("hr", attrs, _, %{mode: :in_select} = state) do
    state
    |> close_option_optgroup_in_select()
    |> add_child_to_stack({"hr", attrs, []})
  end

  # Input/keygen/textarea in select
  defp do_process_html_start_tag(tag, attrs, self_closing, %{mode: :in_select} = state)
       when tag in ["input", "keygen", "textarea"] do
    state
    |> close_select()
    |> then(&do_process_html_start_tag(tag, attrs, self_closing, &1))
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

  # Col in template
  defp do_process_html_start_tag("col", attrs, _, %{mode: :in_template} = state) do
    state
    |> switch_template_mode(:in_table)
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
  defp do_process_html_start_tag(tag, attrs, _, %{mode: :in_table, stack: stack} = state)
       when tag in @table_structure_elements do
    if has_tag?(stack, "table") do
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
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @adopt_on_duplicate_elements do
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

  # Select
  defp do_process_html_start_tag("select", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element("select", attrs)
    |> push_mode(:in_select)
    |> set_frameset_not_ok()
  end

  # Generic
  defp do_process_html_start_tag(tag, attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> maybe_close_same(tag)
    |> push_element(tag, attrs)
    |> reconstruct_active_formatting()
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

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
  # Element creation
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs \\ %{}) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  defp new_foreign_element(ns, tag, attrs) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: []}
  end

  defp correct_tag(tag) do
    case tag do
      "image" -> "img"
      _ -> tag
    end
  end

  # --------------------------------------------------------------------------
  # Stack operations
  # --------------------------------------------------------------------------

  defp add_text_to_stack(%{stack: stack} = state, text) do
    %{state | stack: add_text_child(stack, text)}
  end

  defp add_text_child([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text_child([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text_child([], _text), do: []

  defp add_child_to_stack(%{stack: stack} = state, child) do
    %{state | stack: add_child(stack, child)}
  end

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], child), do: [child]

  defp push_element(%{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  # --------------------------------------------------------------------------
  # Foreign content
  # --------------------------------------------------------------------------

  defp push_foreign_element(%{stack: stack} = state, ns, tag, attrs, true) do
    adjusted_tag = adjust_svg_tag(ns, tag)
    adjusted_attrs = adjust_foreign_attributes(ns, attrs)
    %{state | stack: add_child(stack, {{ns, adjusted_tag}, adjusted_attrs, []})}
  end

  defp push_foreign_element(%{stack: stack} = state, ns, tag, attrs, _) do
    adjusted_tag = adjust_svg_tag(ns, tag)
    adjusted_attrs = adjust_foreign_attributes(ns, attrs)
    %{state | stack: [new_foreign_element(ns, adjusted_tag, adjusted_attrs) | stack]}
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

  @html_integration_encodings ["text/html", "application/xhtml+xml"]

  defp html_integration_point?([%{tag: {:svg, tag}} | _])
       when tag in ~w(foreignObject desc title),
       do: true

  defp html_integration_point?([
         %{tag: {:math, "annotation-xml"}, attrs: %{"encoding" => enc}} | _
       ]) do
    String.downcase(enc) in @html_integration_encodings
  end

  defp html_integration_point?([%{tag: {:math, tag}} | _]) when tag in ~w(mi mo mn ms mtext),
    do: true

  defp html_integration_point?(_), do: false

  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  defp html_breakout_tag?(tag), do: tag in @html_breakout_tags

  defp close_foreign_content(%{stack: stack} = state) do
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

  # --------------------------------------------------------------------------
  # Document structure
  # --------------------------------------------------------------------------

  defp ensure_html(%{stack: []} = state) do
    %{state | stack: [new_element("html")], mode: :before_head}
  end

  defp ensure_html(%{stack: [%{tag: "html"} | _]} = state), do: state
  defp ensure_html(state), do: state

  defp ensure_head(%{stack: [%{tag: "html", children: children} = html]} = state) do
    if has_tag?(children, "head") do
      state
    else
      head = new_element("head")
      %{state | stack: [head, html], mode: :in_head}
    end
  end

  defp ensure_head(%{stack: [%{tag: "head"} | _]} = state), do: state
  defp ensure_head(%{stack: [%{tag: "body"} | _]} = state), do: state
  defp ensure_head(state), do: state

  defp close_head(%{stack: [%{tag: "head"} = head | rest]} = state) do
    %{state | stack: add_child(rest, head), mode: :after_head}
  end

  defp close_head(state), do: state

  defp ensure_body(%{stack: [%{tag: "body"} | _]} = state), do: state
  defp ensure_body(%{stack: [%{tag: "frameset"} | _]} = state), do: state

  defp ensure_body(%{stack: [%{tag: "html", children: children} = html]} = state) do
    if has_tag?(children, "frameset") do
      state
    else
      body = new_element("body")
      %{state | stack: [body, html], mode: :in_body}
    end
  end

  defp ensure_body(%{stack: [current | rest]} = state) do
    %{stack: new_rest} = ensure_body(%{state | stack: rest})
    %{state | stack: [current | new_rest]}
  end

  defp ensure_body(%{stack: []} = state), do: state

  defp has_tag?(nodes, tag) do
    Enum.any?(nodes, fn
      %{tag: t} -> t == tag
      _ -> false
    end)
  end

  defp has_body_content?(stack) do
    Enum.any?(stack, fn
      %{tag: tag} -> tag not in ["html", "head"]
      _ -> true
    end)
  end

  @body_modes [:in_body, :in_select, :in_table, :in_template]

  defp in_body(%{mode: mode, stack: []} = state) when mode in @body_modes do
    transition_to(%{state | mode: :initial}, :in_body)
  end

  defp in_body(%{mode: mode} = state) when mode in @body_modes, do: state

  defp in_body(%{stack: stack} = state) do
    if in_template?(stack) do
      state
    else
      transition_to(state, :in_body)
    end
  end

  defp in_template?(stack), do: do_in_template?(stack)

  defp do_in_template?([%{tag: "template"} | _]), do: true
  defp do_in_template?([%{tag: tag} | _]) when tag in ~w(html body head), do: false
  defp do_in_template?([_ | rest]), do: do_in_template?(rest)
  defp do_in_template?([]), do: false

  defp transition_to(%{mode: mode} = state, :in_body) do
    case mode do
      m when m in @body_modes ->
        state

      m when m in [:initial, :before_html, :before_head, :in_head, :after_head] ->
        state
        |> ensure_html()
        |> ensure_head()
        |> close_head()
        |> ensure_body()
        |> set_mode(:in_body)

      m when m in [:in_frameset, :after_frameset] ->
        state
        |> ensure_body()
        |> set_mode(:in_body)

      _ ->
        state
        |> ensure_html()
        |> ensure_head()
        |> close_head()
        |> ensure_body()
        |> set_mode(:in_body)
    end
  end

  defp merge_html_attrs(state, new_attrs) when new_attrs == %{}, do: state

  defp merge_html_attrs(%{stack: stack} = state, new_attrs) do
    %{state | stack: do_merge_html_attrs(stack, new_attrs)}
  end

  defp do_merge_html_attrs([%{tag: "html", attrs: attrs} = html | rest], new_attrs) do
    merged = Map.merge(new_attrs, attrs)
    [%{html | attrs: merged} | rest]
  end

  defp do_merge_html_attrs([elem | rest], new_attrs) do
    [elem | do_merge_html_attrs(rest, new_attrs)]
  end

  defp do_merge_html_attrs([], _new_attrs), do: []

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

  defp maybe_reopen_head(%{stack: [%{tag: "head"} | _]} = state), do: state

  defp maybe_reopen_head(%{stack: stack} = state) do
    %{state | stack: reopen_head_for_element(stack)}
  end

  defp close_body_for_frameset(%{stack: stack} = state) do
    %{state | stack: do_close_body_for_frameset(stack)}
  end

  defp do_close_body_for_frameset([%{tag: "body"} | rest]), do: rest
  defp do_close_body_for_frameset([%{tag: "html"} | _] = stack), do: stack
  defp do_close_body_for_frameset([_ | rest]), do: do_close_body_for_frameset(rest)
  defp do_close_body_for_frameset([]), do: []

  # --------------------------------------------------------------------------
  # Mode transitions
  # --------------------------------------------------------------------------

  defp set_mode(state, mode), do: %{state | mode: mode}

  defp push_mode(%{mode: current_mode, template_mode_stack: stack} = state, new_mode) do
    %{state | mode: new_mode, template_mode_stack: [current_mode | stack]}
  end

  defp pop_mode(%{template_mode_stack: [prev_mode | rest]} = state) do
    %{state | mode: prev_mode, template_mode_stack: rest}
  end

  defp pop_mode(%{template_mode_stack: []} = state) do
    %{state | mode: :in_body}
  end

  defp switch_template_mode(%{template_mode_stack: template_mode_stack} = state, new_mode) do
    new_stack =
      case template_mode_stack do
        [_ | rest] -> [new_mode | rest]
        [] -> [new_mode]
      end

    %{state | mode: new_mode, template_mode_stack: new_stack}
  end

  defp reset_insertion_mode(%{stack: stack, template_mode_stack: template_mode_stack} = state) do
    mode = determine_mode_from_stack(stack)
    %{state | mode: mode, template_mode_stack: Enum.drop(template_mode_stack, 1)}
  end

  defp determine_mode_from_stack([]), do: :in_body
  defp determine_mode_from_stack([%{tag: "template"} | _]), do: :in_template

  defp determine_mode_from_stack([%{tag: tag} | _]) when tag in ~w(tbody thead tfoot),
    do: :in_table

  defp determine_mode_from_stack([%{tag: "tr"} | _]), do: :in_table
  defp determine_mode_from_stack([%{tag: tag} | _]) when tag in ~w(td th caption), do: :in_body
  defp determine_mode_from_stack([%{tag: "table"} | _]), do: :in_table
  defp determine_mode_from_stack([%{tag: "body"} | _]), do: :in_body
  defp determine_mode_from_stack([%{tag: "frameset"} | _]), do: :in_frameset
  defp determine_mode_from_stack([%{tag: "head"} | _]), do: :in_head
  defp determine_mode_from_stack([%{tag: "html"} | _]), do: :before_head
  defp determine_mode_from_stack([%{tag: "select"} | _]), do: :in_select
  defp determine_mode_from_stack([_ | rest]), do: determine_mode_from_stack(rest)

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

  # --------------------------------------------------------------------------
  # Scope helpers
  # --------------------------------------------------------------------------

  defp in_table_context?(stack), do: do_in_table_context?(stack)

  defp do_in_table_context?([%{tag: tag} | _]) when tag in ~w(table tbody thead tfoot tr),
    do: true

  defp do_in_table_context?([%{tag: tag} | _]) when is_table_scope_boundary(tag), do: false
  defp do_in_table_context?([_ | rest]), do: do_in_table_context?(rest)
  defp do_in_table_context?([]), do: false

  defp in_select?(stack), do: do_in_select?(stack)

  defp do_in_select?([%{tag: "select"} | _]), do: true
  defp do_in_select?([%{tag: tag} | _]) when is_select_scope_boundary(tag), do: false
  defp do_in_select?([_ | rest]), do: do_in_select?(rest)
  defp do_in_select?([]), do: false

  defp close_option_optgroup_in_select(%{stack: [%{tag: tag} = elem | rest]} = state)
       when tag in ["option", "optgroup"] do
    %{state | stack: add_child(rest, elem)}
    |> close_option_optgroup_in_select()
  end

  defp close_option_optgroup_in_select(state), do: state

  defp close_select(%{stack: stack} = state) do
    %{state | stack: close_tag("select", stack)} |> pop_mode()
  end

  # --------------------------------------------------------------------------
  # Table context
  # --------------------------------------------------------------------------

  @table_body_boundaries @table_sections ++ ["table", "template", "html"]
  @table_row_boundaries @table_row_context ++ ["table", "template", "html"]
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_body_context(%{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_body_boundaries)}
  end

  defp clear_to_table_row_context(%{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_row_boundaries)}
  end

  defp clear_to_table_context(%{stack: stack} = state) do
    %{state | stack: clear_to_context(stack, @table_boundaries)}
  end

  defp clear_to_context([%{tag: tag} | _] = stack, boundaries) do
    if tag in boundaries, do: stack, else: clear_to_context_close(stack, boundaries)
  end

  defp clear_to_context([], _boundaries), do: []

  defp clear_to_context_close([elem | rest], boundaries) do
    clear_to_context(add_child(rest, elem), boundaries)
  end

  defp do_clear_to_table_context([%{tag: tag} | _] = stack) when tag in @table_boundaries,
    do: stack

  defp do_clear_to_table_context([_] = stack), do: stack
  defp do_clear_to_table_context([]), do: []

  defp do_clear_to_table_context([elem | rest]) do
    do_clear_to_table_context(add_child(rest, elem))
  end

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

  defp ensure_tbody(%{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "tbody", %{})
  end

  defp ensure_tbody(%{stack: [%{tag: tag} | _]} = state) when tag in @table_sections, do: state
  defp ensure_tbody(%{stack: [%{tag: "tr"} | _]} = state), do: state
  defp ensure_tbody(state), do: state

  defp ensure_tr(%{stack: [%{tag: tag} | _]} = state) when tag in @table_sections do
    push_element(state, "tr", %{})
  end

  defp ensure_tr(%{stack: [%{tag: "tr"} | _]} = state), do: state

  defp ensure_tr(%{stack: [%{tag: "template", children: children} | _]} = state) do
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

  defp ensure_colgroup(%{stack: [%{tag: "colgroup"} | _]} = state), do: state

  defp ensure_colgroup(%{stack: [%{tag: "table"} | _]} = state) do
    push_element(state, "colgroup", %{})
  end

  defp ensure_colgroup(%{stack: [%{tag: tag} = elem | rest]} = state)
       when tag in @colgroup_close_tags do
    ensure_colgroup(%{state | stack: add_child(rest, elem)})
  end

  defp ensure_colgroup(state), do: state

  # --------------------------------------------------------------------------
  # Foster parenting
  # --------------------------------------------------------------------------

  defp foster_text_to_stack(%{stack: stack} = state, text) do
    %{state | stack: foster_text(stack, text)}
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

  defp process_foster_start_tag(tag, attrs, self_closing, %{stack: stack, af: af} = state) do
    cond do
      self_closing or tag in @void_elements ->
        %{state | stack: foster_element(stack, {tag, attrs, []})}

      tag in @formatting_elements ->
        {new_stack, new_ref} = foster_push_element(stack, tag, attrs)
        new_af = apply_noahs_ark([{new_ref, tag, attrs} | af], tag, attrs)
        %{state | stack: new_stack, af: new_af}

      true ->
        {new_stack, _new_ref} = foster_push_element(stack, tag, attrs)
        %{state | stack: new_stack}
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
    foster_content(stack, element, [], &add_child/2)
  end

  defp rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(%{stack: stack, af: af} = state, tag) when tag in @closes_p do
    {new_stack, new_af} = close_p_if_open_with_af(stack, af)
    %{state | stack: new_stack, af: new_af}
  end

  defp maybe_close_p(state, _tag), do: state

  defp close_p_if_open_with_af(stack, af) do
    case find_p_in_stack(stack, []) do
      nil ->
        {stack, af}

      {above_p, p_elem, below_p} ->
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

  defp close_p_in_scope(stack) do
    case find_p_in_stack(stack, []) do
      nil ->
        :not_found

      {above_p, p_elem, below_p} ->
        closed_p = close_with_elements_above(p_elem, above_p)
        {:found, add_child(below_p, closed_p)}
    end
  end

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

  defp find_p_in_stack([%{tag: tag} | _rest], _acc) when is_button_scope_boundary(tag), do: nil
  defp find_p_in_stack([%{tag: {ns, _}} | _rest], _acc) when ns in [:svg, :math], do: nil

  defp find_p_in_stack([elem | rest], acc) do
    find_p_in_stack(rest, [elem | acc])
  end

  @implicit_close_boundaries ~w(table template body html)
  @li_scope_boundaries ~w(ol ul table template body html)

  defp maybe_close_same(%{stack: stack} = state, tag) do
    case get_implicit_close_config(tag) do
      nil ->
        state

      {closes, boundaries, close_all?} ->
        result =
          if close_all? do
            pop_to_implicit_close_all(stack, closes, boundaries)
          else
            pop_to_implicit_close(stack, closes, [], boundaries)
          end

        case result do
          {:ok, new_stack} -> %{state | stack: new_stack}
          :not_found -> state
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

  defp pop_to_implicit_close([], _closes, _acc, _boundaries), do: :not_found

  defp pop_to_implicit_close([%{tag: tag} = elem | rest], closes, acc, boundaries) do
    cond do
      tag in boundaries ->
        :not_found

      tag in closes ->
        closed_elem = Enum.reduce(acc, elem, &add_child_to_elem/2)
        {:ok, add_child(rest, closed_elem)}

      true ->
        pop_to_implicit_close(rest, closes, [elem | acc], boundaries)
    end
  end

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
  # Close tag
  # --------------------------------------------------------------------------

  defp close_tag(tag, stack) do
    case pop_until(tag, stack, []) do
      {:found, element, rest} -> add_child(rest, element)
      :not_found -> stack
    end
  end

  defp pop_until(_target, [], _acc), do: :not_found

  defp pop_until(target, [%{tag: target} = elem | rest], acc) do
    finalize_pop(elem, acc, rest)
  end

  defp pop_until(target, [%{tag: {:svg, target}} = elem | rest], acc) do
    finalize_pop(elem, acc, rest)
  end

  defp pop_until(target, [%{tag: {:math, target}} = elem | rest], acc) do
    finalize_pop(elem, acc, rest)
  end

  defp pop_until(_target, [%{tag: "template"} | _], _acc), do: :not_found

  defp pop_until(target, [elem | rest], acc) do
    pop_until(target, rest, [elem | acc])
  end

  defp finalize_pop(elem, acc, rest) do
    nested_above = nest_elements(Enum.reverse(acc))
    children = if nested_above, do: [nested_above | elem.children], else: elem.children
    {:found, %{elem | children: children}, rest}
  end

  defp nest_elements([]), do: nil

  defp nest_elements([first | rest]) do
    Enum.reduce(rest, first, fn elem, inner -> %{elem | children: [inner | elem.children]} end)
  end

  # --------------------------------------------------------------------------
  # Active formatting elements
  # --------------------------------------------------------------------------

  defp reconstruct_active_formatting(%{stack: stack, af: af} = state) do
    get_entries_to_reconstruct(af, stack)
    |> reconstruct_entries(state)
  end

  defp get_entries_to_reconstruct(af, stack) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.reverse()
    |> Enum.filter(fn {ref, _tag, _attrs} -> find_in_stack_by_ref(stack, ref) == nil end)
  end

  defp find_in_stack_by_ref(stack, target_ref) do
    Enum.find_index(stack, fn
      %{ref: ref} -> ref == target_ref
      _ -> false
    end)
  end

  defp reconstruct_entries([], state), do: state

  defp reconstruct_entries([{old_ref, tag, attrs} | rest], %{stack: stack, af: af} = state) do
    new_elem = new_element(tag, attrs)
    new_stack = [new_elem | stack]
    new_af = update_af_entry(af, old_ref, {new_elem.ref, tag, attrs})
    reconstruct_entries(rest, %{state | stack: new_stack, af: new_af})
  end

  defp update_af_entry(af, old_ref, new_entry) do
    Enum.map(af, fn
      {^old_ref, _, _} -> new_entry
      entry -> entry
    end)
  end

  defp add_formatting_entry(%{stack: [%{ref: ref} | _], af: af} = state, tag, attrs) do
    %{state | af: apply_noahs_ark([{ref, tag, attrs} | af], tag, attrs)}
  end

  defp maybe_close_existing_formatting(%{af: af} = state, tag) do
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

  defp push_af_marker(%{af: af} = state), do: %{state | af: [:marker | af]}

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

  # --------------------------------------------------------------------------
  # Adoption agency algorithm
  # --------------------------------------------------------------------------

  defp run_adoption_agency(state, subject) do
    run_adoption_agency_outer_loop(state, subject, 0)
  end

  defp run_adoption_agency_outer_loop(state, _subject, iteration) when iteration >= 8, do: state

  defp run_adoption_agency_outer_loop(%{stack: stack, af: af} = state, subject, iteration) do
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

  defp element_in_scope?(stack, target_idx), do: do_element_in_scope?(stack, target_idx)

  defp do_element_in_scope?(_stack, 0), do: true
  defp do_element_in_scope?([%{tag: tag} | _], _idx) when is_scope_boundary(tag), do: false
  defp do_element_in_scope?([_ | rest], idx), do: do_element_in_scope?(rest, idx - 1)

  defp handle_no_formatting_entry(%{stack: stack} = state, subject, 0) do
    %{state | stack: close_tag(subject, stack)}
  end

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

  defp run_adoption_agency_with_furthest_block(
         %{stack: stack, af: af} = state,
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

    closed_fe = %{
      ref: fe_ref,
      tag: fe_tag,
      attrs: fe_attrs,
      children: close_elements_into(formatting_between, fe_children)
    }

    below_fe = add_child(below_fe, closed_fe)

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
    af = List.delete_at(af, af_idx)

    {final_stack, af}
  end

  defp close_elements_into([], children), do: children

  defp close_elements_into(elements, fe_original_children) do
    [nest_elements(elements) | fe_original_children]
  end
end
