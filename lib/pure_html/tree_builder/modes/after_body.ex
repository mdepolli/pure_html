defmodule PureHTML.TreeBuilder.Modes.AfterBody do
  @moduledoc """
  HTML5 "after body" insertion mode.

  This mode is entered after the body element is closed.

  Per HTML5 spec:
  - Whitespace: Process using "in body" rules
  - Comment: Insert as last child of the first element (html)
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - </html> end tag: Switch to "after after body" (we stay in after_body)
  - Anything else: Parse error, switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-afterbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  def process({:character, text}, state) do
    case String.trim(text) do
      "" ->
        # Whitespace: process using "in body" rules
        {:reprocess, %{state | mode: :in_body}}

      _ ->
        # Non-whitespace: parse error, switch to in_body, reprocess
        {:reprocess, %{state | mode: :in_body}}
    end
  end

  def process({:comment, text}, %{stack: stack} = state) do
    # Insert comment as last child of the first element (html)
    {:ok, %{state | stack: add_comment_to_html(stack, text)}}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:end_tag, "html"}, state) do
    # Switch to "after after body" - we just stay in after_body
    # since we don't implement after_after_body
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: parse error, switch to "in body", reprocess
    {:reprocess, %{state | mode: :in_body}}
  end

  # Add comment as last child of html element.
  # Since body is still on the stack, we need to close elements down to html first,
  # then add the comment, so it appears after body in the final tree.
  defp add_comment_to_html(stack, text) do
    {closed_stack, html} = close_to_html(stack, [])
    comment = {:comment, text}
    # Add comment to html.children (will be first after reversal = last)
    updated_html = %{html | children: [comment | html.children]}
    closed_stack ++ [updated_html]
  end

  # Close elements until we reach html, nesting them properly
  defp close_to_html([%{tag: "html"} = html], acc) do
    # Nest all accumulated elements and add to html.children
    nested = nest_elements(acc)
    updated_children = if nested, do: [nested | html.children], else: html.children
    {[], %{html | children: updated_children}}
  end

  defp close_to_html([elem | rest], acc) do
    close_to_html(rest, [elem | acc])
  end

  defp close_to_html([], acc) do
    # No html found, just return as-is
    {Enum.reverse(acc), nil}
  end

  # Nest a list of elements inside each other (first becomes outermost)
  defp nest_elements([]), do: nil
  defp nest_elements([single]), do: single

  defp nest_elements([outer | rest]) do
    inner = nest_elements(rest)
    %{outer | children: [inner | outer.children]}
  end
end
