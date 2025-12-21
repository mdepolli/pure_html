defmodule PureHtml.Document do
  @moduledoc false

  defstruct [:nodes, :by_tag, :by_id, :by_class, :root_id, :next_id, :doctype, :before_html, :template_contents]

  def new do
    %__MODULE__{
      nodes: %{},
      by_tag: %{},
      by_id: %{},
      by_class: %{},
      root_id: nil,
      next_id: 0,
      doctype: nil,
      before_html: [],
      template_contents: %{}
    }
  end

  def add_comment_before_html(doc, content) do
    id = doc.next_id
    node = %{type: :comment, id: id, content: content, parent_id: nil}
    nodes = Map.put(doc.nodes, id, node)
    %{doc | nodes: nodes, next_id: id + 1, before_html: [id | doc.before_html]}
  end

  def set_doctype(doc, name, public_id, system_id) do
    %{doc | doctype: %{name: name, public_id: public_id, system_id: system_id}}
  end

  def add_element(doc, tag, attrs, parent_id, namespace \\ nil) do
    id = doc.next_id

    node = %{
      type: :element,
      id: id,
      tag: tag,
      attrs: attrs,
      parent_id: parent_id,
      children_ids: [],
      namespace: namespace
    }

    nodes = Map.put(doc.nodes, id, node)
    nodes = add_to_parent(nodes, parent_id, id)

    doc = %{
      doc
      | nodes: nodes,
        by_tag: index_add(doc.by_tag, tag, id),
        by_id: index_id(doc.by_id, attrs, id),
        by_class: index_classes(doc.by_class, attrs, id),
        next_id: id + 1
    }

    {doc, id}
  end

  @doc "Add element before a sibling (for foster parenting)"
  def add_element_before(doc, tag, attrs, parent_id, before_sibling_id, namespace \\ nil) do
    id = doc.next_id

    node = %{
      type: :element,
      id: id,
      tag: tag,
      attrs: attrs,
      parent_id: parent_id,
      children_ids: [],
      namespace: namespace
    }

    nodes = Map.put(doc.nodes, id, node)

    # Insert before sibling (after in reversed list)
    nodes = update_in(nodes, [parent_id, :children_ids], fn ids ->
      insert_after_in_list(ids || [], before_sibling_id, id)
    end)

    doc = %{
      doc
      | nodes: nodes,
        by_tag: index_add(doc.by_tag, tag, id),
        by_id: index_id(doc.by_id, attrs, id),
        by_class: index_classes(doc.by_class, attrs, id),
        next_id: id + 1
    }

    {doc, id}
  end

  def add_template_content(doc, template_id) do
    # Create a document fragment node for the template's content
    id = doc.next_id
    node = %{type: :document_fragment, id: id, children_ids: []}
    nodes = Map.put(doc.nodes, id, node)
    template_contents = Map.put(doc.template_contents, template_id, id)
    {%{doc | nodes: nodes, next_id: id + 1, template_contents: template_contents}, id}
  end

  def get_template_content(doc, template_id) do
    Map.get(doc.template_contents, template_id)
  end

  def add_text(doc, content, parent_id) do
    # Try to coalesce with the last child if it's a text node
    case last_child_text_node(doc, parent_id) do
      {:ok, text_id, existing_content} ->
        node = %{type: :text, id: text_id, content: existing_content <> content, parent_id: parent_id}
        {%{doc | nodes: Map.put(doc.nodes, text_id, node)}, text_id}

      :none ->
        id = doc.next_id
        node = %{type: :text, id: id, content: content, parent_id: parent_id}

        nodes = Map.put(doc.nodes, id, node)
        nodes = add_to_parent(nodes, parent_id, id)

        {%{doc | nodes: nodes, next_id: id + 1}, id}
    end
  end

  @doc "Add text before a sibling (for foster parenting)"
  def add_text_before(doc, content, parent_id, before_sibling_id) do
    # Check for text node immediately before the sibling for coalescing
    case text_before_sibling(doc, parent_id, before_sibling_id) do
      {:ok, text_id, existing_content} ->
        node = %{type: :text, id: text_id, content: existing_content <> content, parent_id: parent_id}
        {%{doc | nodes: Map.put(doc.nodes, text_id, node)}, text_id}

      :none ->
        id = doc.next_id
        node = %{type: :text, id: id, content: content, parent_id: parent_id}
        nodes = Map.put(doc.nodes, id, node)

        # Insert in children list before the sibling
        nodes = update_in(nodes, [parent_id, :children_ids], fn ids ->
          insert_after_in_list(ids || [], before_sibling_id, id)
        end)

        {%{doc | nodes: nodes, next_id: id + 1}, id}
    end
  end

  defp text_before_sibling(doc, parent_id, sibling_id) do
    parent = get_node(doc, parent_id)
    children_ids = parent[:children_ids] || []

    # Children are stored in reverse order, so "before" sibling means
    # the element AFTER sibling in the list
    case find_after_in_list(children_ids, sibling_id) do
      nil ->
        :none

      candidate_id ->
        case get_node(doc, candidate_id) do
          %{type: :text, content: content} -> {:ok, candidate_id, content}
          _ -> :none
        end
    end
  end

  # Find the element after target_id in a list (or nil if none)
  defp find_after_in_list([], _target), do: nil
  defp find_after_in_list([_target], _target), do: nil
  defp find_after_in_list([target, after_el | _], target), do: after_el
  defp find_after_in_list([_ | rest], target), do: find_after_in_list(rest, target)

  defp last_child_text_node(doc, parent_id) do
    with %{children_ids: [last_id | _]} <- get_node(doc, parent_id),
         %{type: :text, content: content} <- get_node(doc, last_id) do
      {:ok, last_id, content}
    else
      _ -> :none
    end
  end

  def add_comment(doc, content, parent_id) do
    id = doc.next_id
    node = %{type: :comment, id: id, content: content, parent_id: parent_id}

    nodes = Map.put(doc.nodes, id, node)
    nodes = add_to_parent(nodes, parent_id, id)

    {%{doc | nodes: nodes, next_id: id + 1}, id}
  end

  def set_root(doc, id), do: %{doc | root_id: id}

  def get_node(doc, id), do: Map.get(doc.nodes, id)

  def text(doc, id) do
    case get_node(doc, id) do
      %{type: :text, content: content} ->
        content

      %{type: :element, children_ids: ids} ->
        ids
        |> Enum.reverse()
        |> Enum.map(&text(doc, &1))
        |> IO.iodata_to_binary()

      nil ->
        ""
    end
  end

  def children(doc, id) do
    case get_node(doc, id) do
      %{type: :element, children_ids: ids} ->
        for child_id <- Enum.reverse(ids),
            node = get_node(doc, child_id),
            node.type == :element,
            do: node.id

      _ ->
        []
    end
  end

  def get_children_ids(doc, id) do
    case get_node(doc, id) do
      %{children_ids: ids} -> Enum.reverse(ids)
      _ -> []
    end
  end

  @doc "Move all children from one element to another"
  def move_children(doc, from_id, to_id) do
    from_node = get_node(doc, from_id)
    children_ids = Map.get(from_node, :children_ids, [])

    # Update parent_id on each child and add to new parent
    nodes =
      Enum.reduce(children_ids, doc.nodes, fn child_id, nodes ->
        nodes
        |> update_in([child_id, :parent_id], fn _ -> to_id end)
      end)

    # Clear old parent's children and set new parent's children
    nodes = put_in(nodes, [from_id, :children_ids], [])
    nodes = update_in(nodes, [to_id, :children_ids], fn existing ->
      children_ids ++ (existing || [])
    end)

    %{doc | nodes: nodes}
  end

  @doc "Remove a child from its parent's children list"
  def remove_from_parent(doc, child_id) do
    child = get_node(doc, child_id)
    parent_id = child.parent_id

    if parent_id do
      nodes = update_in(doc.nodes, [parent_id, :children_ids], fn ids ->
        Enum.reject(ids, &(&1 == child_id))
      end)
      %{doc | nodes: nodes}
    else
      doc
    end
  end

  @doc "Append a child to a parent"
  def append_child(doc, parent_id, child_id) do
    # Update child's parent_id
    nodes = put_in(doc.nodes, [child_id, :parent_id], parent_id)
    # Add to parent's children
    nodes = update_in(nodes, [parent_id, :children_ids], &[child_id | (&1 || [])])
    %{doc | nodes: nodes}
  end

  @doc "Insert a child before a sibling (for foster parenting)"
  def insert_child_before(doc, parent_id, child_id, before_sibling_id) do
    # Update child's parent_id
    nodes = put_in(doc.nodes, [child_id, :parent_id], parent_id)
    # Insert in children list - since children_ids is in reverse order,
    # we insert AFTER the sibling in the list to appear BEFORE in the DOM
    nodes = update_in(nodes, [parent_id, :children_ids], fn ids ->
      insert_after_in_list(ids || [], before_sibling_id, child_id)
    end)
    %{doc | nodes: nodes}
  end

  @doc "Insert a child after a sibling in DOM order (for adoption agency)"
  def insert_child_after(doc, parent_id, child_id, after_sibling_id) do
    # Update child's parent_id
    nodes = put_in(doc.nodes, [child_id, :parent_id], parent_id)
    # Insert in children list - since children_ids is in reverse order,
    # we insert BEFORE the sibling in the list to appear AFTER in the DOM
    nodes = update_in(nodes, [parent_id, :children_ids], fn ids ->
      insert_before_in_list(ids || [], after_sibling_id, child_id)
    end)
    %{doc | nodes: nodes}
  end

  # Insert new_id after target_id in the list
  defp insert_after_in_list([], _target_id, new_id), do: [new_id]

  defp insert_after_in_list([target_id | rest], target_id, new_id) do
    [target_id, new_id | rest]
  end

  defp insert_after_in_list([other | rest], target_id, new_id) do
    [other | insert_after_in_list(rest, target_id, new_id)]
  end

  # Insert new_id before target_id in the list
  defp insert_before_in_list([], _target_id, new_id), do: [new_id]

  defp insert_before_in_list([target_id | rest], target_id, new_id) do
    [new_id, target_id | rest]
  end

  defp insert_before_in_list([other | rest], target_id, new_id) do
    [other | insert_before_in_list(rest, target_id, new_id)]
  end

  defp add_to_parent(nodes, nil, _child_id), do: nodes

  defp add_to_parent(nodes, parent_id, child_id) do
    update_in(nodes, [parent_id, :children_ids], &[child_id | &1])
  end

  defp index_add(index, key, id) do
    Map.update(index, key, MapSet.new([id]), &MapSet.put(&1, id))
  end

  defp index_id(index, %{"id" => html_id}, id), do: Map.put(index, html_id, id)
  defp index_id(index, _attrs, _id), do: index

  defp index_classes(index, %{"class" => classes}, id) do
    classes
    |> String.split()
    |> Enum.reduce(index, &index_add(&2, &1, id))
  end

  defp index_classes(index, _attrs, _id), do: index
end
