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

  # Elements that implicitly close an open <p> element
  @closes_p ~w(address article aside blockquote center details dialog dir div dl
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup
               hr listing main menu nav ol p pre section summary table ul)

  @doc """
  Builds a document from a stream of tokens.

  Returns `{doctype, tree}` where tree is a nested tuple structure.
  """
  def build(tokens) do
    {doctype, stack} =
      Enum.reduce(tokens, {nil, []}, fn
        {:doctype, name, public_id, system_id, _}, {_, stack} ->
          {{name, public_id, system_id}, stack}

        token, {doctype, stack} ->
          {doctype, process(token, stack)}
      end)

    {doctype, finalize(stack)}
  end

  # Explicit html tag
  defp process({:start_tag, "html", attrs, _}, []) do
    [{"html", attrs, []}]
  end

  defp process({:start_tag, "html", _attrs, _}, stack) do
    stack
  end

  # Explicit head tag
  defp process({:start_tag, "head", attrs, _}, stack) do
    stack
    |> ensure_html()
    |> push_element("head", attrs)
  end

  # Explicit body tag
  defp process({:start_tag, "body", attrs, _}, stack) do
    stack
    |> ensure_html()
    |> ensure_head()
    |> close_head()
    |> push_element("body", attrs)
  end

  # Head elements go in head
  defp process({:start_tag, tag, attrs, self_closing}, stack)
       when tag in @head_elements do
    stack
    |> ensure_html()
    |> ensure_head()
    |> process_start_tag(tag, attrs, self_closing)
  end

  # Start tag - void element (self-closing by nature)
  defp process({:start_tag, tag, attrs, _}, stack) when tag in @void_elements do
    stack
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child({tag, attrs, []})
  end

  # Start tag - self-closing flag
  defp process({:start_tag, tag, attrs, true}, stack) do
    stack
    |> in_body()
    |> maybe_close_p(tag)
    |> add_child({tag, attrs, []})
  end

  # Start tag - push onto stack
  defp process({:start_tag, tag, attrs, _}, stack) do
    stack
    |> in_body()
    |> maybe_close_p(tag)
    |> push_element(tag, attrs)
  end

  # End tags for implicit elements
  defp process({:end_tag, "html"}, stack), do: stack
  defp process({:end_tag, "head"}, stack), do: close_head(stack)
  defp process({:end_tag, "body"}, stack), do: stack

  # End tag - pop and nest in parent
  defp process({:end_tag, tag}, stack), do: close_tag(tag, stack)

  # Character data - empty stack, create structure
  defp process({:character, text}, []) do
    []
    |> ensure_html()
    |> in_body()
    |> add_text(text)
  end

  # Character data inside head element - add directly
  defp process({:character, text}, [{tag, _, _} | _] = stack) when tag in @head_elements do
    add_text(stack, text)
  end

  # Character data - whitespace before body is ignored
  defp process({:character, text}, stack) do
    case {has_body?(stack), String.trim(text)} do
      {false, ""} -> stack
      _ -> stack |> in_body() |> add_text(text)
    end
  end

  # Comment before html - ignored for now
  defp process({:comment, _text}, []), do: []

  # Comment - add to current element
  defp process({:comment, text}, stack) do
    add_child(stack, {:comment, text})
  end

  # Errors - ignore
  defp process({:error, _}, stack), do: stack

  # Helper for processing start tags (stack first for piping)
  defp process_start_tag(stack, tag, attrs, true) do
    add_child(stack, {tag, attrs, []})
  end

  defp process_start_tag(stack, tag, attrs, _) when tag in @void_elements do
    add_child(stack, {tag, attrs, []})
  end

  defp process_start_tag(stack, tag, attrs, _) do
    push_element(stack, tag, attrs)
  end

  # Close <p> if it's currently open and tag is in @closes_p
  defp maybe_close_p(stack, tag) when tag in @closes_p do
    close_p_if_open(stack)
  end

  defp maybe_close_p(stack, _tag), do: stack

  # Close <p> if it's on top of the stack (don't reverse - finalize will do that)
  defp close_p_if_open([{"p", attrs, children} | rest]) do
    add_child(rest, {"p", attrs, children})
  end

  defp close_p_if_open(stack), do: stack

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
  defp ensure_head([{"html", _, _}] = stack), do: ensure_head(stack, stack)
  defp ensure_head([{"head", _, _} | _] = stack), do: stack
  defp ensure_head([{"body", _, _} | _] = stack), do: stack
  defp ensure_head(stack), do: stack

  # Head found - return original stack unchanged
  defp ensure_head([{"html", _, [{"head", _, _} | _]}], original), do: original

  # Skip non-head child, keep checking
  defp ensure_head([{"html", attrs, [_ | rest]}], original) do
    ensure_head([{"html", attrs, rest}], original)
  end

  # No head found - create one with original children
  defp ensure_head([{"html", attrs, []}], [{"html", _, children}]) do
    [{"head", %{}, []}, {"html", attrs, children}]
  end

  # Close head if it's open (move to body context)
  defp close_head([{"head", attrs, children} | rest]) do
    add_child(rest, {"head", attrs, children})
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

  # Push a new element onto the stack (stack first for piping)
  defp push_element(stack, tag, attrs) do
    [{tag, attrs, []} | stack]
  end

  # Add a child to the current element (top of stack)
  defp add_child(stack, child)

  defp add_child([{tag, attrs, children} | rest], child) do
    [{tag, attrs, [child | children]} | rest]
  end

  defp add_child([], child) do
    [child]
  end

  # Add text, coalescing with previous text if possible (stack first for piping)
  defp add_text(stack, text)

  defp add_text([{tag, attrs, [prev_text | rest_children]} | rest], text)
       when is_binary(prev_text) do
    [{tag, attrs, [prev_text <> text | rest_children]} | rest]
  end

  defp add_text([{tag, attrs, children} | rest], text) do
    [{tag, attrs, [text | children]} | rest]
  end

  defp add_text([], _text), do: []

  # Close a tag - find it in stack, pop everything up to it
  defp close_tag(tag, stack) do
    case pop_until(tag, stack, []) do
      {:found, element, rest} -> add_child(rest, element)
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
  defp finalize(stack) do
    stack
    |> close_through_head()
    |> ensure_body()
    |> do_finalize()
  end

  # Close all elements through head (for finalization)
  defp close_through_head([{"html", _, _}] = stack), do: stack
  defp close_through_head([{"body", _, _} | _] = stack), do: stack

  defp close_through_head([{tag, attrs, children} | rest]) do
    child = {tag, attrs, children}
    close_through_head(add_child(rest, child))
  end

  defp close_through_head([]), do: [{"html", %{}, [{"head", %{}, []}]}]

  # Single element left - this is the root, reverse all children
  defp do_finalize([{tag, attrs, children}]) do
    {tag, attrs, reverse_all(children)}
  end

  # Multiple elements - close top and add to parent, don't reverse yet
  defp do_finalize([{tag, attrs, children} | rest]) do
    child = {tag, attrs, children}
    do_finalize(add_child(rest, child))
  end

  defp do_finalize([]), do: nil

  # Recursively reverse children at all levels (called only on root)
  defp reverse_all(children) do
    children
    |> Enum.reverse()
    |> Enum.map(fn
      {tag, attrs, kids} when is_list(kids) -> {tag, attrs, reverse_all(kids)}
      {:comment, _} = comment -> comment
      text when is_binary(text) -> text
    end)
  end
end
