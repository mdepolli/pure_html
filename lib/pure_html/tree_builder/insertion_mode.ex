defmodule PureHTML.TreeBuilder.InsertionMode do
  @moduledoc """
  Behavior for HTML5 insertion mode handlers.

  Each insertion mode module implements this behavior to handle tokens
  according to the HTML5 tree construction algorithm.

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-insertion-mode
  """

  alias PureHTML.TreeBuilder.State

  @type token ::
          {:doctype, String.t(), String.t() | nil, String.t() | nil, boolean()}
          | {:start_tag, String.t(), map(), boolean()}
          | {:end_tag, String.t()}
          | {:character, String.t()}
          | {:comment, String.t()}
          | {:error, atom()}
          | :eof

  @doc """
  Process a token in this insertion mode.

  Returns the updated state, which may include a mode transition.
  """
  @callback process(token(), State.t()) :: State.t()
end
