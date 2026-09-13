defmodule PureHTML.TreeBuilder.Modes.InBody do
  @moduledoc """
  HTML5 "in body" insertion mode.

  This is the main parsing mode for document content inside <body>.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.AdoptionAgency

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)
  @head_elements ~w(base basefont bgsound link meta noframes script style template title)
  @table_context ~w(table tbody thead tfoot tr)
  @table_sections ~w(tbody thead tfoot)
  @table_cells ~w(td th)
  @table_row_context ~w(tr tbody thead tfoot)
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @af_marker_elements ~w(applet marquee object)

  # Use shared special_elements from Helpers
  @special_elements PureHTML.TreeBuilder.Helpers.special_elements()

  @closes_p ~w(address article aside blockquote center details dialog dir div dl dd dt
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr li listing main menu nav ol p plaintext pre rb rp rt rtc search section summary table ul xmp)

  # Block-level end tags per HTML5 spec (generate implied end tags, then pop until match)
  # These do NOT use the "special element stops traversal" rule
  @block_end_tags ~w(address article aside blockquote button center details dialog dir div
                     dl fieldset figcaption figure footer form header hgroup listing main
                     menu nav ol pre search section select summary ul)

  # Note: option and optgroup are handled specially in maybe_close_same/2
  # per HTML5 spec (they only close if current node matches, not stack search)
  @implicit_closes %{
    "li" => [],
    "dt" => ["dd"],
    "dd" => ["dt"],
    "button" => [],
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

  @table_structure_elements @table_sections ++ ["caption", "colgroup"]
  @ruby_elements ~w(rb rt rtc rp)
  @newline_skipping_elements ~w(pre textarea listing)

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
    |> ok()
  end

  def process({:character, text}, state) do
    state
    |> current_tag()
    |> handle_in_body_characters(text, state)
  end

  # Comment tokens
  def process({:comment, _text}, %{stack: []} = state), do: ok(state)

  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  # DOCTYPE - parse error, ignore
  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # --------------------------------------------------------------------------
  # End tags
  # --------------------------------------------------------------------------

  # End tags that break out of foreign content
  def process({:end_tag, tag} = token, state) when tag in ~w(p br) do
    state
    |> foreign_namespace()
    |> break_out_for_end_tag(token, state)
  end

  # Per spec: "If the stack of open elements does not have a body element in scope,
  # this is a parse error; ignore the token."
  # Otherwise, check for unclosed elements and parse error if any are unexpected.
  def process({:end_tag, "body"}, state) do
    if in_scope?(state, "body", :default) do
      state
      |> maybe_parse_error_for_unclosed_body()
      |> set_mode(:after_body)
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Per spec: "If the stack of open elements does not have a body element in scope,
  # this is a parse error; ignore the token."
  # Otherwise act as if </body> was seen, then reprocess.
  def process({:end_tag, "html"}, state) do
    case process({:end_tag, "body"}, state) do
      {:ok, %{mode: :after_body} = new_state} -> reprocess(new_state)
      other -> other
    end
  end

  def process({:end_tag, tag}, state) when tag in @formatting_elements do
    state
    |> AdoptionAgency.run(tag, &close_tag_ref/2)
    |> ok()
  end

  def process({:end_tag, tag}, state) when tag in @table_cells do
    state
    |> close_tag_ref_forced(tag)
    |> clear_af_to_marker()
    |> ok()
  end

  # Per spec: applet/marquee/object end tags:
  # "If not in scope, parse error; ignore."
  # "Generate implied end tags." "If current node is not the element, parse error."
  def process({:end_tag, tag}, state) when tag in @af_marker_elements do
    if in_scope?(state, tag, :default) do
      # Per spec: if current node is not the element, parse error
      state
      |> generate_implied_end_tags()
      |> parse_error_unless_current(tag)
      |> close_tag_ref_forced(tag)
      |> clear_af_to_marker()
      |> ok()
    else
      # Per spec: parse error; ignore the token
      state
      |> parse_error()
      |> ok()
    end
  end

  def process({:end_tag, "table"}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> drop_table_refs_from_af()
      |> clear_to_table_context()
      |> close_tag_ref_forced("table")
      |> pop_mode()
      |> ok()
    else
      # Per spec: "parse error; ignore the token"
      state
      |> parse_error()
      |> ok()
    end
  end

  # Per spec: "If there is no template element on the stack of open elements,
  # then this is a parse error; ignore the token."
  def process({:end_tag, "template"}, state) do
    if has_template_on_stack?(state) do
      state
      |> generate_implied_end_tags_thoroughly()
      |> parse_error_unless_current("template")
      |> close_html_template()
      |> clear_af_to_marker()
      |> reset_insertion_mode()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Heading end tags: per spec, check if any h1-h6 is in scope.
  # "If the stack of open elements does not have an element in scope that is an HTML
  # element whose tag name is one of h1-h6, this is a parse error; ignore the token."
  # "Generate implied end tags."
  # "If the current node is not an HTML element with the same tag name as that of the token,
  # this is a parse error."
  @headings ~w(h1 h2 h3 h4 h5 h6)
  def process({:end_tag, tag}, state) when tag in @headings do
    if has_heading_in_scope?(state) do
      # If current node is not the same heading, parse error
      state
      |> generate_implied_end_tags()
      |> parse_error_unless_current(tag)
      |> close_any_heading()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Per spec: "If the stack of open elements does not have an li element in list item scope,
  # this is a parse error; ignore the token."
  # "Generate implied end tags, except for li."
  # "If the current node is not an li element, this is a parse error."
  def process({:end_tag, "li"}, state) do
    if in_scope?(state, "li", :list_item) do
      state
      |> generate_implied_end_tags_except("li")
      |> parse_error_unless_current("li")
      |> close_li_in_list_scope()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Per spec: "If the stack of open elements does not have an element in scope that is
  # an HTML element with the same tag name as the token, parse error; ignore."
  # "Generate implied end tags, except for dd/dt."
  # "If current node is not the same element, parse error."
  def process({:end_tag, tag}, state) when tag in ~w(dd dt) do
    if in_scope?(state, tag, :default) do
      state
      |> generate_implied_end_tags_except(tag)
      |> parse_error_unless_current(tag)
      |> close_dd_dt_in_scope(tag)
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # </form> has special handling when no template is on the stack of open elements
  # Per HTML5 spec: only REMOVE form from stack, don't pop until it
  def process({:end_tag, "form"}, %{form_element: form_ref} = state)
      when not is_nil(form_ref) do
    if has_template_on_stack?(state) do
      # Template case: use standard "in scope" handling
      state
      |> close_form_with_template()
      |> ok()
    else
      state
      |> close_form_special(form_ref)
      |> ok()
    end
  end

  # Block-level end tags: generate implied end tags, then pop until match
  # Per HTML5 spec, these do NOT use the "special element stops traversal" rule
  def process({:end_tag, tag}, state) when tag in @block_end_tags do
    state
    |> close_block_end_tag(tag)
    |> ok()
  end

  # </svg> and </math>: close foreign root element (ignores internal barriers)
  def process({:end_tag, "svg"}, state) do
    state
    |> close_foreign_root(:svg)
    |> ok()
  end

  def process({:end_tag, "math"}, state) do
    state
    |> close_foreign_root(:math)
    |> ok()
  end

  # Any other end tag per spec:
  # Walk the stack. If node matches tag:
  #   - "If node is not the current node, then this is a parse error."
  #   - Pop until and including node.
  # If node is special: parse error; ignore.
  def process({:end_tag, tag}, state) do
    state
    |> close_any_other_end_tag(tag)
    |> ok()
  end

  # EOF: if a template is still open, use "in template" (which parse-errors and
  # reprocesses EOF after popping the template).
  def process(:eof, %{template_mode_stack: [_ | _]} = state) do
    if has_template_on_stack?(state) do
      state
      |> set_mode(:in_template)
      |> reprocess()
    else
      eof_in_body(state)
    end
  end

  def process(:eof, state), do: eof_in_body(state)

  # --------------------------------------------------------------------------
  # Start tags
  # --------------------------------------------------------------------------

  def process({:start_tag, "html", attrs, _}, %{stack: []} = state) do
    ok(%{state | stack: [new_element("html", attrs)], mode: :before_head})
  end

  # Per spec: "Parse error. If there is a template element on the stack of open elements,
  # then ignore the token."
  def process({:start_tag, "html", _attrs, _}, %{template_mode_stack: [_ | _]} = state) do
    state
    |> parse_error()
    |> ok()
  end

  # Per spec: "Parse error." Then merge attributes.
  def process({:start_tag, "html", attrs, _}, state) do
    state
    |> parse_error()
    |> merge_html_attrs(attrs)
    |> ok()
  end

  def process({:start_tag, "head", _attrs, _}, state) do
    # Parse error, ignore the token (head is only valid in before_head mode)
    state
    |> parse_error()
    |> ok()
  end

  def process({:start_tag, "body", attrs, _}, state) do
    state
    |> process_html_body_start_tag(attrs)
    |> ok()
  end

  def process({:start_tag, "svg", attrs, self_closing}, state) do
    state
    |> in_body()
    |> do_push_foreign_element(:svg, "svg", attrs, self_closing)
    |> ok()
  end

  def process({:start_tag, "math", attrs, self_closing}, state) do
    state
    |> in_body()
    |> do_push_foreign_element(:math, "math", attrs, self_closing)
    |> ok()
  end

  def process({:start_tag, tag, attrs, self_closing}, state) do
    tag
    |> correct_tag()
    |> process_corrected_start_tag(tag, attrs, self_closing, state)
  end

  defp process_corrected_start_tag(tag, tag, attrs, self_closing, state) do
    state
    |> dispatch_start_tag(tag, attrs, self_closing)
    |> ok()
  end

  # Per spec: <image> — "Parse error. Change the token's tag name to 'img'."
  defp process_corrected_start_tag(corrected_tag, _original_tag, attrs, self_closing, state) do
    state
    |> parse_error()
    |> dispatch_start_tag(corrected_tag, attrs, self_closing)
    |> ok()
  end

  defp break_out_for_end_tag(nil, token, state), do: do_process_end_tag(token, state)

  # Break out of foreign content first
  defp break_out_for_end_tag(_ns, token, state) do
    state
    |> close_foreign_content()
    |> process_end_tag(token)
  end

  defp process_end_tag(state, token), do: do_process_end_tag(token, state)

  # Per spec: "Parse error." then "If there is a template element on the stack, ignore"
  defp process_html_body_start_tag(%{template_mode_stack: [_ | _]} = state, _attrs) do
    parse_error(state)
  end

  # Per spec: "Parse error." then "If the stack of open elements has only one element
  # on it, ignore the token. (fragment case)"
  defp process_html_body_start_tag(%{stack: [_]} = state, _attrs) do
    parse_error(state)
  end

  # Per spec: "Parse error." Then merge attributes and set frameset-not-ok.
  defp process_html_body_start_tag(state, attrs) do
    state
    |> parse_error()
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> insert_or_merge_body(attrs)
  end

  defp insert_or_merge_body(%{mode: :after_head} = state, attrs) do
    state
    |> push_element("body", attrs)
    |> set_mode(:in_body)
    |> set_frameset_not_ok()
  end

  defp insert_or_merge_body(state, attrs) do
    state
    |> merge_body_attrs(attrs)
    |> set_frameset_not_ok()
  end

  # Dispatch an HTML start tag with the in-body rules. The one namespace-aware
  # case: a table start tag at an HTML integration point with a table ancestor
  # is foster-parented past the foreign content.
  defp dispatch_start_tag(state, "table", attrs, self_closing) do
    if html_integration_point?(state) and has_table_ancestor?(state.stack, state.elements) do
      handle_table_at_integration_point(state, "table", attrs)
    else
      do_process_html_start_tag("table", attrs, self_closing, state)
    end
  end

  defp dispatch_start_tag(state, tag, attrs, self_closing) do
    do_process_html_start_tag(tag, attrs, self_closing, state)
  end

  defp handle_table_at_integration_point(state, tag, attrs) do
    state
    |> close_foreign_content()
    |> foster_insert({:push, tag, attrs})
    |> push_mode(:in_table)
    |> set_frameset_not_ok()
  end

  # Helper for end tags that break out of foreign content
  # Per spec: "If the stack of open elements does not have a p element in button scope,
  # then this is a parse error; insert an HTML element for a 'p' start tag token with no attributes."
  # Also: "Close a p element" — "If the current node is not a p element, then this is a parse error."
  defp do_process_end_tag({:end_tag, "p"}, state) do
    state
    |> find_p_in_scope_ref()
    |> close_p_for_end_tag(state)
  end

  # Per spec: "</br> — Parse error. Drop the attributes from the token,
  # and act as described in the 'start tag' entry for br."
  defp do_process_end_tag({:end_tag, "br"}, state) do
    state
    |> parse_error()
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_child_to_stack({"br", [], []})
    |> ok()
  end

  # Parse error: p not in button scope
  defp close_p_for_end_tag(nil, state) do
    state
    |> parse_error()
    |> add_child_to_stack({"p", [], []})
    |> ok()
  end

  defp close_p_for_end_tag({p_ref, _refs_above}, state) do
    state
    |> parse_error_unless_current("p")
    |> pop_to_element_ref(p_ref)
    |> ok()
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
       when mode in [:in_body, :in_table] do
    state
    |> find_ref("body")
    |> insert_template_with_body(attrs, state)
  end

  # <noscript> with scripting enabled: process using "in head" rules (RAWTEXT)
  defp do_process_html_start_tag("noscript", attrs, self_closing, %{scripting: true} = state) do
    insert_as_head_element("noscript", attrs, self_closing, state)
  end

  # <noscript> with scripting disabled: reconstruct AF, push element (parsed as HTML)
  defp do_process_html_start_tag("noscript", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element("noscript", attrs)
  end

  # Template in other contexts
  defp do_process_html_start_tag("template", attrs, _, state) do
    state
    |> find_ref("body")
    |> insert_template_elsewhere(attrs, state)
  end

  # Other head elements
  defp do_process_html_start_tag(tag, attrs, self_closing, state)
       when tag in @head_elements do
    insert_as_head_element(tag, attrs, self_closing, state)
  end

  # Per HTML5 spec: "Parse error." Then ignore if only one element on stack
  # (fragment case), if the second element is not body, or if frameset-ok is "not ok".
  defp do_process_html_start_tag("frameset", attrs, _, %{frameset_ok: true} = state) do
    state
    |> parse_error()
    |> insert_frameset_in_body(attrs)
  end

  defp do_process_html_start_tag("frameset", _, _, state), do: parse_error(state)

  # Frame in frameset. Otherwise: parse error, ignore.
  defp do_process_html_start_tag("frame", attrs, _, state) do
    state
    |> current_tag()
    |> insert_frame(attrs, state)
  end

  # Col in table mode
  defp do_process_html_start_tag("col", attrs, _, %{mode: :in_table} = state) do
    state
    |> find_ref("table")
    |> insert_col_in_table(attrs, state)
  end

  # Per spec: in a select fragment, "Parse error. Ignore the token."
  defp do_process_html_start_tag("input", _attrs, _, %{context_element: {_ns, "select"}} = state) do
    parse_error(state)
  end

  # Per spec: with a select in scope, parse error and pop until a select has been
  # popped; then reconstruct, insert and pop; non-hidden inputs set frameset-ok to "not ok".
  defp do_process_html_start_tag("input", attrs, _, state) do
    state
    |> in_body()
    |> close_select_for_input()
    |> reconstruct_active_formatting()
    |> add_child_to_stack({"input", attrs, []})
    |> maybe_set_frameset_not_ok_for_input(attrs)
  end

  # Per spec: close a p in button scope; with a select in scope, generate implied
  # end tags and parse-error if an option or optgroup is still in scope; insert
  # and pop; set frameset-ok to "not ok". (No formatting reconstruction.)
  defp do_process_html_start_tag("hr", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("hr")
    |> close_for_hr()
    |> add_child_to_stack({"hr", attrs, []})
    |> set_frameset_not_ok()
  end

  # Void elements
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @void_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> maybe_close_p(tag)
    |> add_child_to_stack({tag, attrs, []})
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  # Col in other contexts - parse error, ignore
  defp do_process_html_start_tag("col", _, _, state), do: parse_error(state)

  # Table structure in body mode (ignored per spec: parse error)
  defp do_process_html_start_tag(tag, _, _, %{mode: :in_body} = state)
       when tag in @table_structure_elements do
    parse_error(state)
  end

  # Per spec: td and th in body are a parse error and ignored
  defp do_process_html_start_tag(tag, _, _, %{mode: :in_body} = state) when tag in @table_cells do
    parse_error(state)
  end

  # Table cells
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @table_cells do
    state
    |> current_tag()
    |> mismatch_if_not_in(@table_cells, state)
    |> in_body()
    |> clear_to_table_row_context()
    |> ensure_table_context()
    |> push_element(tag, attrs)
    |> push_af_marker()
  end

  # Table structure in table-related modes: create if table context exists
  @table_related_modes [:in_table, :in_table_body, :in_row, :in_cell, :in_caption]

  defp do_process_html_start_tag(tag, attrs, _, %{mode: mode} = state)
       when tag in @table_structure_elements and mode in @table_related_modes do
    state
    |> find_ref("table")
    |> insert_table_structure(tag, attrs, state)
  end

  # Tr - requires table context
  # In :in_body mode without table, this is a parse error - ignore
  # In table-related modes (:in_table, etc.) or with table on stack, create tr
  defp do_process_html_start_tag("tr", attrs, _, %{mode: mode} = state) do
    state
    |> find_ref("table")
    |> insert_tr(mode, attrs, state)
  end

  # Per spec: an a element in the active formatting list after the last marker
  # is a parse error; run the adoption agency algorithm, then remove that
  # element from the list and the stack if the algorithm didn't already.
  defp do_process_html_start_tag("a", attrs, _, state) do
    state
    |> in_body()
    |> close_existing_anchor()
    |> reconstruct_active_formatting()
    |> push_element("a", attrs)
    |> add_formatting_entry("a", attrs)
  end

  # Per spec: reconstruct; if a nobr element is in scope, parse error, run the
  # adoption agency algorithm, and reconstruct again.
  defp do_process_html_start_tag("nobr", attrs, _, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> close_nobr_in_scope()
    |> push_element("nobr", attrs)
    |> add_formatting_entry("nobr", attrs)
  end

  # Formatting elements
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @formatting_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> add_formatting_entry(tag, attrs)
  end

  # Per spec: xmp closes a p in button scope, reconstructs active formatting,
  # sets frameset-ok to "not ok", then follows the generic raw text algorithm.
  defp do_process_html_start_tag("xmp", attrs, _, state) do
    state
    |> in_body()
    |> maybe_close_p("xmp")
    |> reconstruct_active_formatting()
    |> set_frameset_not_ok()
    |> enter_raw_text("xmp", attrs)
  end

  # Per spec: iframe sets frameset-ok to "not ok", then generic raw text.
  defp do_process_html_start_tag("iframe", attrs, _, state) do
    state
    |> in_body()
    |> set_frameset_not_ok()
    |> enter_raw_text("iframe", attrs)
  end

  # Per spec: noembed follows the generic raw text algorithm.
  defp do_process_html_start_tag("noembed", attrs, _, state) do
    state
    |> in_body()
    |> enter_raw_text("noembed", attrs)
  end

  # Per spec: with a select in scope, generate implied end tags except optgroup and
  # parse-error if an option is still in scope; otherwise pop a current option.
  defp do_process_html_start_tag("option", attrs, _, state) do
    state
    |> in_body()
    |> close_for_option()
    |> reconstruct_active_formatting()
    |> push_element("option", attrs)
  end

  # Per spec: with a select in scope, generate implied end tags and parse-error if
  # an option or optgroup is still in scope; otherwise pop a current option.
  defp do_process_html_start_tag("optgroup", attrs, _, state) do
    state
    |> in_body()
    |> close_for_optgroup()
    |> reconstruct_active_formatting()
    |> push_element("optgroup", attrs)
  end

  # Table
  defp do_process_html_start_tag("table", attrs, _, state) do
    state
    |> in_body()
    |> close_p_unless_quirks("table")
    |> push_element("table", attrs)
    |> push_mode(:in_table)
    |> set_frameset_not_ok()
  end

  # Form - Per spec: "If the form element pointer is not null, and there is no
  # template element on the stack of open elements, then this is a parse error; ignore the token."
  defp do_process_html_start_tag("form", attrs, _, %{form_element: f} = state)
       when not is_nil(f) do
    if has_template_on_stack?(state) do
      # With template, process normally (form_element won't be set again)
      do_process_html_start_tag_form(attrs, state)
    else
      # Parse error, ignore the form tag
      parse_error(state)
    end
  end

  defp do_process_html_start_tag("form", attrs, _, state) do
    do_process_html_start_tag_form(attrs, state)
  end

  # Per spec: in a select fragment, "Parse error. Ignore the token."
  defp do_process_html_start_tag("select", _attrs, _, %{context_element: {_ns, "select"}} = state) do
    parse_error(state)
  end

  # Per spec: with a select in scope, "Parse error. Ignore the token. Pop elements
  # until a select element has been popped." Otherwise reconstruct, insert, and
  # set frameset-ok to "not ok".
  defp do_process_html_start_tag("select", attrs, _, state) do
    if in_scope?(state, "select", :default) do
      state
      |> parse_error()
      |> close_tag_ref_forced("select")
    else
      state
      |> in_body()
      |> reconstruct_active_formatting()
      |> push_element("select", attrs)
      |> set_frameset_not_ok()
    end
  end

  # applet/marquee/object - push AF marker (scope boundary for formatting elements)
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @af_marker_elements do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> push_af_marker()
    |> set_frameset_not_ok()
  end

  # Generic - block-level elements close p, inline elements reconstruct AF
  defp do_process_html_start_tag(tag, attrs, _, state) when tag in @closes_p do
    state
    |> in_body()
    |> maybe_close_p(tag)
    |> maybe_close_same(tag)
    |> maybe_ruby_parse_error(tag)
    |> maybe_close_current_heading(tag)
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  defp do_process_html_start_tag(tag, attrs, self_closing, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> maybe_close_same(tag)
    |> maybe_parse_error_unacknowledged_self_closing(tag, self_closing)
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  # Generic raw text element parsing: insert the element, remember the current
  # insertion mode, and switch to "text". The tokenizer switches to RAWTEXT itself.
  defp enter_raw_text(%{mode: mode} = state, tag, attrs) do
    state
    |> push_element(tag, attrs)
    |> Map.put(:original_mode, mode)
    |> set_mode(:text)
  end

  defp maybe_parse_error_unacknowledged_self_closing(state, tag, true)
       when tag not in @void_elements do
    parse_error(state)
  end

  defp maybe_parse_error_unacknowledged_self_closing(state, _tag, _self_closing), do: state

  # Helper function for form handling (separate to allow grouping of do_process_html_start_tag clauses)
  defp do_process_html_start_tag_form(attrs, state) do
    state
    |> in_body()
    |> maybe_close_p("form")
    |> push_element("form", attrs)
    |> point_form_element_unless_template()
  end

  # Set form_element only if no template on stack
  defp point_form_element_unless_template(state) do
    if has_template_on_stack?(state) do
      state
    else
      point_form_element(state)
    end
  end

  defp point_form_element(%{stack: [form_ref | _]} = state) do
    %{state | form_element: form_ref}
  end

  # Per HTML5 spec: only close p if NOT in quirks mode
  defp close_p_unless_quirks(%{quirks_mode: true} = state, _tag), do: state
  defp close_p_unless_quirks(state, tag), do: maybe_close_p(state, tag)

  defp close_for_option(state) do
    if in_scope?(state, "select", :default) do
      state
      |> generate_implied_end_tags_except("optgroup")
      |> parse_error_if_in_scope(["option"])
    else
      pop_if_current_tag(state, "option")
    end
  end

  defp close_for_optgroup(state) do
    if in_scope?(state, "select", :default) do
      state
      |> generate_implied_end_tags()
      |> parse_error_if_in_scope(["option", "optgroup"])
    else
      pop_if_current_tag(state, "option")
    end
  end

  defp close_for_hr(state) do
    if in_scope?(state, "select", :default) do
      state
      |> generate_implied_end_tags()
      |> parse_error_if_in_scope(["option", "optgroup"])
    else
      state
    end
  end

  defp close_select_for_input(state) do
    if in_scope?(state, "select", :default) do
      state
      |> parse_error()
      |> close_tag_ref_forced("select")
    else
      state
    end
  end

  defp parse_error_if_in_scope(state, tags) do
    if in_scope?(state, tags, :default) do
      parse_error(state)
    else
      state
    end
  end

  # Per HTML5 spec: "Parse error." Then ignore if only one element on stack (fragment case),
  # or if second element is not body, or if template on stack.
  defp insert_frameset_in_body(%{stack: stack, elements: elements} = state, attrs) do
    cond do
      length(stack) <= 1 ->
        state

      find_ref(state, "template") ->
        state

      not second_element_is_body?(stack, elements) ->
        state

      true ->
        state
        |> close_body_for_frameset()
        |> push_element("frameset", attrs)
        |> set_mode(:in_frameset)
    end
  end

  # Per HTML5 spec: "If the current node is an HTML element whose tag name is one of
  # 'h1'-'h6', then this is a parse error; pop the current node off the stack."
  defp maybe_close_current_heading(state, tag) when tag in @headings do
    state
    |> current_tag()
    |> close_current_heading(state)
  end

  defp maybe_close_current_heading(state, _tag), do: state

  defp close_current_heading(tag, state) when tag in @headings do
    state
    |> parse_error()
    |> pop_element()
  end

  defp close_current_heading(_tag, state), do: state

  defp insert_frame("frameset", attrs, state) do
    add_child_to_stack(state, {"frame", attrs, []})
  end

  defp insert_frame(_tag, _attrs, state), do: parse_error(state)

  defp insert_tr(nil, mode, attrs, state) do
    if mode in @table_related_modes and not has_foreign_on_stack?(state) do
      push_tr(attrs, state)
    else
      parse_error(state)
    end
  end

  defp insert_tr(_table_ref, _mode, attrs, state), do: push_tr(attrs, state)

  defp push_tr(attrs, state) do
    state
    |> in_body()
    |> clear_to_table_body_context()
    |> ensure_tbody()
    |> push_element("tr", attrs)
  end

  defp insert_head_element(nil, :in_template, tag, attrs, self_closing, state) do
    process_start_tag(state, tag, attrs, self_closing)
  end

  defp insert_head_element(nil, _mode, tag, attrs, self_closing, state) do
    state
    |> ensure_html()
    |> ensure_head()
    |> maybe_reopen_head()
    |> process_start_tag(tag, attrs, self_closing)
  end

  defp insert_head_element(_body_ref, _mode, tag, attrs, self_closing, state) do
    process_start_tag(state, tag, attrs, self_closing)
  end

  defp push_head_if_missing(nil, state) do
    state
    |> push_element("head", [])
    |> set_mode(:in_head)
  end

  defp push_head_if_missing(_ref, state), do: state

  defp push_body_if_no_frameset(nil, state) do
    state
    |> push_element("body", [])
    |> set_mode(:in_body)
  end

  defp push_body_if_no_frameset(_ref, state), do: state

  defp insert_template_with_body(nil, attrs, state) do
    do_process_html_start_tag_head_context("template", attrs, state)
  end

  defp insert_template_with_body(_body_ref, attrs, state) do
    state
    |> reconstruct_active_formatting()
    |> push_element("template", attrs)
    |> push_mode(:in_template)
    |> push_af_marker()
  end

  defp insert_template_elsewhere(nil, attrs, state) do
    do_process_html_start_tag_head_context("template", attrs, state)
  end

  defp insert_template_elsewhere(_body_ref, attrs, state) do
    process_start_tag(state, "template", attrs, false)
  end

  defp insert_col_in_table(nil, attrs, state) do
    add_child_to_stack(state, {"col", attrs, []})
  end

  defp insert_col_in_table(_table_ref, attrs, state) do
    state
    |> ensure_colgroup()
    |> add_child_to_stack({"col", attrs, []})
  end

  defp insert_table_structure(nil, _tag, _attrs, state), do: parse_error(state)

  defp insert_table_structure(_table_ref, tag, attrs, state) do
    state
    |> clear_to_table_context()
    |> push_element(tag, attrs)
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

  defp insert_as_head_element(tag, attrs, self_closing, %{mode: mode} = state)
       when mode in [:in_template, :in_body, :in_table] do
    state
    |> find_ref("body")
    |> insert_head_element(mode, tag, attrs, self_closing, state)
  end

  defp insert_as_head_element(tag, attrs, self_closing, state) do
    state
    |> find_ref("body")
    |> insert_head_element(:in_head, tag, attrs, self_closing, state)
  end

  defp process_start_tag(state, tag, attrs, _self_closing) when tag in @void_elements do
    add_child_to_stack(state, {tag, attrs, []})
  end

  defp process_start_tag(state, tag, attrs, _self_closing) do
    push_element(state, tag, attrs)
  end

  # --------------------------------------------------------------------------
  # Foreign content
  # --------------------------------------------------------------------------

  @doc """
  Inserts a foreign element for a start tag processed by the foreign content
  rules: the element goes into the adjusted current node's namespace with the
  SVG tag and foreign attribute adjustments applied.
  """
  def insert_foreign_element({:start_tag, tag, attrs, self_closing}, state) do
    state
    |> do_push_foreign_element(foreign_namespace(state), tag, attrs, self_closing)
    |> ok()
  end

  # Push foreign element with adjustments (local version with self_closing handling)
  # Self-closing: add as child, don't push to stack
  defp do_push_foreign_element(state, ns, tag, attrs, true) do
    add_child_to_stack(
      state,
      {{ns, adjust_svg_tag(ns, tag)}, adjust_foreign_attributes(ns, attrs), []}
    )
  end

  defp do_push_foreign_element(state, ns, tag, attrs, _self_closing) do
    push_foreign_element(state, ns, adjust_svg_tag(ns, tag), adjust_foreign_attributes(ns, attrs))
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
    Enum.map(attrs, fn {key, value} ->
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

  # --------------------------------------------------------------------------
  # Document structure
  # --------------------------------------------------------------------------

  defp ensure_html(%{stack: []} = state) do
    # Create html element and add to elements map
    elem = new_element("html", [], nil)
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
    state
    |> current_tag()
    |> ensure_head_for(state)
  end

  defp ensure_head_for(tag, state) when tag in ["head", "body"], do: state

  defp ensure_head_for("html", state) do
    html_elem = current_element(state)

    html_elem.children
    |> find_ref_in_children(state.elements, "head")
    |> push_head_if_missing(state)
  end

  defp ensure_head_for(_tag, state), do: state

  defp find_ref_in_children(children, elements, tag) do
    Enum.find(children, fn
      ref when is_reference(ref) -> elements[ref].tag == tag
      _ -> false
    end)
  end

  defp close_head(state) do
    state
    |> current_tag()
    |> close_head_if_current(state)
  end

  defp close_head_if_current("head", state) do
    state
    |> pop_element()
    |> set_mode(:after_head)
  end

  defp close_head_if_current(_tag, state), do: state

  defp ensure_body(state) do
    state
    |> current_tag()
    |> ensure_body_for(state)
  end

  defp ensure_body_for(tag, state) when tag in ["body", "frameset", nil], do: state

  defp ensure_body_for("html", state) do
    html_elem = current_element(state)

    html_elem.children
    |> find_ref_in_children(state.elements, "frameset")
    |> push_body_if_no_frameset(state)
  end

  defp ensure_body_for(_tag, state), do: state

  # Modes that can delegate to InBody without mode being changed
  @body_modes [
    :in_body,
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

  # Reopen head element (put it back on the stack)
  defp maybe_reopen_head(state) do
    state
    |> current_tag()
    |> reopen_head_unless_current(state)
  end

  defp reopen_head_unless_current("head", state), do: state
  defp reopen_head_unless_current(_tag, state), do: do_reopen_head(state)

  defp do_reopen_head(%{stack: stack, elements: elements} = state) do
    with html_ref when html_ref != nil <- find_ref(state, "html"),
         head_ref when head_ref != nil <-
           find_ref_in_children(elements[html_ref].children, elements, "head") do
      %{state | stack: [head_ref | stack], current_parent_ref: head_ref}
    else
      _ -> push_element(state, "head", [])
    end
  end

  # Merge attributes from second <body> onto existing body element
  # Per HTML5: adds attributes that don't already exist
  defp merge_body_attrs(state, new_attrs) do
    state
    |> find_ref("body")
    |> merge_body_attrs_at(state, new_attrs)
  end

  defp merge_body_attrs_at(nil, state, _new_attrs), do: state

  defp merge_body_attrs_at(body_ref, %{elements: elements} = state, new_attrs) do
    body_elem = elements[body_ref]
    merged_attrs = merge_attr_lists(new_attrs, body_elem.attrs)
    %{state | elements: Map.put(elements, body_ref, %{body_elem | attrs: merged_attrs})}
  end

  # Per spec: "the second element on the stack" means second from the bottom
  defp second_element_is_body?(stack, elements) do
    case Enum.at(stack, -2) do
      nil -> false
      ref -> elements[ref].tag == "body"
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

  defp reset_insertion_mode(
         %{
           stack: stack,
           elements: elements,
           context_element: context_element,
           scripting: scripting,
           template_mode_stack: template_mode_stack
         } = state
       ) do
    mode = determine_mode_from_stack(stack, elements, context_element, scripting)
    %{state | mode: mode, template_mode_stack: Enum.drop(template_mode_stack, 1)}
  end

  # Check if there are any foreign (SVG/MathML) elements on the stack.
  # Used to determine if table structure handling should be skipped when
  # processing HTML tokens at integration points.
  defp has_foreign_on_stack?(%{stack: stack, elements: elements}) do
    Enum.any?(stack, fn ref ->
      case elements[ref].tag do
        {ns, _} when ns in [:svg, :math] -> true
        _ -> false
      end
    end)
  end

  defp handle_in_body_characters(tag, text, state) when tag in @head_elements do
    state
    |> add_text_to_stack(text)
    |> ok()
  end

  defp handle_in_body_characters(tag, text, state) when tag in @table_context do
    text
    |> String.trim()
    |> insert_table_context_text(text, state)
  end

  defp handle_in_body_characters(_tag, text, state) do
    text
    |> maybe_skip_leading_newline(state)
    |> insert_body_text(state)
  end

  defp insert_table_context_text("", text, state) do
    state
    |> add_text_to_stack(text)
    |> ok()
  end

  defp insert_table_context_text(_non_ws, text, state) do
    state
    |> foster_insert({:text, text})
    |> ok()
  end

  defp insert_body_text("", state), do: ok(state)

  defp insert_body_text(text, state) do
    state
    |> in_body()
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
    |> maybe_set_frameset_not_ok(text)
    |> ok()
  end

  defp maybe_skip_leading_newline(<<?\n, rest::binary>>, state) do
    case current_element(state) do
      %{tag: tag, children: []} when tag in @newline_skipping_elements ->
        rest

      _ ->
        <<?\n, rest::binary>>
    end
  end

  defp maybe_skip_leading_newline(text, _state), do: text

  defp eof_in_body(state) do
    state
    |> maybe_parse_error_for_unclosed_body()
    |> generate_implied_end_tags_thoroughly()
    |> ok()
  end

  # --------------------------------------------------------------------------
  # Parse error helpers
  # --------------------------------------------------------------------------

  # Per spec: </body> and </html> should parse error if there are unclosed elements
  # that shouldn't be open. The spec lists: dd, dt, li, optgroup, option, p, rb, rp,
  # rt, rtc, tbody, td, tfoot, th, thead, tr, body, html, template as OK.
  @allowed_open_at_body_close ~w(dd dt li optgroup option p rb rp rt rtc
    tbody td tfoot th thead tr body html template)
  defp maybe_parse_error_for_unclosed_body(%{stack: stack, elements: elements} = state) do
    if Enum.any?(stack, &unexpected_open_at_body_close?(elements[&1].tag)) do
      parse_error(state)
    else
      state
    end
  end

  defp unexpected_open_at_body_close?(tag) when is_binary(tag) do
    tag not in @allowed_open_at_body_close
  end

  defp unexpected_open_at_body_close?(_foreign_tag), do: true

  # Check if any heading element (h1-h6) is in scope
  defp has_heading_in_scope?(state) do
    in_scope?(state, @headings, :default)
  end

  # --------------------------------------------------------------------------
  # Frameset-ok flag
  # --------------------------------------------------------------------------

  defp maybe_set_frameset_not_ok(%{frameset_ok: false} = state, _text), do: state

  defp maybe_set_frameset_not_ok(state, text) do
    text
    |> String.trim()
    |> set_frameset_not_ok_for_text(state)
  end

  defp set_frameset_not_ok_for_text("", state), do: state
  defp set_frameset_not_ok_for_text(_text, state), do: set_frameset_not_ok(state)

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

  # Drop the refs that closing the table will pop from the active formatting list
  defp drop_table_refs_from_af(%{stack: stack, elements: elements, af: af} = state) do
    closed_refs = do_get_refs_to_close_for_table(stack, elements, MapSet.new())
    %{state | af: reject_refs_from_af(af, closed_refs)}
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
    state
    |> current_tag()
    |> ensure_tbody_for(state)
  end

  defp ensure_tbody_for("table", state), do: push_element(state, "tbody", [])
  defp ensure_tbody_for(_tag, state), do: state

  defp ensure_tr(state) do
    state
    |> current_tag()
    |> ensure_tr_for(state)
  end

  defp ensure_tr_for(tag, state) when tag in @table_sections, do: push_element(state, "tr", [])
  defp ensure_tr_for("tr", state), do: state

  defp ensure_tr_for("template", state) do
    elem = current_element(state)

    if has_table_row_structure?(state, elem.children) do
      push_element(state, "tr", [])
    else
      state
    end
  end

  defp ensure_tr_for(_tag, state), do: state

  defp has_table_row_structure?(%{elements: elements}, children) do
    Enum.any?(children, fn
      ref when is_reference(ref) -> elements[ref].tag in ~w(tr tbody thead tfoot)
      _ -> false
    end)
  end

  @colgroup_close_tags ["td", "th", "tr"] ++ @table_sections

  defp ensure_colgroup(state) do
    state
    |> current_tag()
    |> ensure_colgroup_for(state)
  end

  defp ensure_colgroup_for("colgroup", state), do: state
  defp ensure_colgroup_for("table", state), do: push_element(state, "colgroup", [])

  defp ensure_colgroup_for(tag, state) when tag in @colgroup_close_tags do
    state
    |> pop_element()
    |> ensure_colgroup()
  end

  defp ensure_colgroup_for(_tag, state), do: state

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  defp maybe_close_p(state, tag) when tag in @closes_p do
    state
    |> find_p_in_scope_ref()
    |> close_p_ref(state)
  end

  defp maybe_close_p(state, _tag), do: state

  defp close_p_ref(nil, state), do: state

  # Per spec "close a p element": "If the current node is not a p element,
  # then this is a parse error."
  defp close_p_ref({p_ref, refs_above}, state) do
    state
    |> parse_error_unless_current("p")
    |> drop_non_formatting_refs_from_af([p_ref | refs_above])
    |> pop_to_element_ref(p_ref)
  end

  defp drop_non_formatting_refs_from_af(%{af: af, elements: elements} = state, refs) do
    non_formatting_refs =
      refs
      |> Enum.reject(fn ref -> elements[ref].tag in @formatting_elements end)
      |> MapSet.new()

    %{state | af: reject_refs_from_af(af, non_formatting_refs)}
  end

  # Pop to the element (children already in elements map)
  defp pop_to_element_ref(%{stack: stack, elements: elements} = state, ref) do
    {new_stack, parent_ref} = pop_to_ref(stack, elements, ref)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
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
  # Ruby elements should stop at ruby boundaries to handle nested ruby elements correctly
  @ruby_close_boundaries ~w(ruby table template body html)

  defp maybe_close_same(state, tag) do
    tag
    |> get_implicit_close_config()
    |> close_implicit(tag, state)
  end

  defp close_implicit(nil, _tag, state), do: state

  defp close_implicit(
         {closes, boundaries, close_all?},
         tag,
         %{stack: stack, elements: elements} = state
       ) do
    stack
    |> pop_implicit_close(elements, closes, boundaries, close_all?)
    |> apply_implicit_close(tag, closes, state)
  end

  defp apply_implicit_close(:not_found, _tag, _closes, state), do: state

  defp apply_implicit_close({:ok, new_stack, parent_ref}, tag, closes, state) do
    state
    |> implicit_close_parse_error(tag, closes)
    |> replace_stack(new_stack, parent_ref)
  end

  # For button: "If the stack has a button in scope, this is a parse error."
  defp implicit_close_parse_error(state, "button", _closes), do: parse_error(state)

  # Per spec: for li/dd/dt start tags:
  #   1. Generate implied end tags, except for the target tag
  #   2. If the current node is not the target tag, parse error
  #   3. Pop until the target is popped
  defp implicit_close_parse_error(state, tag, closes) when tag in ~w(li dd dt) do
    state
    |> generate_implied_end_tags_except(tag)
    |> parse_error_unless_current_in(closes)
  end

  defp implicit_close_parse_error(state, _tag, _closes), do: state

  defp replace_stack(state, stack, parent_ref) do
    %{state | stack: stack, current_parent_ref: parent_ref}
  end

  defp maybe_ruby_parse_error(state, tag) when tag in @ruby_elements do
    if in_scope?(state, "ruby", :default) do
      parse_error_unless_current(state, "ruby")
    else
      state
    end
  end

  defp maybe_ruby_parse_error(state, _tag), do: state

  defp parse_error_unless_current(state, tag) do
    state
    |> current_tag()
    |> mismatch_if_not(tag, state)
  end

  defp mismatch_if_not(tag, tag, state), do: state
  defp mismatch_if_not(_current, _tag, state), do: parse_error(state)

  defp parse_error_unless_current_in(state, closes) do
    state
    |> current_tag()
    |> mismatch_if_not_in(closes, state)
  end

  defp mismatch_if_not_in(tag, closes, state) do
    if tag in closes, do: state, else: parse_error(state)
  end

  defp pop_implicit_close(stack, elements, closes, boundaries, true = _close_all?),
    do: pop_to_implicit_close_all_ref(stack, elements, closes, boundaries)

  defp pop_implicit_close(stack, elements, closes, boundaries, false = _close_all?),
    do: pop_to_implicit_close_ref(stack, elements, closes, boundaries)

  defp get_implicit_close_config("li"), do: {["li"], @li_scope_boundaries, false}

  for {tag, also_closes} <- @implicit_closes, tag != "li" do
    closes = [tag | also_closes]
    close_all? = tag in @ruby_elements

    boundaries =
      if tag in @ruby_elements, do: @ruby_close_boundaries, else: @implicit_close_boundaries

    defp get_implicit_close_config(unquote(tag)) do
      {unquote(closes), unquote(boundaries), unquote(close_all?)}
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

  # Close tag using ref-only stack architecture (respects special element stops)
  defp close_tag_ref(%{stack: stack, elements: elements} = state, tag) do
    apply_pop_result(state, pop_until_tag_ref(stack, elements, tag))
  end

  # "Any other end tag" per spec — walk the stack with parse error detection.
  # If node matches tag and node is not the current node: parse error.
  # If node is special: parse error; ignore.
  defp close_any_other_end_tag(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_tag_ref(stack, elements, tag) do
      {:found, _new_stack, _parent_ref} = result ->
        # Per spec: generate implied end tags except for the target tag,
        # then check if current node matches.
        state
        |> generate_implied_end_tags_except(tag)
        |> parse_error_unless_current(tag)
        |> apply_pop_result(result)

      :not_found ->
        # Per spec: hit a special element without finding match — parse error; ignore
        parse_error(state)
    end
  end

  # Close foreign root element (svg or math) - ignores internal barriers
  # This is needed because </svg> and </math> should close all children
  defp close_foreign_root(%{stack: stack, elements: elements} = state, ns) do
    apply_pop_result(state, pop_until_foreign_root(stack, elements, ns))
  end

  defp pop_until_foreign_root([], _elements, _ns), do: :not_found

  defp pop_until_foreign_root([ref | rest], elements, ns) do
    case elements[ref].tag do
      # Found the root foreign element (e.g., {:svg, "svg"} or {:math, "math"})
      {^ns, tag} when tag in ["svg", "math"] ->
        {:found, rest, elements[ref].parent_ref}

      # Keep looking past other elements (including foreign children)
      _ ->
        pop_until_foreign_root(rest, elements, ns)
    end
  end

  # Close tag for specifically-handled end tags (template, table, select, frameset)
  # Does NOT respect special element stops - only template is a barrier
  defp close_tag_ref_forced(%{stack: stack, elements: elements} = state, tag) do
    apply_pop_result(state, pop_until_tag_ref_block(stack, elements, tag))
  end

  # Close HTML template only (not foreign templates like SVG/MathML)
  defp close_html_template(%{stack: stack, elements: elements} = state) do
    apply_pop_result(state, pop_until_html_template(stack, elements))
  end

  defp pop_until_html_template([], _elements), do: :not_found

  defp pop_until_html_template([ref | rest], elements) when is_map_key(elements, ref) do
    case elements[ref].tag do
      "template" -> {:found, rest, elements[ref].parent_ref}
      _ -> pop_until_html_template(rest, elements)
    end
  end

  defp pop_until_html_template([_ref | rest], elements) do
    pop_until_html_template(rest, elements)
  end

  # Close block-level end tag: per spec check scope, generate implied end tags,
  # check current node, then pop.
  defp close_block_end_tag(state, tag) do
    if in_scope?(state, tag, :default) do
      # Per spec: if current node is not the element, parse error
      state
      |> generate_implied_end_tags()
      |> parse_error_unless_current(tag)
      |> do_close_block_end_tag(tag)
    else
      # Per spec: parse error; ignore the token
      parse_error(state)
    end
  end

  defp do_close_block_end_tag(%{stack: stack, elements: elements} = state, tag) do
    apply_pop_result(state, pop_until_tag_ref_block(stack, elements, tag))
  end

  # Special </form> handling when no template on stack
  # Per spec: Let node be the element that the form element pointer is set to.
  # Set form element pointer to null. If node is not in the stack, parse error; return.
  # Generate implied end tags. If current node is not node, parse error.
  # Remove node from stack.
  defp close_form_special(state, form_ref) do
    if node_in_scope?(state, form_ref) do
      state
      |> clear_form_element()
      |> generate_implied_end_tags()
      |> parse_error_unless_current_ref(form_ref)
      |> remove_from_stack(form_ref)
    else
      # Per spec: node not in scope: parse error; ignore the token
      state
      |> clear_form_element()
      |> parse_error()
    end
  end

  defp clear_form_element(state), do: %{state | form_element: nil}

  # Per spec: after generating implied end tags, if the current node is not
  # the form element, parse error
  defp parse_error_unless_current_ref(%{stack: [ref | _]} = state, ref), do: state
  defp parse_error_unless_current_ref(state, _ref), do: parse_error(state)

  # </form> when template IS on stack
  # Per spec: If form not in scope, parse error; ignore. Generate implied end tags.
  # If current node is not form, parse error. Pop stack until form.
  defp close_form_with_template(state) do
    if in_scope?(state, "form", :default) do
      state
      |> generate_implied_end_tags()
      |> parse_error_unless_current("form")
      |> close_tag_ref("form")
    else
      parse_error(state)
    end
  end

  defp remove_from_stack(%{stack: stack} = state, ref) do
    new_stack = List.delete(stack, ref)
    %{state | stack: new_stack, current_parent_ref: List.first(new_stack)}
  end

  # Check if there's a template element on the stack of open elements
  defp has_template_on_stack?(state) do
    find_ref(state, "template") != nil
  end

  # Close any heading element (h1-h6) per HTML5 spec
  # Any heading end tag closes any open heading element
  defp close_any_heading(%{stack: stack, elements: elements} = state) do
    apply_pop_result(state, pop_until_any_heading(stack, elements))
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
    apply_pop_result(state, find_li_in_list_scope(stack, elements))
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
    apply_pop_result(state, find_dd_dt_in_scope(stack, elements, target))
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

  @svg_special ~w(desc foreignobject title)
  @mathml_special ~w(annotation-xml mi mn mo ms mtext)

  defp pop_until_tag_ref([], _elements, _target), do: :not_found

  defp pop_until_tag_ref([ref | rest], elements, target) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag_matches?(tag, target) -> {:found, rest, parent_ref}
      special_element_barrier?(tag) -> :not_found
      true -> pop_until_tag_ref(rest, elements, target)
    end
  end

  defp pop_until_tag_ref([_ref | rest], elements, target) do
    pop_until_tag_ref(rest, elements, target)
  end

  # Pop until tag for block-level end tags - only template is a barrier
  defp pop_until_tag_ref_block([], _elements, _target), do: :not_found

  defp pop_until_tag_ref_block([ref | rest], elements, target)
       when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag_matches?(tag, target) -> {:found, rest, parent_ref}
      tag == "template" -> :not_found
      true -> pop_until_tag_ref_block(rest, elements, target)
    end
  end

  defp pop_until_tag_ref_block([_ref | rest], elements, target) do
    pop_until_tag_ref_block(rest, elements, target)
  end

  # Apply the result of a pop_until_* function to the state.
  # Shared by close_tag_ref, close_tag_ref_forced, close_foreign_root, and do_close_block_end_tag.
  defp apply_pop_result(state, {:found, [new_top | _] = new_stack, _parent_ref}) do
    %{state | stack: new_stack, current_parent_ref: new_top}
  end

  defp apply_pop_result(state, {:found, [], _parent_ref}) do
    %{state | stack: [], current_parent_ref: nil}
  end

  defp apply_pop_result(state, :not_found), do: state

  # Check if element tag matches target (case-insensitive for SVG)
  defp tag_matches?(tag, target) when is_binary(tag), do: tag == target
  defp tag_matches?({:svg, svg_tag}, target), do: String.downcase(svg_tag) == target
  defp tag_matches?({:math, math_tag}, target), do: math_tag == target
  defp tag_matches?(_, _), do: false

  # Check if tag is a special element that acts as a barrier
  defp special_element_barrier?(tag) when is_binary(tag), do: tag in @special_elements
  defp special_element_barrier?({:svg, tag}), do: String.downcase(tag) in @svg_special
  defp special_element_barrier?({:math, tag}), do: tag in @mathml_special
  defp special_element_barrier?(_), do: false

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

  # Per spec: create a new element for the entry, insert it (foster-parented
  # when foster parenting applies), push it, and repoint the entry to it.
  defp reconstruct_entries([{old_ref, tag, attrs} | rest], state) do
    state
    |> push_element(tag, attrs)
    |> repoint_af_entry(old_ref, tag, attrs)
    |> reconstruct_entries_rest(rest)
  end

  defp repoint_af_entry(%{stack: [new_ref | _], af: af} = state, old_ref, tag, attrs) do
    %{state | af: update_af_entry(af, old_ref, {new_ref, tag, attrs})}
  end

  defp reconstruct_entries_rest(state, rest), do: reconstruct_entries(rest, state)

  defp add_formatting_entry(%{stack: [ref | _], af: af} = state, tag, attrs) do
    %{state | af: apply_noahs_ark([{ref, tag, attrs} | af], tag, attrs)}
  end

  defp close_existing_anchor(%{af: af} = state) do
    af
    |> anchor_ref_after_last_marker()
    |> close_anchor(state)
  end

  # The list head is its end; entries up to the first marker are in scope.
  defp anchor_ref_after_last_marker(af) do
    af
    |> Enum.take_while(&(&1 != :marker))
    |> Enum.find_value(fn
      {ref, "a", _attrs} -> ref
      _entry -> nil
    end)
  end

  defp close_anchor(nil, state), do: state

  defp close_anchor(ref, state) do
    state
    |> parse_error()
    |> AdoptionAgency.run("a", &close_tag_ref/2)
    |> remove_af_entry(ref)
    |> remove_from_stack_if_present(ref)
  end

  defp remove_af_entry(%{af: af} = state, ref) do
    %{state | af: Enum.reject(af, &match?({^ref, _, _}, &1))}
  end

  defp remove_from_stack_if_present(%{stack: stack} = state, ref) do
    if ref in stack do
      remove_from_stack(state, ref)
    else
      state
    end
  end

  # Noah's Ark clause: if there are already 3 formatting elements with same tag/attrs
  # in the current scope (before any marker), remove the oldest one.
  defp apply_noahs_ark(af, tag, attrs) do
    # Only consider entries before the first marker (current scope)
    in_scope = Enum.take_while(af, &(&1 != :marker))

    matching_indices =
      in_scope
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

  defp close_nobr_in_scope(state) do
    if in_scope?(state, "nobr", :default) do
      state
      |> parse_error()
      |> AdoptionAgency.run("nobr", &close_tag_ref/2)
      |> reconstruct_active_formatting()
    else
      state
    end
  end

  # Pop element if current tag matches target
  defp pop_if_current_tag(state, tag) do
    state
    |> current_tag()
    |> pop_if_tag(tag, state)
  end

  defp pop_if_tag(tag, tag, state), do: pop_element(state)
  defp pop_if_tag(_current, _expected, state), do: state
end
