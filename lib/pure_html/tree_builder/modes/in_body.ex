defmodule PureHTML.TreeBuilder.Modes.InBody do
  @moduledoc """
  HTML5 "in body" insertion mode.

  This is the main parsing mode for document content inside <body>.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.AdoptionAgency
  alias PureHTML.TreeBuilder.ForeignContent
  alias PureHTML.TreeBuilder.Modes.InTemplate

  # --------------------------------------------------------------------------
  # Element categories
  # --------------------------------------------------------------------------

  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)
  @head_elements ~w(base basefont bgsound link meta noframes script style template title)
  @void_elements ~w(area base basefont bgsound br embed hr img input keygen link meta param source track wbr)
  @af_marker_elements ~w(applet marquee object)
  @ignored_start_tags ~w(caption col colgroup frame tbody td tfoot th thead tr)

  @closes_p ~w(address article aside blockquote center details dialog dir div dl dd dt
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr li listing main menu nav ol p plaintext pre search section summary table ul xmp)

  # Block-level end tags per HTML5 spec (generate implied end tags, then pop until match)
  # These do NOT use the "special element stops traversal" rule
  @block_end_tags ~w(address article aside blockquote button center details dialog dir div
                     dl fieldset figcaption figure footer form header hgroup listing main
                     menu nav ol pre search section select summary ul)

  # Note: input is handled specially - only non-hidden inputs disable frameset
  # Start tags whose in-body entries set the frameset-ok flag to "not ok"
  # (input is handled by its own entry: only when its type is not hidden)
  @frameset_disabling_elements ~w(pre listing textarea xmp iframe select embed keygen applet
                                  marquee object table button img hr br wbr area dd dt li)

  # --------------------------------------------------------------------------
  # Token processing
  # --------------------------------------------------------------------------

  @impl true
  # Character tokens
  # U+0000: "Parse error. Ignore the token." One error per NUL; the rest of
  # the text is inserted as usual.
  def process({:character, text}, state) do
    {text, null_count} = split_null_characters(text)

    state
    |> parse_error(null_count)
    |> insert_body_text(text)
  end

  # Comment tokens
  def process({:comment, _text}, %{stack: []} = state), do: ok(state)

  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  def process({:pi, _target, _data}, %{stack: []} = state), do: ok(state)

  def process({:pi, target, data}, state) do
    state
    |> insert_pi(target, data)
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

  def process({:end_tag, tag} = token, state) when tag in ~w(p br) do
    do_process_end_tag(token, state)
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
    |> AdoptionAgency.run(tag, &close_any_other_end_tag/2)
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

  # Template end tag: process using the "in head" rules
  def process({:end_tag, "template"} = token, state) do
    state
    |> process_in_head(token)
    |> ok()
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
  # "If the stack of template insertion modes is not empty, then process the
  # token using the rules for the in template insertion mode."
  def process(:eof, %{template_mode_stack: [_ | _]} = state), do: InTemplate.process(:eof, state)

  def process(:eof, state), do: eof_in_body(state)

  # --------------------------------------------------------------------------
  # Start tags
  # --------------------------------------------------------------------------

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

  # Per spec: parse error; ignore the token with a template on the stack, or
  # when the stack has only one element or its second element is not a body;
  # otherwise set frameset-ok to "not ok" and merge the attributes into the body.
  def process({:start_tag, "body", attrs, _}, state) do
    state
    |> parse_error()
    |> merge_body_start_tag(attrs)
    |> ok()
  end

  # Per spec: reconstruct the active formatting elements, then insert a
  # foreign element with the SVG (or MathML) and foreign attribute adjustments
  def process({:start_tag, "svg", attrs, self_closing}, state) do
    state
    |> reconstruct_active_formatting()
    |> ForeignContent.insert_element(:svg, "svg", attrs, self_closing)
    |> ok()
  end

  def process({:start_tag, "math", attrs, self_closing}, state) do
    state
    |> reconstruct_active_formatting()
    |> ForeignContent.insert_element(:math, "math", attrs, self_closing)
    |> ok()
  end

  def process({:start_tag, tag, _, _} = token, state) do
    tag
    |> correct_tag()
    |> process_corrected_start_tag(token, state)
  end

  defp process_corrected_start_tag(tag, {:start_tag, tag, _, _} = token, state) do
    state
    |> dispatch_start_tag(token)
    |> ok()
  end

  # Per spec: <image> — "Parse error. Change the token's tag name to 'img'."
  defp process_corrected_start_tag(corrected_tag, {:start_tag, _, attrs, self_closing}, state) do
    state
    |> parse_error()
    |> dispatch_start_tag({:start_tag, corrected_tag, attrs, self_closing})
    |> ok()
  end

  # Dispatch an HTML start tag with the in-body rules. Per spec, a start tag
  # whose self-closing flag is not acknowledged by the tree construction stage
  # is a parse error; only void elements (and foreign elements, handled
  # elsewhere) acknowledge it.
  defp dispatch_start_tag(state, {:start_tag, tag, _, self_closing} = token) do
    token
    |> start_tag(state)
    |> maybe_parse_error_unacknowledged_self_closing(tag, self_closing)
  end

  # Per spec: with no p element in button scope, parse error and insert a p
  # element for a start tag with no attributes; then close a p element.
  defp do_process_end_tag({:end_tag, "p"}, state) do
    if in_scope?(state, "p", :button) do
      state
      |> close_p()
      |> ok()
    else
      state
      |> parse_error()
      |> push_element("p", [])
      |> close_p()
      |> ok()
    end
  end

  # "Parse error. Drop the attributes from the token, and act as if this was a
  # br start tag token with no attributes."
  defp do_process_end_tag({:end_tag, "br"}, state) do
    state
    |> parse_error()
    |> dispatch_start_tag({:start_tag, "br", [], false})
    |> ok()
  end

  # --------------------------------------------------------------------------
  # HTML start tag processing
  # --------------------------------------------------------------------------

  # <noscript> with scripting enabled: process using "in head" rules (RAWTEXT)
  defp start_tag({:start_tag, "noscript", attrs, self_closing}, %{scripting: true} = state) do
    process_in_head(state, {:start_tag, "noscript", attrs, self_closing})
  end

  # <noscript> with scripting disabled: reconstruct AF, push element (parsed as HTML)
  defp start_tag({:start_tag, "noscript", attrs, _}, state) do
    state
    |> reconstruct_active_formatting()
    |> push_element("noscript", attrs)
  end

  # Other head elements: process using "in head" rules
  defp start_tag({:start_tag, tag, attrs, self_closing}, state)
       when tag in @head_elements do
    process_in_head(state, {:start_tag, tag, attrs, self_closing})
  end

  # Per HTML5 spec: "Parse error." Then ignore if only one element on stack
  # (fragment case), if the second element is not body, or if frameset-ok is "not ok".
  defp start_tag({:start_tag, "frameset", attrs, _}, %{frameset_ok: true} = state) do
    state
    |> parse_error()
    |> insert_frameset_in_body(attrs)
  end

  defp start_tag({:start_tag, "frameset", _, _}, state), do: parse_error(state)

  # Per spec: in a select fragment, "Parse error. Ignore the token."
  defp start_tag({:start_tag, "input", _attrs, _}, %{context_element: {_ns, "select"}} = state) do
    parse_error(state)
  end

  # Per spec: with a select in scope, parse error and pop until a select has been
  # popped; then reconstruct, insert and pop; non-hidden inputs set frameset-ok to "not ok".
  defp start_tag({:start_tag, "input", attrs, _}, state) do
    state
    |> close_select_for_input()
    |> reconstruct_active_formatting()
    |> add_child_to_stack({"input", attrs, []})
    |> maybe_set_frameset_not_ok_for_input(attrs)
  end

  # Per spec: close a p in button scope; with a select in scope, generate implied
  # end tags and parse-error if an option or optgroup is still in scope; insert
  # and pop; set frameset-ok to "not ok". (No formatting reconstruction.)
  defp start_tag({:start_tag, "hr", attrs, _}, state) do
    state
    |> maybe_close_p("hr")
    |> close_for_hr()
    |> add_child_to_stack({"hr", attrs, []})
    |> set_frameset_not_ok()
  end

  # "area, br, embed, img, keygen, wbr": reconstruct the active formatting
  # elements, insert, pop, set frameset-ok to "not ok".
  defp start_tag({:start_tag, tag, attrs, _}, state)
       when tag in ~w(area br embed img keygen wbr) do
    state
    |> reconstruct_active_formatting()
    |> add_child_to_stack({tag, attrs, []})
    |> set_frameset_not_ok()
  end

  # "param, source, track": insert and pop; no reconstruction, frameset-ok kept.
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in ~w(param source track) do
    add_child_to_stack(state, {tag, attrs, []})
  end

  # "pre", "listing": close a p in button scope, insert, ignore a LF that is
  # the next token, set frameset-ok to "not ok".
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in ~w(pre listing) do
    state
    |> maybe_close_p(tag)
    |> push_element(tag, attrs)
    |> ignore_next_lf()
    |> set_frameset_not_ok()
  end

  # "A start tag whose tag name is one of: caption, col, colgroup, frame, head,
  # tbody, td, tfoot, th, thead, tr: Parse error. Ignore the token." (head has
  # its own clause above.)
  defp start_tag({:start_tag, tag, _, _}, state) when tag in @ignored_start_tags do
    parse_error(state)
  end

  # Per spec: with a button in scope, parse error, generate implied end tags,
  # and pop until a button has been popped; then reconstruct, insert, and set
  # frameset-ok to "not ok".
  defp start_tag({:start_tag, "button", attrs, _}, state) do
    state
    |> close_open_button()
    |> reconstruct_active_formatting()
    |> push_element("button", attrs)
    |> set_frameset_not_ok()
  end

  # Per spec: an a element in the active formatting list after the last marker
  # is a parse error; run the adoption agency algorithm, then remove that
  # element from the list and the stack if the algorithm didn't already.
  defp start_tag({:start_tag, "a", attrs, _}, state) do
    state
    |> close_existing_anchor()
    |> reconstruct_active_formatting()
    |> push_element("a", attrs)
    |> add_formatting_entry("a", attrs)
  end

  # Per spec: reconstruct; if a nobr element is in scope, parse error, run the
  # adoption agency algorithm, and reconstruct again.
  defp start_tag({:start_tag, "nobr", attrs, _}, state) do
    state
    |> reconstruct_active_formatting()
    |> close_nobr_in_scope()
    |> push_element("nobr", attrs)
    |> add_formatting_entry("nobr", attrs)
  end

  # Formatting elements
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in @formatting_elements do
    state
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> add_formatting_entry(tag, attrs)
  end

  # Per spec: xmp closes a p in button scope, reconstructs active formatting,
  # sets frameset-ok to "not ok", then follows the generic raw text algorithm.
  defp start_tag({:start_tag, "xmp", attrs, _}, state) do
    state
    |> maybe_close_p("xmp")
    |> reconstruct_active_formatting()
    |> set_frameset_not_ok()
    |> enter_raw_text("xmp", attrs)
  end

  # Per spec: iframe sets frameset-ok to "not ok", then generic raw text.
  defp start_tag({:start_tag, "iframe", attrs, _}, state) do
    state
    |> set_frameset_not_ok()
    |> enter_raw_text("iframe", attrs)
  end

  # Per spec: noembed follows the generic raw text algorithm.
  defp start_tag({:start_tag, "noembed", attrs, _}, state) do
    state
    |> enter_raw_text("noembed", attrs)
  end

  # Per spec: insert the textarea, ignore a LF that is the next token, switch
  # the tokenizer to RCDATA, set frameset-ok to "not ok", and enter the text
  # mode.
  defp start_tag({:start_tag, "textarea", attrs, _}, state) do
    state
    |> push_element("textarea", attrs)
    |> ignore_next_lf()
    |> set_frameset_not_ok()
    |> enter_text_mode(:rcdata)
  end

  # Per spec: close a p in button scope, insert the element, and switch the
  # tokenizer to PLAINTEXT; the insertion mode stays.
  defp start_tag({:start_tag, "plaintext", attrs, _}, state) do
    state
    |> maybe_close_p("plaintext")
    |> push_element("plaintext", attrs)
    |> switch_tokenizer(:plaintext)
  end

  # Per spec: with a select in scope, generate implied end tags except optgroup and
  # parse-error if an option is still in scope; otherwise pop a current option.
  defp start_tag({:start_tag, "option", attrs, _}, state) do
    state
    |> close_for_option()
    |> reconstruct_active_formatting()
    |> push_element("option", attrs)
  end

  # Per spec: with a select in scope, generate implied end tags and parse-error if
  # an option or optgroup is still in scope; otherwise pop a current option.
  defp start_tag({:start_tag, "optgroup", attrs, _}, state) do
    state
    |> close_for_optgroup()
    |> reconstruct_active_formatting()
    |> push_element("optgroup", attrs)
  end

  # Table
  defp start_tag({:start_tag, "table", attrs, _}, state) do
    state
    |> close_p_unless_quirks("table")
    |> push_element("table", attrs)
    |> set_mode(:in_table)
    |> set_frameset_not_ok()
  end

  # Form - Per spec: "If the form element pointer is not null, and there is no
  # template element on the stack of open elements, then this is a parse error; ignore the token."
  defp start_tag({:start_tag, "form", attrs, _}, %{form_element: f} = state)
       when not is_nil(f) do
    if has_template_on_stack?(state) do
      # With template, process normally (form_element won't be set again)
      insert_form(attrs, state)
    else
      # Parse error, ignore the form tag
      parse_error(state)
    end
  end

  defp start_tag({:start_tag, "form", attrs, _}, state) do
    insert_form(attrs, state)
  end

  # Per spec: in a select fragment, "Parse error. Ignore the token."
  defp start_tag({:start_tag, "select", _attrs, _}, %{context_element: {_ns, "select"}} = state) do
    parse_error(state)
  end

  # Per spec: with a select in scope, "Parse error. Ignore the token. Pop elements
  # until a select element has been popped." Otherwise reconstruct, insert, and
  # set frameset-ok to "not ok".
  defp start_tag({:start_tag, "select", attrs, _}, state) do
    if in_scope?(state, "select", :default) do
      state
      |> parse_error()
      |> close_tag_ref_forced("select")
    else
      state
      |> reconstruct_active_formatting()
      |> push_element("select", attrs)
      |> set_frameset_not_ok()
    end
  end

  # applet/marquee/object - push AF marker (scope boundary for formatting elements)
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in @af_marker_elements do
    state
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> push_af_marker()
    |> set_frameset_not_ok()
  end

  # rb, rtc: with a ruby element in scope, generate implied end tags; a parse
  # error unless the current node is then a ruby element.
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in ~w(rb rtc) do
    state
    |> close_ruby_parts(tag)
    |> push_element(tag, attrs)
  end

  # rp, rt: the same, keeping an open rtc; the current node must then be an
  # rtc or a ruby element.
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in ~w(rp rt) do
    state
    |> close_ruby_parts(tag)
    |> push_element(tag, attrs)
  end

  # Generic - block-level elements close p, inline elements reconstruct AF
  defp start_tag({:start_tag, tag, attrs, _}, state) when tag in @closes_p do
    state
    |> close_open_list_item(tag)
    |> maybe_close_p(tag)
    |> maybe_close_current_heading(tag)
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  defp start_tag({:start_tag, tag, attrs, _self_closing}, state) do
    state
    |> reconstruct_active_formatting()
    |> push_element(tag, attrs)
    |> maybe_set_frameset_not_ok_for_element(tag)
  end

  # Generic raw text element parsing
  defp enter_raw_text(state, tag, attrs) do
    state
    |> push_element(tag, attrs)
    |> enter_text_mode(:rawtext)
  end

  defp maybe_parse_error_unacknowledged_self_closing(state, tag, true)
       when tag not in @void_elements do
    parse_error(state)
  end

  defp maybe_parse_error_unacknowledged_self_closing(state, _tag, _self_closing), do: state

  # form: the form element pointer must be null unless a template is open
  defp insert_form(attrs, state) do
    state
    |> maybe_close_p("form")
    |> push_element("form", attrs)
    |> point_form_element()
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

  # --------------------------------------------------------------------------
  # Body element
  # --------------------------------------------------------------------------

  defp merge_body_start_tag(%{stack: [_]} = state, _attrs), do: state

  defp merge_body_start_tag(%{stack: stack, elements: elements} = state, attrs) do
    if has_template_on_stack?(state) or not second_element_is_body?(stack, elements) do
      state
    else
      state
      |> set_frameset_not_ok()
      |> merge_body_attrs(attrs)
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
    {new_stack, new_elements, _parent_ref} = do_close_body_for_frameset(stack, elements)
    %{state | stack: new_stack, elements: new_elements}
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

  defp insert_body_text(state, ""), do: ok(state)

  defp insert_body_text(state, text) do
    state
    |> reconstruct_active_formatting()
    |> add_text_to_stack(text)
    |> maybe_set_frameset_not_ok(text)
    |> ok()
  end

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
    |> ascii_whitespace_only?()
    |> set_frameset_not_ok_for_text(state)
  end

  defp set_frameset_not_ok_for_text(true, state), do: state
  defp set_frameset_not_ok_for_text(false, state), do: set_frameset_not_ok(state)

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

  # --------------------------------------------------------------------------
  # Implicit closing
  # --------------------------------------------------------------------------

  # "If the stack of open elements has a p element in button scope, then close
  # a p element."
  defp maybe_close_p(state, tag) when tag in @closes_p do
    if in_scope?(state, "p", :button), do: close_p(state), else: state
  end

  defp maybe_close_p(state, _tag), do: state

  # Close a p element: generate implied end tags except p, parse error unless
  # the current node is then a p, pop through the p.
  defp close_p(state) do
    state
    |> generate_implied_end_tags_except("p")
    |> parse_error_unless_current("p")
    |> close_tag_ref_forced("p")
  end

  defp close_open_button(state) do
    if in_scope?(state, "button", :default) do
      state
      |> parse_error()
      |> generate_implied_end_tags()
      |> pop_through("button")
    else
      state
    end
  end

  # li, dd, dt start tags: walk the stack from the current node. An open item
  # of the same kind (li, or dd/dt) is closed with implied end tags except
  # itself, a parse error unless it is then the current node, and a pop up to
  # and including it. A special element other than address, div, or p ends
  # the walk.
  defp close_open_list_item(%{stack: stack, elements: elements} = state, tag)
       when tag in ~w(li dd dt) do
    stack
    |> find_open_list_item(elements, list_item_kind(tag))
    |> close_list_item(state)
  end

  defp close_open_list_item(state, _tag), do: state

  defp list_item_kind("li"), do: ["li"]
  defp list_item_kind(_dd_or_dt), do: ["dd", "dt"]

  defp find_open_list_item([], _elements, _kind), do: nil

  defp find_open_list_item([ref | rest], elements, kind) do
    tag = elements[ref].tag

    cond do
      tag in kind -> tag
      tag in ~w(address div p) -> find_open_list_item(rest, elements, kind)
      special_element?(tag) -> nil
      true -> find_open_list_item(rest, elements, kind)
    end
  end

  defp close_list_item(nil, state), do: state

  defp close_list_item(tag, state) do
    state
    |> generate_implied_end_tags_except(tag)
    |> parse_error_unless_current(tag)
    |> close_tag_ref_forced(tag)
  end

  defp close_ruby_parts(state, tag) when tag in ~w(rb rtc) do
    if in_scope?(state, "ruby", :default) do
      state
      |> generate_implied_end_tags()
      |> parse_error_unless_current("ruby")
    else
      state
    end
  end

  defp close_ruby_parts(state, _rp_or_rt) do
    if in_scope?(state, "ruby", :default) do
      state
      |> generate_implied_end_tags_except("rtc")
      |> parse_error_unless_current_in(["rtc", "ruby"])
    else
      state
    end
  end

  defp parse_error_unless_current_in(state, tags) do
    state
    |> current_tag()
    |> mismatch_if_not_in(tags, state)
  end

  defp parse_error_unless_current(state, tag) do
    state
    |> current_tag()
    |> mismatch_if_not(tag, state)
  end

  defp mismatch_if_not(tag, tag, state), do: state
  defp mismatch_if_not(_current, _tag, state), do: parse_error(state)

  defp mismatch_if_not_in(tag, closes, state) do
    if tag in closes, do: state, else: parse_error(state)
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

  # Close tag for specifically-handled end tags (template, table, select, frameset)
  # Does NOT respect special element stops - only template is a barrier
  defp close_tag_ref_forced(%{stack: stack, elements: elements} = state, tag) do
    apply_pop_result(state, pop_until_tag_ref_block(stack, elements, tag))
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
    %{state | stack: List.delete(stack, ref)}
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

  defp pop_until_tag_ref([], _elements, _target), do: :not_found

  defp pop_until_tag_ref([ref | rest], elements, target) when is_map_key(elements, ref) do
    %{tag: tag, parent_ref: parent_ref} = elements[ref]

    cond do
      tag_matches?(tag, target) -> {:found, rest, parent_ref}
      special_element?(tag) -> :not_found
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
  # Shared by close_tag_ref, close_tag_ref_forced, and do_close_block_end_tag.
  defp apply_pop_result(state, {:found, new_stack, _parent_ref}), do: %{state | stack: new_stack}

  defp apply_pop_result(state, :not_found), do: state

  # The end-tag walks look for "an HTML element with the same tag name";
  # a foreign element never matches.
  defp tag_matches?(tag, target) when is_binary(tag), do: tag == target
  defp tag_matches?(_foreign, _target), do: false

  # Check if tag is a special element that acts as a barrier

  # --------------------------------------------------------------------------
  # Active formatting elements
  # --------------------------------------------------------------------------

  # Reconstruct the active formatting elements: walking back from the end of
  # the list, the entries after the last marker or still-open element are
  # recreated in order.
  defp reconstruct_active_formatting(%{stack: stack, af: af} = state) do
    af
    |> entries_to_reconstruct(stack)
    |> reconstruct_entries(state)
  end

  # The list head is its end; the oldest entry to recreate comes first.
  defp entries_to_reconstruct(af, stack) do
    af
    |> Enum.take_while(fn
      :marker -> false
      {ref, _tag, _attrs} -> ref not in stack
    end)
    |> Enum.reverse()
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
    |> AdoptionAgency.run("a", &close_any_other_end_tag/2)
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
      |> AdoptionAgency.run("nobr", &close_any_other_end_tag/2)
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
