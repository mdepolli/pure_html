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

  import PureHTML.TreeBuilder.Helpers

  # HTML5 ASCII whitespace characters
  @html5_whitespace ~c[ \t\n\r\f]

  @impl true
  # Empty string - all whitespace was consumed
  def process({:character, ""}, state), do: {:ok, state}

  # Leading HTML5 whitespace - strip and reprocess rest
  def process({:character, <<c, rest::binary>>}, state) when c in @html5_whitespace do
    process({:character, rest}, state)
  end

  # Non-whitespace at start - insert html and reprocess
  def process({:character, text}, state) do
    state |> insert_html([]) |> reprocess_with({:character, text})
  end

  def process({:comment, _text}, state) do
    # Comments are inserted as children of the Document
    # This is handled at document level in TreeBuilder.process_token
    {:ok, state}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state |> parse_error() |> ok()
  end

  def process({:start_tag, "html", attrs, _self_closing}, state) do
    # Create html element with attrs and switch to before_head
    state |> insert_html(attrs) |> ok()
  end

  def process({:end_tag, tag}, state) when tag in ~w(head body html br) do
    # Act as "anything else" - create implied <html> and reprocess
    state |> insert_html([]) |> reprocess()
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    state |> parse_error() |> ok()
  end

  def process(_token, state) do
    # Anything else: create implied <html>, switch to before_head, reprocess
    state |> insert_html([]) |> reprocess()
  end

  # Insert html element and switch to before_head mode
  defp insert_html(state, attrs) do
    state
    |> push_element("html", attrs)
    |> set_mode(:before_head)
  end
end
