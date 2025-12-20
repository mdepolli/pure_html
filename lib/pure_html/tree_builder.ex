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
               hgroup hr listing main menu nav ol p plaintext pre section summary table ul xmp)

  defstruct [:document, :stack, :head_id, :body_id, :strip_next_newline]

  @type t :: %__MODULE__{
          document: Document.t(),
          stack: [non_neg_integer()],
          head_id: non_neg_integer() | nil,
          body_id: non_neg_integer() | nil,
          strip_next_newline: boolean()
        }

  @doc "Builds a document from a stream of tokens."
  @spec build(Enumerable.t()) :: Document.t()
  def build(tokens) do
    tokens
    |> Enum.reduce(new(), &process(&2, &1))
    |> finalize()
  end

  defp new do
    %__MODULE__{
      document: Document.new(),
      stack: [],
      head_id: nil,
      body_id: nil,
      strip_next_newline: false
    }
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

  defp process(state, {:start_tag, "template", attrs, _self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> insert_template(attrs, &head_or_body_parent/1)
  end

  defp process(state, {:start_tag, tag, attrs, self_closing?}) when tag in @head_elements do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> insert_element(tag, attrs, self_closing?, &head_or_body_parent/1)
  end

  # Convert <image> to <img> per spec
  defp process(state, {:start_tag, "image", attrs, self_closing?}) do
    process(state, {:start_tag, "img", attrs, self_closing?})
  end

  defp process(state, {:start_tag, tag, attrs, self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> ensure_body()
    |> maybe_close_p(tag)
    |> maybe_close_heading(tag)
    |> maybe_close_li(tag)
    |> maybe_close_dd_dt(tag)
    |> maybe_close_table_elements(tag)
    |> maybe_close_ruby(tag)
    |> maybe_close_option(tag)
    |> maybe_close_optgroup(tag)
    |> maybe_close_button(tag)
    |> maybe_close_formatting(tag)
    |> maybe_insert_table_implicit(tag)
    |> insert_element(tag, attrs, self_closing?, &(stack_first_id(&1.stack) || &1.body_id))
    |> maybe_set_strip_newline(tag)
  end

  defp process(state, {:end_tag, "html"}), do: state
  defp process(state, {:end_tag, "head"}), do: state
  defp process(state, {:end_tag, "body"}), do: remove_from_stack(state, state.body_id)

  defp process(state, {:end_tag, tag}) do
    case close_until(state.stack, state.document, tag) do
      {:found, new_stack} -> %{state | stack: new_stack}
      :not_found -> state
    end
  end

  defp process(state, {:character, text}) do
    {text, state} = maybe_strip_newline(text, state)

    if text == "" or (String.trim(text) == "" and state.body_id == nil) do
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
    if state.document.root_id == nil do
      document = Document.add_comment_before_html(state.document, text)
      %{state | document: document}
    else
      parent_id = stack_first_id(state.stack) || state.document.root_id
      parent_id = adjust_for_template(state.document, parent_id)
      {document, _id} = Document.add_comment(state.document, text, parent_id)
      %{state | document: document}
    end
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

  # Parent selection

  defp head_or_body_parent(%{body_id: nil, head_id: head_id}), do: head_id
  defp head_or_body_parent(%{stack: [{:template, _template_id, content_id} | _]}), do: content_id
  defp head_or_body_parent(%{stack: [top | _]}), do: top
  defp head_or_body_parent(%{body_id: body_id}), do: body_id

  # Leading newline stripping for pre/textarea/listing

  defp maybe_set_strip_newline(state, tag) when tag in ~w(pre textarea listing) do
    %{state | strip_next_newline: true}
  end

  defp maybe_set_strip_newline(state, _tag), do: state

  defp maybe_strip_newline(<<?\n, rest::binary>>, %{strip_next_newline: true} = state) do
    {rest, %{state | strip_next_newline: false}}
  end

  defp maybe_strip_newline(text, state) do
    {text, %{state | strip_next_newline: false}}
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

  defp insert_template(state, attrs, parent_fn) do
    parent_id = parent_fn.(state)
    parent_id = adjust_for_template(state.document, parent_id)
    {document, template_id} = Document.add_element(state.document, "template", attrs, parent_id)
    {document, content_id} = Document.add_template_content(document, template_id)
    # Push template onto stack, but content is where children go
    %{state | document: document, stack: [{:template, template_id, content_id} | state.stack]}
  end

  defp insert_element(state, tag, attrs, self_closing?, parent_fn) do
    parent_id = parent_fn.(state)
    parent_id = adjust_for_template(state.document, parent_id)
    {document, node_id} = Document.add_element(state.document, tag, attrs, parent_id)

    stack =
      if self_closing? or tag in @void_elements, do: state.stack, else: [node_id | state.stack]

    %{state | document: document, stack: stack}
  end

  defp insert_text(state, text) do
    parent_id = get_current_parent(state)
    parent_id = adjust_for_template(state.document, parent_id)
    {document, _id} = Document.add_text(state.document, text, parent_id)
    %{state | document: document}
  end

  # When parent is a template, redirect to its content
  defp adjust_for_template(document, parent_id) do
    case Document.get_node(document, parent_id) do
      %{tag: "template"} -> Document.get_template_content(document, parent_id)
      _ -> parent_id
    end
  end

  defp get_current_parent(state) do
    case List.first(state.stack) do
      {:template, _template_id, content_id} -> content_id
      id when is_integer(id) -> id
      nil -> state.body_id
    end
  end

  # Extract node ID from stack entry (handles both plain IDs and template tuples)
  defp stack_entry_id({:template, template_id, _content_id}), do: template_id
  defp stack_entry_id(id) when is_integer(id), do: id

  defp stack_first_id([]), do: nil
  defp stack_first_id([entry | _]), do: stack_entry_id(entry)

  # Implicit closing

  defp maybe_close_p(state, tag) when tag in @closes_p do
    close_if_current(state, "p")
  end

  defp maybe_close_p(state, _tag), do: state

  # Headings close other headings
  @headings ~w(h1 h2 h3 h4 h5 h6)
  defp maybe_close_heading(state, tag) when tag in @headings do
    close_if_current_in(state, @headings)
  end

  defp maybe_close_heading(state, _tag), do: state

  defp close_if_current_in(%{stack: [entry | rest]} = state, targets) do
    node = Document.get_node(state.document, stack_entry_id(entry))
    if node.tag in targets, do: %{state | stack: rest}, else: state
  end

  defp close_if_current_in(state, _targets), do: state

  defp maybe_close_li(state, "li"), do: close_in_scope(state, "li", ~w(ul ol))
  defp maybe_close_li(state, _tag), do: state

  defp maybe_close_dd_dt(state, "dd"), do: close_in_scope(state, ~w(dd dt), ~w(dl))
  defp maybe_close_dd_dt(state, "dt"), do: close_in_scope(state, ~w(dd dt), ~w(dl))
  defp maybe_close_dd_dt(state, _tag), do: state

  # Table elements
  defp maybe_close_table_elements(state, "caption") do
    state
    |> close_in_scope(~w(td th), ~w(table))
    |> close_in_scope(~w(tr), ~w(table))
    |> close_in_scope(~w(thead tbody tfoot), ~w(table))
    |> close_in_scope("caption", ~w(table))
  end

  defp maybe_close_table_elements(state, "colgroup") do
    state
    |> close_in_scope(~w(td th), ~w(table))
    |> close_in_scope(~w(tr), ~w(table))
    |> close_in_scope(~w(thead tbody tfoot), ~w(table))
    |> close_if_current("colgroup")
  end

  defp maybe_close_table_elements(state, "tr") do
    state
    |> close_if_current("caption")
    |> close_if_current("colgroup")
    |> close_in_scope("tr", ~w(table))
  end

  defp maybe_close_table_elements(state, "td") do
    state
    |> close_if_current("caption")
    |> close_if_current("colgroup")
    |> close_in_scope(~w(td th), ~w(table tr))
  end

  defp maybe_close_table_elements(state, "th") do
    state
    |> close_if_current("caption")
    |> close_if_current("colgroup")
    |> close_in_scope(~w(td th), ~w(table tr))
  end

  defp maybe_close_table_elements(state, tag) when tag in ~w(thead tbody tfoot) do
    state
    |> close_if_current("caption")
    |> close_if_current("colgroup")
    |> close_in_scope(~w(thead tbody tfoot), ~w(table))
  end

  defp maybe_close_table_elements(state, _tag), do: state

  # Ruby elements
  defp maybe_close_ruby(state, tag) when tag in ~w(rp rt),
    do: close_in_scope(state, ~w(rp rt), ~w(ruby))

  defp maybe_close_ruby(state, tag) when tag in ~w(rb rtc),
    do: close_in_scope(state, ~w(rb rtc rp rt), ~w(ruby))

  defp maybe_close_ruby(state, _tag), do: state

  # Option elements
  defp maybe_close_option(state, tag) when tag in ~w(option optgroup hr),
    do: close_if_current(state, "option")

  defp maybe_close_option(state, _tag), do: state

  # Optgroup closes optgroup (and hr in select context)
  defp maybe_close_optgroup(state, tag) when tag in ~w(optgroup hr),
    do: close_if_current(state, "optgroup")

  defp maybe_close_optgroup(state, _tag), do: state

  # Button closes button
  defp maybe_close_button(state, "button"), do: close_in_scope(state, "button", ~w(form))
  defp maybe_close_button(state, _tag), do: state

  # Formatting elements that close themselves
  defp maybe_close_formatting(state, tag)
       when tag in ~w(a b big code em font i nobr s small strike strong tt u),
       do: close_if_current(state, tag)

  defp maybe_close_formatting(state, _tag), do: state

  # Implicit table structure
  defp maybe_insert_table_implicit(state, "col") do
    if current_tag(state) == "table" do
      insert_and_push(state, "colgroup")
    else
      state
    end
  end

  defp maybe_insert_table_implicit(state, "tr") do
    if current_tag(state) == "table" do
      insert_and_push(state, "tbody")
    else
      state
    end
  end

  defp maybe_insert_table_implicit(state, tag) when tag in ~w(td th) do
    case current_tag(state) do
      "table" ->
        state
        |> insert_and_push("tbody")
        |> insert_and_push("tr")

      t when t in ~w(tbody thead tfoot) ->
        insert_and_push(state, "tr")

      _ ->
        state
    end
  end

  defp maybe_insert_table_implicit(state, _tag), do: state

  defp current_tag(%{stack: [entry | _], document: document}) do
    Document.get_node(document, stack_entry_id(entry)).tag
  end

  defp current_tag(_state), do: nil

  defp insert_and_push(state, tag) do
    parent_id = stack_first_id(state.stack) || state.body_id
    parent_id = adjust_for_template(state.document, parent_id)
    {document, node_id} = Document.add_element(state.document, tag, %{}, parent_id)
    %{state | document: document, stack: [node_id | state.stack]}
  end

  defp close_if_current(%{stack: [entry | rest]} = state, target) do
    node = Document.get_node(state.document, stack_entry_id(entry))
    if node.tag == target, do: %{state | stack: rest}, else: state
  end

  defp close_if_current(state, _target), do: state

  defp close_in_scope(state, targets, scope_boundary) do
    targets = List.wrap(targets)

    case find_in_scope(state.stack, state.document, targets, scope_boundary) do
      {:found, new_stack} -> %{state | stack: new_stack}
      :not_found -> state
    end
  end

  defp find_in_scope([], _document, _targets, _boundary), do: :not_found

  defp find_in_scope([entry | rest], document, targets, boundary) do
    node = Document.get_node(document, stack_entry_id(entry))

    cond do
      node.tag in targets -> {:found, rest}
      node.tag in boundary -> :not_found
      true -> find_in_scope(rest, document, targets, boundary)
    end
  end

  # Stack operations

  defp remove_from_stack(state, id) do
    %{state | stack: Enum.reject(state.stack, &(stack_entry_id(&1) == id))}
  end

  defp close_until([], _document, _tag), do: :not_found

  defp close_until([entry | rest], document, tag) do
    node = Document.get_node(document, stack_entry_id(entry))

    if node.tag == tag do
      {:found, rest}
    else
      close_until(rest, document, tag)
    end
  end
end
