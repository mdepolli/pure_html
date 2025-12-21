defmodule PureHtml.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a stream of tokens.

  Uses a tuple-based representation inspired by Floki/Saxy:
  - Element: `{tag, attrs, children}`
  - Text: plain strings in children list
  - Comment: `{:comment, text}`
  - Doctype: returned separately

  The stack holds `{tag, attrs, children}` tuples where children
  accumulate in reverse order (for efficient prepending).
  """

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)

  @doc """
  Builds a document from a stream of tokens.

  Returns `{doctype, tree}` where tree is a nested tuple structure.
  """
  def build(tokens) do
    {doctype, stack} = Enum.reduce(tokens, {nil, []}, &process/2)
    {doctype, finalize(stack)}
  end

  # Doctype
  defp process({:doctype, name, public_id, system_id, _}, {_doctype, stack}) do
    {{name, public_id, system_id}, stack}
  end

  # Explicit html tag
  defp process({:start_tag, "html", attrs, _}, {doctype, []}) do
    {doctype, [{"html", attrs, []}]}
  end

  defp process({:start_tag, "html", _attrs, _}, {doctype, stack}) do
    # html already exists, ignore
    {doctype, stack}
  end

  # Explicit head tag
  defp process({:start_tag, "head", attrs, _}, {doctype, stack}) do
    stack = ensure_html(stack)
    {doctype, [{"head", attrs, []} | stack]}
  end

  # Explicit body tag
  defp process({:start_tag, "body", attrs, _}, {doctype, stack}) do
    stack =
      stack
      |> ensure_html()
      |> ensure_head()
      |> close_head()

    {doctype, [{"body", attrs, []} | stack]}
  end

  # Head elements go in head
  defp process({:start_tag, tag, attrs, self_closing}, {doctype, stack})
       when tag in @head_elements do
    stack =
      stack
      |> ensure_html()
      |> ensure_head()

    process_start_tag(tag, attrs, self_closing, doctype, stack)
  end

  # Start tag - void element (self-closing by nature)
  defp process({:start_tag, tag, attrs, _}, {doctype, stack}) when tag in @void_elements do
    stack = in_body(stack)
    {doctype, add_child({tag, attrs, []}, stack)}
  end

  # Start tag - self-closing flag
  defp process({:start_tag, tag, attrs, true}, {doctype, stack}) do
    stack = in_body(stack)
    {doctype, add_child({tag, attrs, []}, stack)}
  end

  # Start tag - push onto stack
  defp process({:start_tag, tag, attrs, _}, {doctype, stack}) do
    stack = in_body(stack)
    {doctype, [{tag, attrs, []} | stack]}
  end

  # End tags for implicit elements
  defp process({:end_tag, "html"}, acc), do: acc
  defp process({:end_tag, "head"}, {doctype, stack}), do: {doctype, close_head(stack)}
  defp process({:end_tag, "body"}, acc), do: acc

  # End tag - pop and nest in parent
  defp process({:end_tag, tag}, {doctype, stack}) do
    {doctype, close_tag(tag, stack)}
  end

  # Character data - add to current element
  defp process({:character, text}, {doctype, stack}) do
    # Whitespace-only before body is ignored
    if stack == [] or (not has_body?(stack) and String.trim(text) == "") do
      {doctype, stack}
    else
      {doctype, add_text(text, in_body(stack))}
    end
  end

  # Comment
  defp process({:comment, text}, {doctype, stack}) do
    if stack == [] do
      # Comment before html - add to html when it's created
      {doctype, stack}
    else
      {doctype, add_child({:comment, text}, stack)}
    end
  end

  # Errors - ignore
  defp process({:error, _}, acc), do: acc

  # Helper for processing start tags
  defp process_start_tag(tag, attrs, true, doctype, stack) do
    {doctype, add_child({tag, attrs, []}, stack)}
  end

  defp process_start_tag(tag, attrs, _, doctype, stack) when tag in @void_elements do
    {doctype, add_child({tag, attrs, []}, stack)}
  end

  defp process_start_tag(tag, attrs, _, doctype, stack) do
    {doctype, [{tag, attrs, []} | stack]}
  end

  # Transition to body context (ensure html/head/body exist, head is closed)
  defp in_body(stack) do
    stack
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> ensure_body()
  end

  # Ensure html element exists
  defp ensure_html([]), do: [{"html", %{}, []}]
  defp ensure_html([{"html", _, _} | _] = stack), do: stack
  defp ensure_html(stack), do: stack

  # Ensure head element exists (must be called after ensure_html)
  defp ensure_head([{"html", attrs, children}]) do
    [{"head", %{}, []}, {"html", attrs, children}]
  end

  defp ensure_head([{"head", _, _} | _] = stack), do: stack
  defp ensure_head([{"body", _, _} | _] = stack), do: stack
  defp ensure_head(stack), do: stack

  # Close head if it's open (move to body context)
  defp close_head([{"head", attrs, children} | rest]) do
    add_child({"head", attrs, Enum.reverse(children)}, rest)
  end

  defp close_head(stack), do: stack

  # Ensure body element exists
  defp ensure_body([{"body", _, _} | _] = stack), do: stack

  defp ensure_body([{"html", attrs, children}]) do
    [{"body", %{}, []}, {"html", attrs, children}]
  end

  defp ensure_body([current | rest]) do
    [current | ensure_body(rest)]
  end

  defp ensure_body([]), do: []

  # Check if body is in stack
  defp has_body?([{"body", _, _} | _]), do: true
  defp has_body?([_ | rest]), do: has_body?(rest)
  defp has_body?([]), do: false

  # Add a child to the current element (top of stack)
  defp add_child(child, [{tag, attrs, children} | rest]) do
    [{tag, attrs, [child | children]} | rest]
  end

  defp add_child(child, []) do
    [child]
  end

  # Add text, coalescing with previous text if possible
  defp add_text(text, [{tag, attrs, [prev_text | rest_children]} | rest])
       when is_binary(prev_text) do
    [{tag, attrs, [prev_text <> text | rest_children]} | rest]
  end

  defp add_text(text, [{tag, attrs, children} | rest]) do
    [{tag, attrs, [text | children]} | rest]
  end

  defp add_text(_text, []), do: []

  # Close a tag - find it in stack, pop everything up to it
  defp close_tag(tag, stack) do
    case pop_until(tag, stack, []) do
      {:found, element, rest} -> add_child(element, rest)
      :not_found -> stack
    end
  end

  # Pop elements until we find the matching tag
  defp pop_until(_tag, [], _acc), do: :not_found

  defp pop_until(tag, [{tag, attrs, children} | rest], acc) do
    element = {tag, attrs, Enum.reverse(children)}
    final_element =
      Enum.reduce(acc, element, fn child, {t, a, c} ->
        {t, a, [reverse_children(child) | c]}
      end)

    {:found, final_element, rest}
  end

  defp pop_until(tag, [current | rest], acc) do
    pop_until(tag, rest, [current | acc])
  end

  defp reverse_children({tag, attrs, children}) when is_list(children) do
    {tag, attrs, Enum.reverse(children)}
  end

  defp reverse_children(other), do: other

  # Finalize - close all open elements and return tree
  defp finalize([]), do: nil

  defp finalize(stack) do
    do_finalize(in_body(stack))
  end

  defp do_finalize([{tag, attrs, children}]) do
    {tag, attrs, reverse_all(Enum.reverse(children))}
  end

  defp do_finalize([{tag, attrs, children} | rest]) do
    child = {tag, attrs, Enum.reverse(children)}
    do_finalize(add_child(child, rest))
  end

  defp do_finalize([]) do
    nil
  end

  defp reverse_all(children) do
    Enum.map(children, fn
      {tag, attrs, kids} when is_list(kids) -> {tag, attrs, reverse_all(Enum.reverse(kids))}
      {:comment, _} = comment -> comment
      text when is_binary(text) -> text
    end)
  end
end
