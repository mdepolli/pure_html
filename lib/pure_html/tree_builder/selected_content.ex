defmodule PureHTML.TreeBuilder.SelectedContent do
  @moduledoc """
  The customizable select's `selectedcontent` mirroring, replayed after
  parsing.

  This is not a rule of the tree construction algorithm. The forms chapter of
  the standard runs "update a select's selectedcontent" from the DOM insertion
  steps as the parser inserts nodes, so the tree a browser ends up with shows
  the clone. This module produces that tree once the parse is complete, with
  the forms chapter's definitions as fetched on 2026-09-15:

  - a select's enabled selectedcontent is its first selectedcontent
    descendant in tree order, unless the select has `multiple` or that
    selectedcontent is disabled (it sits under a nested select, an option, or
    another selectedcontent);
  - the list of options is the option descendants of the select in tree
    order, not descending into select, hr, option, datalist, or a nested
    optgroup;
  - selectedness starts from the `selected` attribute, then the selectedness
    setting algorithm: without `multiple`, all but the last selected option
    lose selectedness, and with display size 1 and nothing selected the first
    non-disabled option is selected;
  - the first selected option's children are cloned into the selectedcontent,
    or it is cleared when none is selected.

  See: https://html.spec.whatwg.org/multipage/form-elements.html#update-a-select's-selectedcontent
  """

  @doc "Replays \"update a select's selectedcontent\" over the finished tree."
  def populate(tree), do: transform_tree(tree, &update_selectedcontent/1)

  defp transform_tree(%{children: children} = node, transform) do
    transformed_children = Enum.map(children, &transform_tree(&1, transform))
    transform.(%{node | children: transformed_children})
  end

  defp transform_tree(other, _transform), do: other

  defp update_selectedcontent(%{tag: "select"} = select) do
    if enabled_selectedcontent?(select) do
      content = selected_option_children(select)
      %{select | children: replace_selectedcontent(select.children, content)}
    else
      select
    end
  end

  defp update_selectedcontent(node), do: node

  # "Get a select's enabled selectedcontent": null with `multiple`, null
  # without a selectedcontent descendant, null when that descendant is
  # disabled. A selectedcontent is disabled when an option, a selectedcontent,
  # or a second select lies between it and its select.
  defp enabled_selectedcontent?(select) do
    not has_attr?(select, "multiple") and
      case first_selectedcontent(select.children, []) do
        nil -> false
        ancestors -> not Enum.any?(ancestors, &(&1 in ~w(select option selectedcontent)))
      end
  end

  defp first_selectedcontent([], _ancestors), do: nil

  defp first_selectedcontent([%{tag: "selectedcontent"} | _rest], ancestors), do: ancestors

  defp first_selectedcontent([%{tag: tag, children: children} | rest], ancestors) do
    first_selectedcontent(children, [tag | ancestors]) || first_selectedcontent(rest, ancestors)
  end

  defp first_selectedcontent([_other | rest], ancestors),
    do: first_selectedcontent(rest, ancestors)

  defp replace_selectedcontent([], _content), do: []

  defp replace_selectedcontent([%{tag: "selectedcontent"} = sc | rest], content) do
    [%{sc | children: content} | rest]
  end

  defp replace_selectedcontent([%{children: children} = node | rest], content) do
    if first_selectedcontent(children, []) == nil do
      [node | replace_selectedcontent(rest, content)]
    else
      [%{node | children: replace_selectedcontent(children, content)} | rest]
    end
  end

  defp replace_selectedcontent([other | rest], content) do
    [other | replace_selectedcontent(rest, content)]
  end

  # The first option whose selectedness is true, after the selectedness
  # setting algorithm; its children are the clone, none clears the element.
  defp selected_option_children(select) do
    select
    |> list_of_options()
    |> apply_selectedness(select)
    |> Enum.find(fn {_option, selected?} -> selected? end)
    |> case do
      {option, true} -> option.children
      nil -> []
    end
  end

  # "Get the list of options": option descendants in tree order, without
  # descending into select, hr, option, datalist, or an optgroup inside an
  # optgroup. Each option carries its disabled state, which its own attribute
  # or its optgroup's sets.
  defp list_of_options(select), do: collect_options(select.children, nil)

  defp collect_options(children, optgroup) do
    Enum.flat_map(children, &options_of(&1, optgroup))
  end

  defp options_of(%{tag: "option"} = option, optgroup) do
    disabled? =
      has_attr?(option, "disabled") or (optgroup != nil and has_attr?(optgroup, "disabled"))

    [{option, disabled?}]
  end

  defp options_of(%{tag: tag}, _optgroup) when tag in ~w(select hr datalist), do: []
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
