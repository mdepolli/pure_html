defmodule PureHTML.TreeBuilder.SelectedContent do
  @moduledoc """
  The customizable select's `selectedcontent` mirroring, replayed after
  parsing.

  This is not a rule of the tree construction algorithm. The forms chapter of
  the standard updates selectedcontent elements from the DOM insertion steps
  and when the parser pops an option, so the tree a browser ends up with shows
  the clone. This module produces that tree once the parse is complete, with
  the forms chapter's definitions as fetched on 2026-10-11:

  - a selectedcontent is enabled when its nearest select ancestor is its only
    select ancestor and no option or selectedcontent is among its ancestors
    ("recalculate a selectedcontent element's disabledness");
  - every enabled selectedcontent descendant of a select without `multiple`
    is updated ("update a select's descendant selectedcontent elements");
  - the list of options is the option descendants of the select in tree
    order, not descending into select, hr, option, datalist, or a nested
    optgroup;
  - selectedness starts from the `selected` attribute, then the selectedness
    setting algorithm: without `multiple`, all but the last selected option
    lose selectedness, and with display size 1 and nothing selected the first
    non-disabled option is selected;
  - the first selected option's children are cloned into the selectedcontent,
    or it is cleared when none is selected;
  - a template's children are its contents, a separate fragment, so neither
    the ancestor walk nor the list of options crosses into them.

  See: https://html.spec.whatwg.org/multipage/form-elements.html#update-a-select's-descendant-selectedcontent-elements
  """

  @doc "Replays the selectedcontent updates over a finished tree or fragment child."
  def populate(tree), do: mirror(tree, [], nil)

  # Walks the tree top-down with the node's ancestor tags, nearest first, and
  # the nearest select's content: the selected option's children, or :none
  # when that select has `multiple`.
  defp mirror(%{tag: "select", children: children} = select, ancestors, _content) do
    content = select_content(select)
    %{select | children: Enum.map(children, &mirror(&1, ["select" | ancestors], content))}
  end

  # Template contents are not descendants: their ancestors start afresh.
  defp mirror(%{tag: "template", children: children} = template, _ancestors, _content) do
    %{template | children: Enum.map(children, &mirror(&1, [], nil))}
  end

  defp mirror(%{tag: "selectedcontent"} = selectedcontent, ancestors, content) do
    ancestors
    |> disabled?()
    |> mirror_selectedcontent(selectedcontent, ancestors, content)
  end

  defp mirror(%{tag: tag, children: children} = node, ancestors, content) do
    %{node | children: Enum.map(children, &mirror(&1, [tag | ancestors], content))}
  end

  defp mirror(other, _ancestors, _content), do: other

  # Disabled unless exactly one select is an ancestor and no option or
  # selectedcontent is.
  defp disabled?(ancestors) do
    Enum.count(ancestors, &(&1 == "select")) != 1 or
      Enum.any?(ancestors, &(&1 in ~w(option selectedcontent)))
  end

  defp mirror_selectedcontent(false, node, _ancestors, content) when is_list(content) do
    %{node | children: content}
  end

  defp mirror_selectedcontent(_disabled?, %{children: children} = node, ancestors, content) do
    walked = Enum.map(children, &mirror(&1, ["selectedcontent" | ancestors], content))
    %{node | children: walked}
  end

  defp select_content(select) do
    if has_attr?(select, "multiple"), do: :none, else: selected_option_children(select)
  end

  # The first option whose selectedness is true, after the selectedness
  # setting algorithm; its children are the clone, none clears the element.
  defp selected_option_children(select) do
    select
    |> list_of_options()
    |> apply_selectedness(select)
    |> Enum.find_value([], fn
      {option, true} -> option.children
      {_option, false} -> nil
    end)
  end

  # "Get the list of options": option descendants in tree order, without
  # descending into select, hr, option, datalist, or an optgroup inside an
  # optgroup. Template contents are not descendants. Each option carries its
  # disabled state, which its own attribute or its optgroup's sets.
  defp list_of_options(select), do: collect_options(select.children, nil)

  defp collect_options(children, optgroup) do
    Enum.flat_map(children, &options_of(&1, optgroup))
  end

  defp options_of(%{tag: "option"} = option, optgroup) do
    disabled? =
      has_attr?(option, "disabled") or (optgroup != nil and has_attr?(optgroup, "disabled"))

    [{option, disabled?}]
  end

  defp options_of(%{tag: tag}, _optgroup) when tag in ~w(select hr datalist template), do: []
  defp options_of(%{tag: "optgroup"}, optgroup) when optgroup != nil, do: []
  defp options_of(%{tag: "optgroup"} = node, nil), do: collect_options(node.children, node)
  defp options_of(%{children: children}, optgroup), do: collect_options(children, optgroup)
  defp options_of(_text_or_comment, _optgroup), do: []

  # Selectedness from the `selected` attribute, then the selectedness setting
  # algorithm for a select without `multiple` (the enabled selectedcontent
  # already ruled `multiple` out): keep only the last selected option, and
  # with display size 1 and none selected, select the first non-disabled one.
  defp apply_selectedness(options, select) do
    options
    |> Enum.map(fn {option, disabled?} -> {option, disabled?, has_attr?(option, "selected")} end)
    |> keep_last_selected()
    |> select_first_enabled_if_none(display_size(select))
    |> Enum.map(fn {option, _disabled?, selected?} -> {option, selected?} end)
  end

  # Walk from the end: the first selected option seen stays selected, every
  # earlier one loses its selectedness.
  defp keep_last_selected(options) do
    options
    |> Enum.reverse()
    |> Enum.map_reduce(false, fn {option, disabled?, selected?}, seen? ->
      {{option, disabled?, selected? and not seen?}, seen? or selected?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp select_first_enabled_if_none(options, 1) do
    if Enum.any?(options, fn {_, _, s?} -> s? end) do
      options
    else
      select_first_enabled(options)
    end
  end

  defp select_first_enabled_if_none(options, _size), do: options

  defp select_first_enabled([]), do: []
  defp select_first_enabled([{option, false, _} | rest]), do: [{option, false, true} | rest]
  defp select_first_enabled([entry | rest]), do: [entry | select_first_enabled(rest)]

  # "The display size": the size attribute parsed as a non-negative integer,
  # else 4 with `multiple` and 1 otherwise.
  defp display_size(select) do
    case attr(select, "size") do
      nil -> 1
      value -> parse_non_negative_integer(value) || 1
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(String.trim_leading(value)) do
      {n, _rest} when n >= 0 -> n
      _ -> nil
    end
  end

  defp attr(%{attrs: attrs}, name) do
    case List.keyfind(attrs, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp has_attr?(%{attrs: attrs}, name), do: List.keymember?(attrs, name, 0)
end
