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
      push_af_marker: 1,
      correct_tag: 1,
      current_tag: 1,
      current_element: 1,
      pop_element: 1,
      pop_until_one_of: 2,
      foster_parent: 2
    ]

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
          {:ok, foster_parent(state, {:text, text})}
        end

      true ->
        state =
          state
          |> in_body()
          |> reconstruct_active_formatting()
          |> add_text_to_stack(text)
          |> maybe_set_frameset_not_ok(text)

        {:ok, state}
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
    {:ok, run_adoption_agency(state, tag)}
  end

  def process({:end_tag, tag}, %{af: af} = state) when tag in @table_cells do
    new_state = close_tag_ref(state, tag)
    new_af = clear_af_to_marker(af)
    {:ok, %{new_state | af: new_af}}
  end

  def process({:end_tag, "table"}, %{af: af} = state) do
    closed_refs = get_refs_to_close_for_table(state)
    new_af = reject_refs_from_af(af, closed_refs)
    state = clear_to_table_context(state)
    {:ok, close_tag_ref(%{state | af: new_af}, "table") |> pop_mode()}
  end

  def process({:end_tag, "select"}, state) do
    {:ok, close_tag_ref(state, "select") |> pop_mode()}
  end

  def process({:end_tag, "template"}, %{af: af} = state) do
    new_state = close_tag_ref(state, "template")
    new_af = clear_af_to_marker(af)
    {:ok, %{new_state | af: new_af} |> reset_insertion_mode()}
  end

  def process({:end_tag, "frameset"}, state) do
    {:ok, close_tag_ref(state, "frameset") |> Map.put(:mode, :after_frameset)}
  end

  # Heading end tags: close ANY open heading element per spec
  @headings ~w(h1 h2 h3 h4 h5 h6)
  def process({:end_tag, tag}, state) when tag in @headings do
    {:ok, close_any_heading(state)}
  end

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
        is_nil(ns) or html_integration_point?(state) ->
          process_html_start_tag(tag, attrs, self_closing, state)

        html_breakout_tag?(tag) ->
          state = close_foreign_content(state)
          process_html_start_tag(tag, attrs, self_closing, state)

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

  # All HTML start tags are processed through do_process_html_start_tag
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
  defp do_process_html_start_tag("template", attrs, _, %{mode: mode} = state)
       when mode in [:in_body, :in_table, :in_select] do
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
       when tag in @head_elements and mode in [:in_template, :in_body, :in_table, :in_select] do
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
    |> maybe_close_current_heading(tag)
    |> push_element(tag, attrs)
    |> reconstruct_active_formatting()
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

  defp foreign_namespace(%{stack: stack, elements: elements}) do
    Enum.find_value(stack, fn ref ->
      if is_map_key(elements, ref) do
        case elements[ref].tag do
          {ns, _} when ns in [:svg, :math] -> ns
          _ -> nil
        end
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

  # Check if stack contains a tag (uses elements map lookup)
  defp has_tag?(%{stack: stack, elements: elements}, tag) do
    Enum.any?(stack, fn ref -> elements[ref].tag == tag end)
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
    if elements[ref].tag == "html" do
      ref
    else
      find_html_ref(rest, elements)
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

  defp close_body_for_frameset(%{stack: stack, elements: elements} = state) do
    {new_stack, new_elements, parent_ref} = do_close_body_for_frameset(stack, elements)
    %{state | stack: new_stack, elements: new_elements, current_parent_ref: parent_ref}
  end

  defp do_close_body_for_frameset([], elements), do: {[], elements, nil}

  defp do_close_body_for_frameset([ref | rest] = stack, elements) do
    case elements[ref].tag do
      "body" ->
        # Remove body from its parent (html) per spec
        parent_ref = elements[ref].parent_ref

        new_elements =
          if parent_ref do
            Map.update!(elements, parent_ref, fn parent ->
              %{parent | children: List.delete(parent.children, ref)}
            end)
          else
            elements
          end

        {rest, new_elements, parent_ref}

      "html" ->
        # Stop at html
        {stack, elements, ref}

      _ ->
        do_close_body_for_frameset(rest, elements)
    end
  end

  # --------------------------------------------------------------------------
  # Mode transitions
  # --------------------------------------------------------------------------

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

  defp reset_insertion_mode(
         %{stack: stack, elements: elements, template_mode_stack: template_mode_stack} = state
       ) do
    mode = determine_mode_from_stack(stack, elements)
    %{state | mode: mode, template_mode_stack: Enum.drop(template_mode_stack, 1)}
  end

  defp determine_mode_from_stack([], _elements), do: :in_body

  defp determine_mode_from_stack([ref | rest], elements) do
    tag = elements[ref].tag

    cond do
      tag == "template" -> :in_template
      tag in ~w(tbody thead tfoot) -> :in_table
      tag == "tr" -> :in_table
      tag in ~w(td th caption) -> :in_body
      tag == "table" -> :in_table
      tag == "body" -> :in_body
      tag == "frameset" -> :in_frameset
      tag == "head" -> :in_head
      tag == "html" -> :before_head
      tag == "select" -> :in_select
      true -> determine_mode_from_stack(rest, elements)
    end
  end

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

  defp close_option_optgroup_in_select(state) do
    tag = current_tag(state)

    if tag in ["option", "optgroup"] do
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
    tag = elements[ref].tag

    cond do
      tag == "table" -> MapSet.put(acc, ref)
      tag in ["template", "html"] -> acc
      true -> do_get_refs_to_close_for_table(rest, elements, MapSet.put(acc, ref))
    end
  end

  defp ensure_table_context(state) do
    state
    |> ensure_tbody()
    |> ensure_tr()
  end

  defp ensure_tbody(state) do
    tag = current_tag(state)

    cond do
      tag == "table" -> push_element(state, "tbody", %{})
      tag in @table_sections -> state
      tag == "tr" -> state
      true -> state
    end
  end

  defp ensure_tr(state) do
    tag = current_tag(state)

    cond do
      tag in @table_sections ->
        push_element(state, "tr", %{})

      tag == "tr" ->
        state

      tag == "template" ->
        elem = current_element(state)

        if has_table_row_structure?(state, elem.children) do
          push_element(state, "tr", %{})
        else
          state
        end

      true ->
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
    tag = current_tag(state)

    cond do
      tag == "colgroup" ->
        state

      tag == "table" ->
        push_element(state, "colgroup", %{})

      tag in @colgroup_close_tags ->
        state |> pop_element() |> ensure_colgroup()

      true ->
        state
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
    %{tag: tag} = elements[ref]

    cond do
      tag == "p" ->
        {ref, Enum.reverse(above)}

      is_button_scope_boundary(tag) ->
        nil

      is_tuple(tag) and elem(tag, 0) in [:svg, :math] ->
        nil

      true ->
        do_find_p_in_scope_ref(rest, elements, [ref | above])
    end
  end

  defp do_find_p_in_scope_ref([_ref | rest], elements, above) do
    do_find_p_in_scope_ref(rest, elements, above)
  end

  defp pop_to_ref(stack, elements, target_ref) do
    do_pop_to_ref(stack, elements, target_ref)
  end

  defp do_pop_to_ref([], _elements, _target), do: {[], nil}

  defp do_pop_to_ref([ref | rest], elements, target) do
    if ref == target do
      {rest, elements[ref].parent_ref}
    else
      do_pop_to_ref(rest, elements, target)
    end
  end

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

  defp pop_to_implicit_close_ref(stack, elements, closes, boundaries) do
    do_pop_to_implicit_close_ref(stack, elements, closes, boundaries)
  end

  defp do_pop_to_implicit_close_ref([], _elements, _closes, _boundaries), do: :not_found

  defp do_pop_to_implicit_close_ref([ref | rest], elements, closes, boundaries) do
    tag = elements[ref].tag

    cond do
      tag in boundaries ->
        :not_found

      tag in closes ->
        {:ok, rest, elements[ref].parent_ref}

      true ->
        do_pop_to_implicit_close_ref(rest, elements, closes, boundaries)
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
        # (new elements should be children of the top element)
        parent_ref =
          case stack do
            [ref | _] -> ref
            [] -> nil
          end

        {:ok, stack, parent_ref}

      :not_found ->
        :not_found
    end
  end

  # --------------------------------------------------------------------------
  # Close tag
  # --------------------------------------------------------------------------

  # Close tag using ref-only stack architecture
  defp close_tag_ref(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_tag_ref(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

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
      tag in @headings ->
        {:found, rest, parent_ref}

      tag == "template" ->
        :not_found

      true ->
        pop_until_any_heading(rest, elements)
    end
  end

  defp pop_until_tag_ref(stack, elements, target) do
    do_pop_until_tag_ref(stack, elements, target)
  end

  defp do_pop_until_tag_ref([], _elements, _target), do: :not_found

  defp do_pop_until_tag_ref([ref | rest], elements, target) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag == target ->
        {:found, rest, parent_ref}

      tag == {:svg, target} ->
        {:found, rest, parent_ref}

      tag == {:math, target} ->
        {:found, rest, parent_ref}

      tag == "template" ->
        :not_found

      true ->
        do_pop_until_tag_ref(rest, elements, target)
    end
  end

  defp do_pop_until_tag_ref([_ref | rest], elements, target) do
    do_pop_until_tag_ref(rest, elements, target)
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

  defp run_adoption_agency_outer_loop(%{af: af} = state, subject, iteration) do
    case locate_formatting_element(state, subject) do
      :not_in_af ->
        handle_no_formatting_entry(state, subject, iteration)

      {:not_in_stack, af_idx} ->
        %{state | af: List.delete_at(af, af_idx)}

      :not_in_scope ->
        state

      {:no_furthest_block, af_idx, stack_idx} ->
        pop_to_formatting_element_ref(state, af_idx, stack_idx)

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

  defp locate_formatting_element(%{af: af, stack: stack} = state, subject) do
    with {:ok, af_idx, {fe_ref, fe_tag, fe_attrs}} <- find_formatting_entry_result(af, subject),
         {:ok, stack_idx} <- find_in_stack_result(stack, fe_ref, af_idx),
         :ok <- check_in_scope(state, stack_idx) do
      case find_furthest_block(state, stack_idx) do
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

  defp element_in_scope?(%{stack: stack, elements: elements}, target_idx) do
    do_element_in_scope?(stack, elements, target_idx)
  end

  defp do_element_in_scope?(_stack, _elements, 0), do: true

  defp do_element_in_scope?([ref | rest], elements, idx) when is_map_key(elements, ref) do
    %{tag: tag} = elements[ref]

    if is_scope_boundary(tag) do
      false
    else
      do_element_in_scope?(rest, elements, idx - 1)
    end
  end

  defp do_element_in_scope?([_ref | rest], elements, idx) do
    do_element_in_scope?(rest, elements, idx)
  end

  defp do_element_in_scope?([], _elements, _idx), do: false

  defp handle_no_formatting_entry(state, subject, 0) do
    close_tag_ref(state, subject)
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

  # Find AF entry by ref (for inner loop)
  defp find_af_entry_by_ref(af, target_ref) do
    af
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{^target_ref, tag, attrs}, idx} -> {idx, {target_ref, tag, attrs}}
      _ -> nil
    end)
  end

  # Reparent a node to a new parent
  # Note: children are stored in reverse order (prepended), so we prepend here too
  defp reparent_node(elements, child_ref, new_parent_ref) do
    child = elements[child_ref]
    old_parent_ref = child.parent_ref

    elements
    |> maybe_remove_from_old_parent(child_ref, old_parent_ref)
    |> Map.update!(child_ref, &%{&1 | parent_ref: new_parent_ref})
    |> Map.update!(new_parent_ref, fn p -> %{p | children: [child_ref | p.children]} end)
  end

  # Reparent node with foster parenting awareness - inserts before any table element
  defp reparent_node_foster_aware(elements, child_ref, new_parent_ref) do
    child = elements[child_ref]
    old_parent_ref = child.parent_ref

    elements = maybe_remove_from_old_parent(elements, child_ref, old_parent_ref)
    elements = Map.update!(elements, child_ref, &%{&1 | parent_ref: new_parent_ref})

    # Find table in parent's children to insert before it
    parent = elements[new_parent_ref]

    table_ref =
      Enum.find(parent.children, fn
        ref when is_reference(ref) -> elements[ref] && elements[ref].tag == "table"
        _ -> false
      end)

    new_children =
      if table_ref do
        # Insert after table in stored list (= before table in output)
        insert_after_in_list(parent.children, child_ref, table_ref)
      else
        # No table, just prepend
        [child_ref | parent.children]
      end

    Map.update!(elements, new_parent_ref, fn p -> %{p | children: new_children} end)
  end

  # Insert new_item after target_item in list (because children are reversed)
  defp insert_after_in_list(list, new_item, target_item) do
    do_insert_after(list, new_item, target_item, [])
  end

  defp do_insert_after([], new_item, _target, acc) do
    Enum.reverse([new_item | acc])
  end

  defp do_insert_after([target | rest], new_item, target, acc) do
    Enum.reverse(acc) ++ [target, new_item | rest]
  end

  defp do_insert_after([item | rest], new_item, target, acc) do
    do_insert_after(rest, new_item, target, [item | acc])
  end

  defp maybe_remove_from_old_parent(elements, _child_ref, nil), do: elements

  defp maybe_remove_from_old_parent(elements, child_ref, old_parent_ref) do
    if Map.has_key?(elements, old_parent_ref) do
      Map.update!(elements, old_parent_ref, fn p ->
        %{p | children: List.delete(p.children, child_ref)}
      end)
    else
      elements
    end
  end

  # Update parent_ref for multiple children
  defp update_children_parent_refs(elements, children, new_parent_ref) do
    Enum.reduce(children, elements, fn
      child_ref, elems when is_reference(child_ref) ->
        Map.update!(elems, child_ref, &%{&1 | parent_ref: new_parent_ref})

      _, elems ->
        elems
    end)
  end

  # Inner loop for adoption agency algorithm
  # Processes each node between furthest block and formatting element
  defp run_adoption_inner_loop(
         state,
         _fe_ref,
         _node_idx,
         last_node_ref,
         _fb_ref,
         _common_ancestor_ref,
         bookmark,
         counter
       )
       when counter >= 3 do
    {state, last_node_ref, bookmark}
  end

  defp run_adoption_inner_loop(
         %{stack: stack, af: af, elements: elements} = state,
         fe_ref,
         node_idx,
         last_node_ref,
         fb_ref,
         common_ancestor_ref,
         bookmark,
         counter
       ) do
    # Advance node toward FE (node = element before node in stack)
    next_node_idx = node_idx + 1
    node_ref = Enum.at(stack, next_node_idx)

    cond do
      # Reached the formatting element or past it - done
      node_ref == fe_ref or node_ref == nil ->
        {state, last_node_ref, bookmark}

      # Node not in AF - remove from stack, continue (don't increment counter)
      find_af_entry_by_ref(af, node_ref) == nil ->
        new_stack = List.delete_at(stack, next_node_idx)

        run_adoption_inner_loop(
          %{state | stack: new_stack},
          fe_ref,
          node_idx,
          last_node_ref,
          fb_ref,
          common_ancestor_ref,
          bookmark,
          counter
        )

      # Node in AF - create new element, replace in AF, reparent
      true ->
        {node_af_idx, {_, node_tag, node_attrs}} = find_af_entry_by_ref(af, node_ref)

        # Create new element for node's token
        new_node = new_element(node_tag, node_attrs, common_ancestor_ref)
        new_elements = Map.put(elements, new_node.ref, new_node)

        # Replace node in AF with new element
        new_af = List.replace_at(af, node_af_idx, {new_node.ref, node_tag, node_attrs})

        # Replace node in stack with new element
        new_stack = List.replace_at(stack, next_node_idx, new_node.ref)

        # Update bookmark: if last_node is furthest block, move bookmark after new element
        new_bookmark = if last_node_ref == fb_ref, do: node_af_idx + 1, else: bookmark

        # Reparent last_node to new_node
        new_elements = reparent_node(new_elements, last_node_ref, new_node.ref)

        run_adoption_inner_loop(
          %{state | stack: new_stack, af: new_af, elements: new_elements},
          fe_ref,
          next_node_idx,
          new_node.ref,
          fb_ref,
          common_ancestor_ref,
          new_bookmark,
          counter + 1
        )
    end
  end

  # Full adoption agency with furthest block - HTML5 spec compliant
  defp run_adoption_agency_with_furthest_block(
         %{stack: stack, elements: elements} = state,
         {af_idx, fe_ref, fe_tag, fe_attrs},
         fe_stack_idx,
         fb_idx
       ) do
    # Common ancestor = element immediately before FE in stack
    # BUT: if FE was foster parented, use its actual parent_ref instead
    common_ancestor_ref =
      if is_map_key(elements, fe_ref) and
           is_map_key(elements[fe_ref], :foster_parent_ref) and
           elements[fe_ref].foster_parent_ref != nil do
        elements[fe_ref].foster_parent_ref
      else
        Enum.at(stack, fe_stack_idx + 1)
      end

    fb_ref = Enum.at(stack, fb_idx)

    # Run inner loop (processes nodes between FB and FE)
    {state, last_node_ref, bookmark} =
      run_adoption_inner_loop(
        state,
        fe_ref,
        fb_idx,
        fb_ref,
        fb_ref,
        common_ancestor_ref,
        af_idx,
        0
      )

    # Insert last_node at common ancestor
    # For foster parented elements, insert before the table
    new_elements = reparent_node_foster_aware(state.elements, last_node_ref, common_ancestor_ref)

    # Create new element for formatting element
    new_fe = new_element(fe_tag, fe_attrs, fb_ref)
    new_elements = Map.put(new_elements, new_fe.ref, new_fe)

    # Move FB's children to new FE
    fb_elem = new_elements[fb_ref]

    new_elements =
      new_elements
      |> Map.update!(new_fe.ref, &%{&1 | children: fb_elem.children})
      |> Map.put(fb_ref, %{fb_elem | children: [new_fe.ref]})
      |> update_children_parent_refs(fb_elem.children, new_fe.ref)

    # Update AF: remove old FE, insert new FE at bookmark
    adjusted_bookmark = if af_idx < bookmark, do: bookmark - 1, else: bookmark

    new_af =
      state.af
      |> List.delete_at(af_idx)
      |> List.insert_at(adjusted_bookmark, {new_fe.ref, fe_tag, fe_attrs})

    # Update stack: remove FE, insert new FE below FB
    fe_current_idx = Enum.find_index(state.stack, &(&1 == fe_ref))
    fb_current_idx = Enum.find_index(state.stack, &(&1 == fb_ref))

    new_stack =
      if fe_current_idx do
        state.stack
        |> List.delete_at(fe_current_idx)
        |> List.insert_at(fb_current_idx, new_fe.ref)
      else
        List.insert_at(state.stack, fb_current_idx + 1, new_fe.ref)
      end

    # Update current_parent_ref
    current_parent_ref =
      case new_stack do
        [top_ref | _] when is_map_key(new_elements, top_ref) -> new_elements[top_ref].parent_ref
        _ -> state.current_parent_ref
      end

    %{
      state
      | stack: new_stack,
        af: new_af,
        elements: new_elements,
        current_parent_ref: current_parent_ref
    }
  end

  defp find_furthest_block(%{stack: stack, elements: elements}, fe_idx) do
    stack
    |> Enum.take(fe_idx)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(&find_special_element(&1, elements))
  end

  defp find_special_element({ref, idx}, elements) when is_map_key(elements, ref) do
    case elements[ref].tag do
      tag when is_binary(tag) and tag in @special_elements -> idx
      _ -> nil
    end
  end

  defp find_special_element(_, _), do: nil

  defp pop_to_formatting_element_ref(
         %{stack: stack, af: af, elements: elements} = state,
         af_idx,
         stack_idx
       ) do
    # Pop stack to the formatting element
    {_above_fe, [fe_ref | rest]} = Enum.split(stack, stack_idx)

    # Update current parent ref
    parent_ref =
      if is_map_key(elements, fe_ref) do
        elements[fe_ref].parent_ref
      else
        state.current_parent_ref
      end

    # Remove formatting element from af
    new_af = List.delete_at(af, af_idx)

    %{state | stack: rest, af: new_af, current_parent_ref: parent_ref}
  end
end
