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
  def process({:start_tag, "select", _, _}, %{stack: stack} = state) do
    if has_select_in_scope?(stack) do
      {:ok, close_select(state)}
    else
      {:ok, state}
    end
  end

  # Start tag: input, keygen, textarea - close select, reprocess
  def process({:start_tag, tag, _, _}, %{stack: stack} = state)
      when tag in ["input", "keygen", "textarea"] do
    if has_select_in_scope?(stack) do
      state = close_select(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # Start tag: script, template - process using in_head rules
  def process({:start_tag, tag, _, _}, state) when tag in ["script", "template"] do
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

  # Table structure elements: close select and reprocess
  @table_elements ~w(caption table tbody tfoot thead tr td th)

  def process({:start_tag, tag, _, _}, %{stack: stack} = state)
      when tag in @table_elements do
    if has_select_in_scope?(stack) do
      state = close_select(state)
      {:reprocess, state}
    else
      {:ok, state}
    end
  end

  # SVG and Math - create namespaced elements
  def process({:start_tag, "svg", attrs, self_closing}, state) do
    {:ok, push_foreign_element(state, :svg, "svg", attrs, self_closing)}
  end

  def process({:start_tag, "math", attrs, self_closing}, state) do
    {:ok, push_foreign_element(state, :math, "math", attrs, self_closing)}
  end

  # Any other start tag: insert (browsers don't strictly follow spec here)
  def process({:start_tag, tag, attrs, self_closing}, state) do
    if self_closing do
      {:ok, add_child_to_stack(state, {tag, attrs, []})}
    else
      {:ok, push_element(state, tag, attrs)}
    end
  end

  # End tag: optgroup
  def process({:end_tag, "optgroup"}, %{stack: stack} = state) do
    case stack do
      # Current is option, parent is optgroup: pop option, then pop optgroup
      [%{tag: "option"} = option, %{tag: "optgroup"} = optgroup | rest] ->
        rest = add_child(rest, %{optgroup | children: [option | optgroup.children]})
        {:ok, %{state | stack: rest}}

      # Current is optgroup: pop it
      [%{tag: "optgroup"} = optgroup | rest] ->
        {:ok, %{state | stack: add_child(rest, optgroup)}}

      # Otherwise ignore
      _ ->
        {:ok, state}
    end
  end

  # End tag: option
  def process({:end_tag, "option"}, %{stack: stack} = state) do
    case stack do
      [%{tag: "option"} = option | rest] ->
        {:ok, %{state | stack: add_child(rest, option)}}

      _ ->
        {:ok, state}
    end
  end

  # End tag: select
  def process({:end_tag, "select"}, %{stack: stack} = state) do
    if has_select_in_scope?(stack) do
      {:ok, close_select(state)}
    else
      {:ok, state}
    end
  end

  # End tag: template - process using in_head rules
  def process({:end_tag, "template"}, state) do
    {:reprocess, %{state | mode: :in_head}}
  end

  # Any other end tag: parse error, ignore
  def process({:end_tag, _}, state) do
    {:ok, state}
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  defp new_foreign_element(ns, tag, attrs) do
    %{ref: make_ref(), tag: {ns, tag}, attrs: attrs, children: []}
  end

  defp push_element(%{stack: stack} = state, tag, attrs) do
    %{state | stack: [new_element(tag, attrs) | stack]}
  end

  defp push_foreign_element(%{stack: stack} = state, ns, tag, attrs, true) do
    # Self-closing: add as child, not on stack
    %{state | stack: add_child(stack, {{ns, tag}, attrs, []})}
  end

  defp push_foreign_element(%{stack: stack} = state, ns, tag, attrs, _) do
    %{state | stack: [new_foreign_element(ns, tag, attrs) | stack]}
  end

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

  defp add_child([], _child), do: []

  # Close current option if on top of stack
  defp close_current_option(%{stack: [%{tag: "option"} = option | rest]} = state) do
    %{state | stack: add_child(rest, option)}
  end

  defp close_current_option(state), do: state

  # Close current optgroup if on top of stack
  defp close_current_optgroup(%{stack: [%{tag: "optgroup"} = optgroup | rest]} = state) do
    %{state | stack: add_child(rest, optgroup)}
  end

  defp close_current_optgroup(state), do: state

  # Check if select is in select scope
  defp has_select_in_scope?(stack), do: do_has_select_in_scope?(stack)

  defp do_has_select_in_scope?([%{tag: "select"} | _]), do: true
  defp do_has_select_in_scope?([%{tag: "template"} | _]), do: false
  defp do_has_select_in_scope?([_ | rest]), do: do_has_select_in_scope?(rest)
  defp do_has_select_in_scope?([]), do: false

  # Close select and pop mode
  defp close_select(%{stack: stack} = state) do
    new_stack = close_to_select(stack)
    pop_mode(%{state | stack: new_stack})
  end

  defp close_to_select([%{tag: "select"} = select | rest]) do
    add_child(rest, select)
  end

  defp close_to_select([elem | rest]) do
    close_to_select(add_child(rest, elem))
  end

  defp close_to_select([]), do: []

  # Pop mode from template mode stack
  defp pop_mode(%{template_mode_stack: [prev_mode | rest]} = state) do
    %{state | mode: prev_mode, template_mode_stack: rest}
  end

  defp pop_mode(%{template_mode_stack: []} = state) do
    %{state | mode: :in_body}
  end
end
