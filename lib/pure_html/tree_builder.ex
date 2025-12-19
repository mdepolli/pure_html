defmodule PureHtml.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a stream of tokens.

  This module can be tested independently against html5lib tree-construction tests.
  """

  alias PureHtml.Document

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)

  # Elements that implicitly close an open <p> element
  @closes_p ~w(address article aside blockquote center details dialog dir div dl
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header
               hgroup hr main menu nav ol p pre section summary table ul)

  defstruct [:document, :stack, :head_id, :body_id]

  @type t :: %__MODULE__{
          document: Document.t(),
          stack: [non_neg_integer()],
          head_id: non_neg_integer() | nil,
          body_id: non_neg_integer() | nil
        }

  @doc "Builds a document from a stream of tokens."
  @spec build(Enumerable.t()) :: Document.t()
  def build(tokens) do
    tokens
    |> Enum.reduce(new(), &process(&2, &1))
    |> finalize()
  end

  defp new do
    %__MODULE__{document: Document.new(), stack: [], head_id: nil, body_id: nil}
  end

  defp process(state, {:start_tag, "html", attrs, _self_closing?}) do
    ensure_html(state, attrs)
  end

  defp process(state, {:start_tag, "head", attrs, _self_closing?}) do
    state
    |> ensure_html(%{})
    |> maybe_insert_head(attrs)
  end

  defp process(state, {:start_tag, "body", attrs, _self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> maybe_insert_body(attrs)
  end

  defp process(state, {:start_tag, tag, attrs, self_closing?}) when tag in @head_elements do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> insert_element(tag, attrs, self_closing?, & &1.head_id)
  end

  defp process(state, {:start_tag, tag, attrs, self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> ensure_body()
    |> maybe_close_p(tag)
    |> maybe_close_li(tag)
    |> insert_element(tag, attrs, self_closing?, &(List.first(&1.stack) || &1.body_id))
  end

  defp process(state, {:end_tag, "html"}), do: state
  defp process(state, {:end_tag, "head"}), do: remove_from_stack(state, state.head_id)
  defp process(state, {:end_tag, "body"}), do: remove_from_stack(state, state.body_id)

  defp process(state, {:end_tag, tag}) do
    %{state | stack: close_until(state.stack, state.document, tag)}
  end

  defp process(state, {:character, text}) do
    if String.trim(text) == "" and state.body_id == nil do
      state
    else
      state
      |> ensure_html(%{})
      |> ensure_head()
      |> ensure_body()
      |> insert_text(text)
    end
  end

  defp process(state, {:comment, text}) do
    parent_id = List.first(state.stack) || state.document.root_id
    {document, _id} = Document.add_comment(state.document, text, parent_id)
    %{state | document: document}
  end

  defp process(state, {:doctype, name, public_id, system_id, _force_quirks}) do
    %{state | document: Document.set_doctype(state.document, name, public_id, system_id)}
  end

  defp process(state, {:error, _}), do: state

  defp finalize(state) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> ensure_body()
    |> Map.get(:document)
  end

  # Ensure implicit elements exist

  defp ensure_html(%__MODULE__{document: %{root_id: nil}} = state, attrs) do
    {document, html_id} = Document.add_element(state.document, "html", attrs, nil)
    %{state | document: Document.set_root(document, html_id)}
  end

  defp ensure_html(state, _attrs), do: state

  defp ensure_head(%__MODULE__{head_id: nil} = state),
    do: insert_implicit(state, "head", :head_id)

  defp ensure_head(state), do: state

  defp ensure_body(%__MODULE__{body_id: nil} = state),
    do: insert_implicit(state, "body", :body_id)

  defp ensure_body(state), do: state

  defp maybe_insert_head(%{head_id: nil} = state, attrs),
    do: insert_implicit(state, "head", :head_id, attrs)

  defp maybe_insert_head(state, _attrs), do: state

  defp maybe_insert_body(%{body_id: nil} = state, attrs),
    do: insert_implicit(state, "body", :body_id, attrs)

  defp maybe_insert_body(state, _attrs), do: state

  defp insert_implicit(state, tag, field, attrs \\ %{}) do
    {document, id} = Document.add_element(state.document, tag, attrs, state.document.root_id)
    %{state | document: document} |> Map.put(field, id)
  end

  # Insert nodes

  defp insert_element(state, tag, attrs, self_closing?, parent_fn) do
    parent_id = parent_fn.(state)
    {document, node_id} = Document.add_element(state.document, tag, attrs, parent_id)

    stack =
      if self_closing? or tag in @void_elements, do: state.stack, else: [node_id | state.stack]

    %{state | document: document, stack: stack}
  end

  defp insert_text(state, text) do
    parent_id = List.first(state.stack) || state.body_id
    {document, _id} = Document.add_text(state.document, text, parent_id)
    %{state | document: document}
  end

  # Implicit closing

  defp maybe_close_p(state, tag) when tag in @closes_p do
    close_if_current(state, "p")
  end

  defp maybe_close_p(state, _tag), do: state

  defp maybe_close_li(state, "li"), do: close_in_scope(state, "li", ~w(ul ol))
  defp maybe_close_li(state, _tag), do: state

  defp close_if_current(state, target) do
    case state.stack do
      [top | rest] ->
        node = Document.get_node(state.document, top)
        if node.tag == target, do: %{state | stack: rest}, else: state

      _ ->
        state
    end
  end

  defp close_in_scope(state, target, scope_boundary) do
    case find_in_scope(state.stack, state.document, target, scope_boundary) do
      {:found, new_stack} -> %{state | stack: new_stack}
      :not_found -> state
    end
  end

  defp find_in_scope([], _document, _target, _boundary), do: :not_found

  defp find_in_scope([top | rest], document, target, boundary) do
    node = Document.get_node(document, top)

    cond do
      node.tag == target -> {:found, rest}
      node.tag in boundary -> :not_found
      true -> find_in_scope(rest, document, target, boundary)
    end
  end

  # Stack operations

  defp remove_from_stack(state, id) do
    %{state | stack: Enum.reject(state.stack, &(&1 == id))}
  end

  defp close_until([], _document, _tag), do: []

  defp close_until([top | rest], document, tag) do
    node = Document.get_node(document, top)

    if node.tag == tag do
      rest
    else
      close_until(rest, document, tag)
    end
  end
end
