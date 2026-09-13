defmodule PureHTML.TreeBuilder.SelectedContent do
  @moduledoc """
  The customizable select's `selectedcontent` mirroring, replayed after
  parsing.

  This is not a rule of the tree construction algorithm. The forms chapter of
  the standard defines "update a select's selectedcontent": when an option
  becomes selected, the select's selectedcontent element has its contents
  replaced with a clone of the option's children. A browser runs it from the
  DOM insertion steps while the parser inserts nodes, so the resulting tree
  shows the cloned content; this module produces the same tree once the
  parse is complete.

  See: https://html.spec.whatwg.org/multipage/form-elements.html#update-a-select's-selectedcontent
  """

  @doc """
  Replays "update a select's selectedcontent" over the finished tree: each
  select's selectedcontent element receives a clone of the children of its
  selected option, or of its first option.
  """
  def populate(tree), do: transform_tree(tree, &maybe_populate_select/1)

  defp transform_tree(%{children: children} = node, transform) do
    transformed_children = Enum.map(children, &transform_tree(&1, transform))
    transform.(%{node | children: transformed_children})
  end

  defp transform_tree(other, _transform), do: other

  defp maybe_populate_select(%{tag: "select", children: children} = select) do
    case find_selectedcontent_and_options(children) do
      {nil, _} ->
        select

      {selectedcontent_path, options} ->
        # Find content to clone: selected option, or first option
        option_content = get_option_content(options)
        # Clone content to selectedcontent
        new_children =
          set_selectedcontent_children(children, selectedcontent_path, option_content)

        %{select | children: new_children}
    end
  end

  defp maybe_populate_select(node), do: node

  # Find selectedcontent element path and collect options
  defp find_selectedcontent_and_options(children) do
    find_selectedcontent_and_options(children, [], [])
  end

  defp find_selectedcontent_and_options([], _path, options) do
    {nil, Enum.reverse(options)}
  end

  defp find_selectedcontent_and_options([%{tag: "selectedcontent"} | rest], _path, options) do
    {[0], Enum.reverse(options) ++ collect_options(rest)}
  end

  defp find_selectedcontent_and_options([%{tag: "option"} = opt | rest], path, options) do
    find_selectedcontent_and_options(rest, path, [opt | options])
  end

  defp find_selectedcontent_and_options(
         [%{tag: "button", children: button_children} | rest],
         path,
         options
       ) do
    case find_in_button(button_children, 0) do
      {:found, idx} ->
        all_options = Enum.reverse(options) ++ collect_options(rest)
        {[length(path), idx], all_options}

      :not_found ->
        find_selectedcontent_and_options(rest, path, options)
    end
  end

  defp find_selectedcontent_and_options([_ | rest], path, options) do
    find_selectedcontent_and_options(rest, path, options)
  end

  defp find_in_button([], _idx), do: :not_found

  defp find_in_button([%{tag: "selectedcontent"} | _], idx), do: {:found, idx}
  defp find_in_button([_ | rest], idx), do: find_in_button(rest, idx + 1)

  defp collect_options(children) do
    Enum.filter(children, &match?(%{tag: "option"}, &1))
  end

  defp get_option_content([]), do: []

  defp get_option_content(options) do
    # Find option with selected attribute, or use first option
    selected =
      Enum.find(options, fn %{attrs: attrs} -> List.keymember?(attrs, "selected", 0) end)

    option = selected || hd(options)
    option.children
  end

  defp set_selectedcontent_children(children, [button_idx, sc_idx], content) do
    List.update_at(children, button_idx, fn button ->
      new_button_children =
        List.update_at(button.children, sc_idx, fn sc ->
          %{sc | children: content}
        end)

      %{button | children: new_button_children}
    end)
  end

  defp set_selectedcontent_children(children, [sc_idx], content) do
    List.update_at(children, sc_idx, fn sc ->
      %{sc | children: content}
    end)
  end

  defp set_selectedcontent_children(children, _, _), do: children
end
