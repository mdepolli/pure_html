defmodule PureHTML.TreeBuilder.Modes.InTable do
  @moduledoc """
  HTML5 "in table" insertion mode.

  This mode handles content inside a <table> element.

  Per HTML5 spec:
  - Character tokens with a table, tbody, template, tfoot, thead, or tr as the
    current node: collect them in "in table text"
  - Comments: insert comment
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption: clear to table context, insert marker, insert caption, switch to in_caption
    - colgroup: clear to table context, insert colgroup, switch to in_column_group
    - col: clear to table context, insert colgroup, switch to in_column_group, reprocess
    - tbody/thead/tfoot: clear to table context, insert element, switch to in_table_body
    - td/th/tr: clear to table context, insert tbody, switch to in_table_body, reprocess
    - table: parse error; with a table in table scope, pop through it, reset the
      insertion mode, reprocess
    - style/script/template: process using in_head rules
    - input type=hidden: parse error, insert and pop
    - form: parse error; with no template on the stack and a null form pointer,
      insert the form, point to it, and pop it
    - Anything else: parse error, enable foster parenting, process using in_body rules
  - End tags:
    - table: with a table in table scope, pop through it and reset the insertion mode
    - body/caption/col/colgroup/html/tbody/td/tfoot/th/thead/tr: parse error, ignore
    - template: process using in_head rules
    - Anything else: parse error, enable foster parenting, process using in_body rules
  - EOF: process using in_body rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intable
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Modes.InHead

  @table_sections ~w(tbody thead tfoot)
  @table_context ~w(table tbody template tfoot thead tr)
  @ignored_end_tags ~w(body caption col colgroup html tbody td tfoot th thead tr)

  @impl true
  def process(token, state) do
    do_process(token, state)
  end

  # Character tokens in table context elements: switch to in_table_text mode
  defp do_process({:character, text}, %{stack: [ref | _], elements: elements} = state) do
    do_process_character(elements[ref], text, state)
  end

  defp do_process({:character, text}, state) do
    InBody.process({:character, text}, state)
  end

  # Comments: insert
  defp do_process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  defp do_process({:pi, target, data}, state) do
    state
    |> insert_pi(target, data)
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  defp do_process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: caption
  defp do_process({:start_tag, "caption", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_af_marker()
    |> push_element("caption", attrs)
    |> set_mode(:in_caption)
    |> ok()
  end

  # Start tag: colgroup
  defp do_process({:start_tag, "colgroup", attrs, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", attrs)
    |> set_mode(:in_column_group)
    |> ok()
  end

  # Start tag: col - per spec, clear to table context, insert a colgroup, switch to
  # "in column group", and reprocess
  defp do_process({:start_tag, "col", _, _}, state) do
    state
    |> clear_to_table_context()
    |> push_element("colgroup", [])
    |> set_mode(:in_column_group)
    |> reprocess()
  end

  # Start tags: tbody, thead, tfoot
  defp do_process({:start_tag, tag, attrs, _}, state) when tag in @table_sections do
    state
    |> clear_to_table_context()
    |> push_element(tag, attrs)
    |> set_mode(:in_table_body)
    |> ok()
  end

  # Start tags: td, th, tr - ensure tbody, reprocess
  defp do_process({:start_tag, tag, _, _}, state) when tag in ~w(td th tr) do
    state
    |> clear_to_table_context()
    |> push_element("tbody", [])
    |> set_mode(:in_table_body)
    |> reprocess()
  end

  # Start tag: nested table - parse error, close current table, reprocess
  defp do_process({:start_tag, "table", _, _}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> parse_error()
      |> close_table()
      |> reset_insertion_mode()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Start tags: style, script - process using in_head rules
  defp do_process({:start_tag, tag, _, _} = token, state) when tag in ~w(style script) do
    InHead.process(token, state)
  end

  # Start tag: template - process using in_head rules
  defp do_process({:start_tag, "template", _, _} = token, state) do
    InHead.process(token, state)
  end

  # "If the token does not have an attribute with the name 'type', or if it
  # does, but that attribute's value is not an ASCII case-insensitive match for
  # 'hidden', then act as described in the 'anything else' entry. Otherwise:
  # Parse error. Insert an HTML element for the token. Pop that input element."
  defp do_process({:start_tag, "input", attrs, _} = token, state) do
    attrs
    |> get_attr("type", "")
    |> String.downcase()
    |> table_input(token, state)
  end

  # "Parse error. If the form element pointer is not null, and the parser is
  # not parsing template contents, then ignore the token. Otherwise: insert an
  # HTML element for the token, and, if the parser is not parsing template
  # contents, set the form element pointer to point to the element created.
  # Pop that form element off the stack of open elements."
  defp do_process({:start_tag, "form", attrs, _}, state) do
    state
    |> parse_error()
    |> insert_table_form(attrs)
  end

  # Frameset/frame: per spec "Parse error." then in-body rules, which parse
  # error again and ignore the token (nothing is inserted, so no foster parenting).
  defp do_process({:start_tag, tag, _, _} = token, state)
       when tag in ["frameset", "frame"] do
    state
    |> parse_error()
    |> process_in_body(token)
  end

  # Other start tags: per spec "Parse error. Enable foster parenting, process
  # the token using the rules for the 'in body' insertion mode."
  defp do_process({:start_tag, _, _, _} = token, state), do: foster_in_body(state, token)

  # End tag: table
  # Per spec: "If the stack of open elements does not have a table element in table scope,
  # this is a parse error; ignore the token."
  defp do_process({:end_tag, "table"}, state) do
    if in_scope?(state, "table", :table) do
      state
      |> close_table()
      |> reset_insertion_mode()
      |> ok()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: template - process using in_head rules
  defp do_process({:end_tag, "template"} = token, state) do
    InHead.process(token, state)
  end

  # Ignored end tags: parse error, ignore
  defp do_process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # Other end tags, </br> included: per spec "Parse error. Enable foster
  # parenting, process the token using the rules for the 'in body' insertion
  # mode, and then disable foster parenting."
  defp do_process({:end_tag, _} = token, state), do: foster_in_body(state, token)

  # EOF: process using in_body rules
  defp do_process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers (in_table specific - general helpers imported from TreeBuilder.Helpers)
  # --------------------------------------------------------------------------

  defp table_input("hidden", {:start_tag, _, attrs, _}, state) do
    state
    |> parse_error()
    |> add_child_to_stack({"input", attrs, []})
    |> ok()
  end

  defp table_input(_type, token, state), do: foster_in_body(state, token)

  defp foster_in_body(state, token) do
    state
    |> parse_error()
    |> enable_foster_parenting()
    |> process_in_body(token)
  end

  defp do_process_character(%{tag: tag}, _text, state) when tag in @table_context do
    state
    |> start_table_text()
    |> reprocess()
  end

  # Anything else: parse error (one per character token), enable foster
  # parenting, process using the in body rules
  defp do_process_character(_, text, state) do
    state
    |> parse_error(String.length(text))
    |> enable_foster_parenting()
    |> process_in_body({:character, text})
  end

  # "Let the pending table character tokens be an empty list of tokens. Let the
  # original insertion mode be the current insertion mode. Switch the insertion
  # mode to in table text and reprocess the token."
  defp start_table_text(%{mode: mode} = state) do
    %{state | mode: :in_table_text, original_mode: mode, pending_table_text: ""}
  end

  # Clear stack to table context (table, template, html)
  @table_boundaries ["table", "template", "html"]

  defp clear_to_table_context(%{stack: stack, elements: elements} = state) do
    {new_stack, _parent_ref} = do_clear_to_table_context(stack, elements)
    %{state | stack: new_stack}
  end

  defp do_clear_to_table_context([], _elements), do: {[], nil}

  defp do_clear_to_table_context([ref | _rest] = stack, elements) do
    tag = elements[ref].tag

    if tag in @table_boundaries do
      # Found boundary, parent is the ref itself since we stay on it
      {stack, ref}
    else
      do_clear_to_table_context(tl(stack), elements)
    end
  end

  defp insert_table_form(%{form_element: nil} = state, attrs),
    do: insert_and_pop_form(state, attrs)

  defp insert_table_form(state, attrs) do
    if has_template_on_stack?(state) do
      insert_and_pop_form(state, attrs)
    else
      ok(state)
    end
  end

  defp insert_and_pop_form(state, attrs) do
    state
    |> push_element("form", attrs)
    |> point_form_element()
    |> pop_element()
    |> ok()
  end

  # "Pop elements from this stack until a table element has been popped from
  # the stack."
  defp close_table(state), do: pop_through(state, "table")
end
