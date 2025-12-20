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

  def add_element(doc, tag, attrs, parent_id) do
    id = doc.next_id

    node = %{
      type: :element,
      id: id,
      tag: tag,
      attrs: attrs,
      parent_id: parent_id,
      children_ids: []
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
