defmodule PureHTML.TreeBuilder.Modes.InSelect do
  @moduledoc """
  HTML5 "in select" insertion mode.

  This mode handles content inside a <select> element.

  Per HTML5 spec:
  - Character tokens: insert
  - Comments: insert
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules
    - option: close current option if any, insert option
    - optgroup: close current option/optgroup if any, insert optgroup
    - select: parse error, close select (nested select)
    - input/keygen/textarea: parse error, close select, reprocess
    - script/template: process using "in head" rules
    - hr: close option/optgroup, insert void element
    - Anything else: parse error, IGNORE
  - End tags:
    - optgroup: pop if current is optgroup (with option handling)
    - option: pop if current is option
    - select: pop elements to select, switch mode
    - template: process using "in head" rules
    - Anything else: parse error, ignore

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inselect
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder.AdoptionAgency

  # Formatting elements that should be added to AF even in select mode
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

  # HTML breakout tags - these break out of foreign content
  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  # Table elements to ignore in in_select
  @table_elements_to_ignore ~w(caption table tbody tfoot thead tr td th)

  # Void elements (always treated as self-closing)
  @void_elements ~w(area base br col embed hr img input link meta source track wbr)

  @impl true
  # Character tokens: reconstruct active formatting, then insert
  def process({:character, text}, state) do
    # Null characters should be ignored, but we don't track that - just insert
    state
    |> reconstruct_af_in_select()
    |> add_text_to_stack(text)
    |> ok()
  end

  # Comments: insert
  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  # Start tag: html - process using in_body rules
  def process({:start_tag, "html", _, _}, state) do
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

  # Start tag: option
  def process({:start_tag, "option", attrs, _}, state) do
    state
    |> close_current_option()
    |> push_element("option", attrs)
    |> ok()
  end

  # Start tag: optgroup
  def process({:start_tag, "optgroup", attrs, _}, state) do
    state
    |> close_current_option()
    |> close_current_optgroup()
    |> push_element("optgroup", attrs)
    |> ok()
  end

  # Start tag: select (nested) - parse error, close select
  def process({:start_tag, "select", _, _}, state) do
    state
    |> parse_error()
    |> close_nested_select()
  end

  # Start tag: input, textarea - parse error, close select, reprocess
  def process({:start_tag, tag, _, _}, state)
      when tag in ["input", "textarea"] do
    state
    |> parse_error()
    |> close_select_if_in_select_scope()
  end

  # Start tag: keygen - insert as child of select (deprecated element)
  def process({:start_tag, "keygen", attrs, _}, state) do
    state
    |> add_child_to_stack({"keygen", attrs, []})
    |> ok()
  end

  # Start tag: script - process using in_head rules, preserve original mode
  def process({:start_tag, "script", _, _}, state) do
    state
    |> Map.put(:original_mode, state.mode)
    |> set_mode(:in_head)
    |> reprocess()
  end

  # Start tag: template - process using in_head rules
  def process({:start_tag, "template", _, _}, state) do
    state
    |> set_mode(:in_head)
    |> reprocess()
  end

  # Start tag: hr - close option/optgroup, insert void
  def process({:start_tag, "hr", attrs, _}, state) do
    state
    |> close_current_option()
    |> close_current_optgroup()
    |> add_child_to_stack({"hr", attrs, []})
    |> ok()
  end

  # Table elements in in_select: parse error, ignore per HTML5 spec
  # Note: in_select_in_table mode handles these differently (closes select)
  def process({:start_tag, tag, _, _}, state) when tag in @table_elements_to_ignore do
    state
    |> parse_error()
    |> ok()
  end

  # SVG and Math - create namespaced elements
  def process({:start_tag, "svg", attrs, true}, state) do
    state
    |> add_child_to_stack({{:svg, "svg"}, attrs, []})
    |> ok()
  end

  def process({:start_tag, "svg", attrs, false}, state) do
    state
    |> push_foreign_element(:svg, "svg", attrs)
    |> ok()
  end

  def process({:start_tag, "math", attrs, true}, state) do
    state
    |> add_child_to_stack({{:math, "math"}, attrs, []})
    |> ok()
  end

  def process({:start_tag, "math", attrs, false}, state) do
    state
    |> push_foreign_element(:math, "math", attrs)
    |> ok()
  end

  # Any other start tag: per spec "Parse error."
  def process({:start_tag, tag, attrs, self_closing}, state) do
    state
    |> parse_error()
    |> insert_other_element(tag, attrs, self_closing)
  end

  # End tag: optgroup
  # Per spec: "If the current node is an option whose parent is an optgroup, pop both."
  # "If the current node is an optgroup, pop."
  # "Otherwise, parse error; ignore."
  def process({:end_tag, "optgroup"}, %{stack: [_, parent_ref | _], elements: elements} = state) do
    state
    |> current_tag()
    |> end_optgroup_with_parent(elements[parent_ref].tag, state)
  end

  # End tag: optgroup (fallback - single element stack)
  def process({:end_tag, "optgroup"}, state) do
    state
    |> current_tag()
    |> end_optgroup(state)
  end

  # End tag: option
  # Per spec: "If the current node is an option element, pop. Otherwise, parse error; ignore."
  def process({:end_tag, "option"}, state) do
    state
    |> current_tag()
    |> end_option(state)
  end

  # End tag: select
  # Per spec: "If not in select scope, parse error; ignore."
  def process({:end_tag, "select"}, state) do
    state
    |> in_scope?("select", :select)
    |> end_select(state)
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    state
    |> set_mode(:in_head)
    |> reprocess()
  end

  # End tag for formatting elements: parse error, use adoption agency if element is inside select
  def process({:end_tag, tag}, state) when tag in @formatting_elements do
    if formatting_element_in_select?(state, tag) do
      # Run adoption agency for formatting elements inside select
      state
      |> parse_error()
      |> AdoptionAgency.run(tag, &close_formatting_in_select/2)
      |> ok()
    else
      # Formatting element is outside select - ignore
      state
      |> parse_error()
      |> ok()
    end
  end

  # Any other end tag: parse error, handle foreign content or close matching HTML element
  def process({:end_tag, tag}, state) do
    state
    |> parse_error()
    |> close_element_in_select(tag)
  end

  # EOF: process using "in body" rules
  def process(:eof, state) do
    state
    |> set_mode(:in_body)
    |> reprocess()
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp insert_other_element(state, tag, attrs, self_closing) do
    state
    |> foreign_namespace()
    |> insert_in_namespace(tag, attrs, self_closing, state)
  end

  # HTML breakout tag inside foreign content: close the foreign content first
  defp insert_in_namespace(ns, tag, attrs, self_closing, state)
       when ns != nil and tag in @html_breakout_tags do
    state
    |> close_foreign_content()
    |> insert_element_in_select(nil, tag, attrs, self_closing)
    |> ok()
  end

  defp insert_in_namespace(ns, tag, attrs, self_closing, state) do
    state
    |> insert_element_in_select(ns, tag, attrs, self_closing)
    |> ok()
  end

  # Insert element, handling void/self-closing vs regular elements
  defp insert_element_in_select(state, ns, tag, attrs, self_closing)
       when self_closing or tag in @void_elements do
    add_child_to_stack(state, build_child_node(ns, tag, attrs))
  end

  defp insert_element_in_select(state, ns, tag, attrs, _self_closing) do
    push_element_in_select(state, ns, tag, attrs)
  end

  defp build_child_node(nil, tag, attrs), do: {tag, attrs, []}
  defp build_child_node(ns, tag, attrs), do: {{ns, tag}, attrs, []}

  defp push_element_in_select(state, nil, tag, attrs) do
    state
    |> push_element(tag, attrs)
    |> maybe_add_formatting_entry(tag, attrs)
  end

  defp push_element_in_select(state, ns, tag, attrs) do
    state
    |> push_foreign_element(ns, tag, attrs)
    |> maybe_add_formatting_entry(tag, attrs)
  end

  defp maybe_add_formatting_entry(%{stack: [new_ref | _], af: af} = state, tag, attrs)
       when tag in @formatting_elements do
    %{state | af: [{new_ref, tag, attrs} | af]}
  end

  defp maybe_add_formatting_entry(state, _tag, _attrs), do: state

  # Close current option if on top of stack
  defp close_select_if_in_select_scope(state) do
    state
    |> in_scope?("select", :select)
    |> reprocess_after_close_select(state)
  end

  defp reprocess_after_close_select(true, state) do
    state
    |> close_select()
    |> reprocess()
  end

  defp reprocess_after_close_select(false, state), do: ok(state)

  defp end_select(true, state) do
    state
    |> close_select()
    |> ok()
  end

  defp end_select(false, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp close_nested_select(state) do
    state
    |> find_ref("select")
    |> pop_select_if_found(state)
  end

  defp pop_select_if_found(nil, state), do: ok(state)

  defp pop_select_if_found(_ref, state) do
    state
    |> close_select()
    |> ok()
  end

  defp close_element_in_select(state, tag) do
    state
    |> foreign_namespace()
    |> close_element_in_namespace(tag, state)
  end

  # Not in foreign content - try to close matching HTML element
  # This handles cases where elements like <div> were pushed for compatibility
  defp close_element_in_namespace(nil, tag, state) do
    state
    |> close_html_element_in_select(tag)
    |> ok()
  end

  # In foreign content - close if matches current element
  defp close_element_in_namespace(ns, tag, state) do
    state
    |> close_foreign_element(ns, tag)
    |> ok()
  end

  defp end_optgroup_with_parent("option", "optgroup", state) do
    state
    |> pop_element()
    |> pop_element()
    |> ok()
  end

  defp end_optgroup_with_parent("optgroup", _parent, state) do
    state
    |> pop_element()
    |> ok()
  end

  defp end_optgroup_with_parent(_tag, _parent, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp end_optgroup("optgroup", state) do
    state
    |> pop_element()
    |> ok()
  end

  defp end_optgroup(_tag, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp end_option("option", state) do
    state
    |> pop_element()
    |> ok()
  end

  defp end_option(_tag, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp close_current_option(state) do
    close_if_current_tag(state, "option")
  end

  # Close current optgroup if on top of stack
  defp close_current_optgroup(state) do
    close_if_current_tag(state, "optgroup")
  end

  defp close_if_current_tag(state, tag) do
    state
    |> current_tag()
    |> pop_if_tag(tag, state)
  end

  defp pop_if_tag(tag, tag, state), do: pop_element(state)
  defp pop_if_tag(_current, _tag, state), do: state

  # Check if a formatting element is inside select (on stack above select)
  defp formatting_element_in_select?(%{stack: stack, elements: elements}, tag) do
    # Walk stack from top until we hit select - if we find the tag, it's inside
    Enum.reduce_while(stack, false, fn ref, _acc ->
      case elements[ref].tag do
        "select" -> {:halt, false}
        ^tag -> {:halt, true}
        _ -> {:cont, false}
      end
    end)
  end

  # Close callback for adoption agency - stops at select boundary
  defp close_formatting_in_select(%{stack: stack, elements: elements} = state, tag) do
    case pop_until_html_tag_in_select(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  # Close an HTML element that was pushed inside select (for browser compatibility)
  # Pops elements until finding the matching tag, stops at select boundary
  defp close_html_element_in_select(%{stack: stack, elements: elements, af: af} = state, tag) do
    case pop_until_html_tag_in_select(stack, elements, tag) do
      {:found, new_stack, parent_ref} ->
        # Update state with new stack
        new_state = %{state | stack: new_stack, current_parent_ref: parent_ref}
        # Reconstruct active formatting elements
        reconstruct_af_in_select(new_state, af, new_stack)

      :not_found ->
        state
    end
  end

  defp pop_until_html_tag_in_select([], _elements, _tag), do: :not_found

  defp pop_until_html_tag_in_select([ref | rest], elements, tag) do
    case elements[ref].tag do
      ^tag ->
        {:found, rest, elements[ref].parent_ref}

      "select" ->
        # Don't pop past select
        :not_found

      _ ->
        pop_until_html_tag_in_select(rest, elements, tag)
    end
  end

  # Reconstruct active formatting elements after closing an element
  # Reconstruct active formatting elements in select mode
  # Only reconstructs elements that are inside select (above select in AF)
  defp reconstruct_af_in_select(%{af: af, stack: stack} = state) do
    reconstruct_af_in_select(state, af, stack)
  end

  defp reconstruct_af_in_select(state, af, stack) do
    entries_to_reconstruct =
      af
      |> Enum.take_while(&(&1 != :marker))
      |> Enum.reverse()
      |> Enum.filter(fn {ref, _tag, _attrs} -> ref not in stack end)

    Enum.reduce(entries_to_reconstruct, state, fn {_old_ref, tag, attrs}, acc ->
      new_state = push_element(acc, tag, attrs)
      [new_ref | _] = new_state.stack

      new_af = [
        {new_ref, tag, attrs}
        | Enum.reject(new_state.af, fn
            {_, ^tag, ^attrs} -> true
            _ -> false
          end)
      ]

      %{new_state | af: new_af}
    end)
  end

  # Close all foreign content elements (pop until we hit an HTML element)
  defp close_foreign_content(%{stack: stack, elements: elements} = state) do
    {new_stack, parent_ref} = pop_foreign_elements(stack, elements)
    %{state | stack: new_stack, current_parent_ref: parent_ref}
  end

  defp pop_foreign_elements([], _elements), do: {[], nil}

  defp pop_foreign_elements([ref | rest] = stack, elements) do
    case elements[ref].tag do
      {ns, _} when ns in [:svg, :math] ->
        pop_foreign_elements(rest, elements)

      _ ->
        {stack, ref}
    end
  end

  # Close a foreign element by tag name
  # Walks up the stack looking for matching foreign element
  defp close_foreign_element(%{stack: stack, elements: elements} = state, ns, tag) do
    case pop_until_foreign_tag(stack, elements, ns, tag) do
      {:found, new_stack, parent_ref} ->
        %{state | stack: new_stack, current_parent_ref: parent_ref}

      :not_found ->
        state
    end
  end

  defp pop_until_foreign_tag([], _elements, _ns, _tag), do: :not_found

  defp pop_until_foreign_tag([ref | rest], elements, ns, tag) do
    case elements[ref] do
      %{tag: {^ns, ^tag}, parent_ref: parent_ref} ->
        {:found, rest, parent_ref}

      %{tag: {^ns, _}} ->
        # Keep looking in same namespace
        pop_until_foreign_tag(rest, elements, ns, tag)

      _ ->
        # Hit non-foreign element, stop
        :not_found
    end
  end
end
