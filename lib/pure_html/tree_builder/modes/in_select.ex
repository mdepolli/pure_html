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

  import PureHTML.TreeBuilder.Helpers,
    only: [
      push_element: 3,
      push_foreign_element: 4,
      add_child_to_stack: 2,
      add_text_to_stack: 2,
      pop_element: 1,
      close_select: 1,
      current_tag: 1,
      in_scope?: 3,
      find_ref: 2
    ]

  # Formatting elements that should be added to AF even in select mode
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

  # HTML breakout tags - these break out of foreign content
  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  # Table elements to ignore in in_select
  @table_elements_to_ignore ~w(caption table tbody tfoot thead tr td th)

  @impl true
  # Character tokens: insert
  def process({:character, text}, state) do
    # Null characters should be ignored, but we don't track that - just insert
    {:ok, add_text_to_stack(state, text)}
  end

  # Comments: insert
  def process({:comment, text}, state) do
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: html - process using in_body rules
  def process({:start_tag, "html", _, _}, state) do
    {:reprocess, %{state | mode: :in_body}}
  end

  # Start tag: option
  def process({:start_tag, "option", attrs, _}, state) do
    state =
      state
      |> close_current_option()
      |> push_element("option", attrs)

    {:ok, state}
  end

  # Start tag: optgroup
  def process({:start_tag, "optgroup", attrs, _}, state) do
    state =
      state
      |> close_current_option()
      |> close_current_optgroup()
      |> push_element("optgroup", attrs)

    {:ok, state}
  end

  # Start tag: select (nested) - parse error, close select
  def process({:start_tag, "select", _, _}, state) do
    if find_ref(state, "select") do
      {:ok, close_select(state)}
    else
      {:ok, state}
    end
  end

  # Start tag: input, textarea - close select, reprocess
  def process({:start_tag, tag, _, _}, state)
      when tag in ["input", "textarea"] do
    if in_scope?(state, "select", :select) do
      state = close_select(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # Start tag: keygen - insert as child of select (deprecated element)
  def process({:start_tag, "keygen", attrs, _}, state) do
    {:ok, add_child_to_stack(state, {"keygen", attrs, []})}
  end

  # Start tag: script - process using in_head rules, preserve original mode
  def process({:start_tag, "script", _, _}, state) do
    {:reprocess, %{state | original_mode: state.mode, mode: :in_head}}
  end

  # Start tag: template - process using in_head rules
  def process({:start_tag, "template", _, _}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Start tag: hr - close option/optgroup, insert void
  def process({:start_tag, "hr", attrs, _}, state) do
    state =
      state
      |> close_current_option()
      |> close_current_optgroup()
      |> add_child_to_stack({"hr", attrs, []})

    {:ok, state}
  end

  # Table elements in in_select: parse error, ignore per HTML5 spec
  def process({:start_tag, tag, _, _}, state) when tag in @table_elements_to_ignore do
    {:ok, state}
  end

  # SVG and Math - create namespaced elements
  def process({:start_tag, "svg", attrs, true}, state) do
    {:ok, add_child_to_stack(state, {{:svg, "svg"}, attrs, []})}
  end

  def process({:start_tag, "svg", attrs, false}, state) do
    {:ok, push_foreign_element(state, :svg, "svg", attrs)}
  end

  def process({:start_tag, "math", attrs, true}, state) do
    {:ok, add_child_to_stack(state, {{:math, "math"}, attrs, []})}
  end

  def process({:start_tag, "math", attrs, false}, state) do
    {:ok, push_foreign_element(state, :math, "math", attrs)}
  end

  # Any other start tag: insert (browsers insert elements for compatibility)
  def process({:start_tag, tag, attrs, self_closing}, state) do
    ns = foreign_namespace(state)

    # HTML breakout tags should not get foreign namespace
    ns = if ns && tag in @html_breakout_tags, do: nil, else: ns

    # Close foreign content when hitting a breakout tag
    state =
      if ns == nil && foreign_namespace(state) do
        close_foreign_content(state)
      else
        state
      end

    if self_closing do
      child =
        if ns do
          {{ns, tag}, attrs, []}
        else
          {tag, attrs, []}
        end

      {:ok, add_child_to_stack(state, child)}
    else
      new_state =
        if ns do
          push_foreign_element(state, ns, tag, attrs)
        else
          push_element(state, tag, attrs)
        end

      # Add formatting elements to AF for later reconstruction
      new_state =
        if tag in @formatting_elements do
          [new_ref | _] = new_state.stack
          new_af = [{new_ref, tag, attrs} | new_state.af]
          %{new_state | af: new_af}
        else
          new_state
        end

      {:ok, new_state}
    end
  end

  # End tag: optgroup
  def process({:end_tag, "optgroup"}, %{stack: [_, parent_ref | _], elements: elements} = state) do
    case {current_tag(state), elements[parent_ref].tag} do
      {"option", "optgroup"} ->
        {:ok, state |> pop_element() |> pop_element()}

      {"optgroup", _} ->
        {:ok, pop_element(state)}

      _ ->
        {:ok, state}
    end
  end

  def process({:end_tag, "optgroup"}, state) do
    if current_tag(state) == "optgroup", do: {:ok, pop_element(state)}, else: {:ok, state}
  end

  # End tag: option
  def process({:end_tag, "option"}, state) do
    if current_tag(state) == "option" do
      {:ok, pop_element(state)}
    else
      {:ok, state}
    end
  end

  # End tag: select
  def process({:end_tag, "select"}, state) do
    if in_scope?(state, "select", :select) do
      {:ok, close_select(state)}
    else
      {:ok, state}
    end
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Any other end tag: handle foreign content, otherwise ignore
  def process({:end_tag, tag}, state) do
    case foreign_namespace(state) do
      nil ->
        # Not in foreign content - ignore per spec
        {:ok, state}

      ns ->
        # In foreign content - close if matches current element
        {:ok, close_foreign_element(state, ns, tag)}
    end
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Close current option if on top of stack
  defp close_current_option(state) do
    close_if_current_tag(state, "option")
  end

  # Close current optgroup if on top of stack
  defp close_current_optgroup(state) do
    close_if_current_tag(state, "optgroup")
  end

  defp close_if_current_tag(state, tag) do
    if current_tag(state) == tag, do: pop_element(state), else: state
  end

  # Get the current foreign namespace (if we're inside SVG or MathML)
  defp foreign_namespace(%{stack: stack, elements: elements}) do
    Enum.find_value(stack, fn ref ->
      case elements[ref] do
        %{tag: {ns, _}} when ns in [:svg, :math] -> ns
        _ -> nil
      end
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
