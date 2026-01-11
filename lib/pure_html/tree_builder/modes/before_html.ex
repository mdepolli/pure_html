defmodule PureHTML.TreeBuilder.Modes.BeforeHtml do
  @moduledoc """
  HTML5 "before html" insertion mode.

  This mode is entered after DOCTYPE is processed in initial mode.

  Per HTML5 spec:
  - DOCTYPE: Parse error, ignore
  - Comment: Insert as child of Document
  - Whitespace: Ignore
  - <html> start tag: Create element, switch to "before head"
  - </head>, </body>, </html>, </br>: Act as "anything else"
  - Any other end tag: Parse error, ignore
  - Anything else: Create <html>, switch to "before head", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-before-html-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  @impl true
  def process({:character, text}, state) do
    # Whitespace is ignored
    # Non-whitespace triggers implied <html> and reprocess
    case String.trim(text) do
      "" ->
        {:ok, state}

      _ ->
        {:reprocess, insert_html(state, %{})}
    end
  end

  def process({:comment, _text}, state) do
    # Comments are inserted as children of the Document
    # This is handled at document level in TreeBuilder.process_token
    {:ok, state}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", attrs, _self_closing}, state) do
    # Create html element with attrs and switch to before_head
    {:ok, insert_html(state, attrs)}
  end

  def process({:end_tag, tag}, state) when tag in ~w(head body html br) do
    # Act as "anything else" - create implied <html> and reprocess
    {:reprocess, insert_html(state, %{})}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: create implied <html>, switch to before_head, reprocess
    {:reprocess, insert_html(state, %{})}
  end

  # Insert html element and switch to before_head mode
  defp insert_html(%{stack: stack} = state, attrs) do
    html = %{ref: make_ref(), tag: "html", attrs: attrs, children: []}
    %{state | stack: [html | stack], mode: :before_head}
  end
end
