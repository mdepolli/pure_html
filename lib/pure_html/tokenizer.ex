defmodule PureHTML.Tokenizer do
  @moduledoc """
  HTML5 tokenizer that produces a stream of tokens.

  The tokenizer is implemented as a state machine. Each call to `next_token/1`
  advances the machine until it produces a token, then returns the token and
  the updated state. The tree builder switches the state for raw text, RCDATA,
  script data, and plaintext elements with `set_state/2`, and tells the
  tokenizer whether the adjusted current node is foreign with
  `set_foreign_content/2` (for CDATA sections).

  ## Usage

      iex> PureHTML.Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()
      [{:start_tag, "p", [], false}, {:character, "Hello"}, {:end_tag, "p"}]

  ## Token Types

  - `{:doctype, name, public_id, system_id, force_quirks?}`
  - `{:start_tag, name, attrs, self_closing?}`
  - `{:end_tag, name}`
  - `{:comment, data}`
  - `{:pi, target, data}`
  - `{:character, data}`

  """

  alias PureHTML.Entities

  @type t :: %__MODULE__{}

  @type token ::
          {:doctype, String.t() | nil, String.t() | nil, String.t() | nil, boolean()}
          | {:start_tag, String.t(), [{String.t(), String.t()}], boolean()}
          | {:end_tag, String.t()}
          | {:comment, String.t()}
          | {:pi, String.t(), String.t()}
          | {:character, String.t()}
          | :eof

  # The tokenizer state struct
  defstruct [
    # remaining input binary
    :input,
    # current state atom
    :state,
    # state to return to (for character references, etc.)
    :return_state,
    # token being built
    :token,
    # temporary buffer for tag names, etc.
    :buffer,
    # current attribute name being built
    :attr_name,
    # current attribute value being built
    :attr_value,
    # for appropriate end tag checks
    :last_start_tag,
    # pending character data (for coalescing)
    :pending_chars,
    # deferred token (to emit after flushing pending chars)
    :deferred_token,
    # Tree builder feedback: is adjusted current node NOT in HTML namespace?
    # When true, <![CDATA[ is parsed as CDATA section
    # When false (default), <![CDATA[ is treated as bogus comment
    adjusted_current_node_not_in_html_namespace: false,
    # XML infoset coercion mode - applies transformations for XML compatibility
    xml_violation_mode: false,
    # Whether the EOF token has already been emitted
    eof_emitted: false,
    # Parse error count
    error_count: 0,
    # Names of the attributes seen on the tag token being built, for the
    # duplicate check when leaving the attribute name state. An end tag with
    # any is an end-tag-with-attributes parse error at emit.
    attr_names: [],
    # The current attribute is a duplicate: its value is still consumed, then
    # dropped.
    duplicate_attr: false
  ]

  # Guards
  defguardp is_ascii_alpha(c) when c in ?a..?z or c in ?A..?Z
  defguardp is_ascii_lower(c) when c in ?a..?z
  defguardp is_ascii_upper(c) when c in ?A..?Z
  defguardp is_ascii_digit(c) when c in ?0..?9
  defguardp is_ascii_whitespace(c) when c in ~c[\t\n\f ]
  defguardp is_ascii_hex_digit(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F
  defguardp is_surrogate(cp) when cp in 0xD800..0xDFFF
  defguardp is_outside_unicode_range(cp) when cp > 0x10FFFF

  # Preprocessing the input stream: controls other than ASCII whitespace and
  # U+0000, and noncharacters, are parse errors. Surrogates would be too, but
  # decoded UTF-8 cannot carry one: the Encoding Standard's decoders replace a
  # lone surrogate, and only a script API such as document.write() could push
  # one past them.
  defguardp is_input_stream_error(cp)
            when cp in 0x01..0x08 or cp == 0x0B or cp in 0x0E..0x1F or cp in 0x7F..0x9F or
                   cp in 0xFDD0..0xFDEF or rem(cp, 0x10000) in [0xFFFE, 0xFFFF]

  # Match "doctype" case-insensitively using bitwise OR with 0x20 to force lowercase
  # "doctype" as 56-bit integer: 0x646F6374797065
  defguardp is_doctype(prefix)
            when :erlang.bor(prefix, 0x20202020202020) == 0x646F6374797065

  # "public" as 48-bit integer: 0x7075626C6963
  defguardp is_public(prefix)
            when :erlang.bor(prefix, 0x202020202020) == 0x7075626C6963

  # "system" as 48-bit integer: 0x73797374656D
  defguardp is_system(prefix)
            when :erlang.bor(prefix, 0x202020202020) == 0x73797374656D

  defguardp is_attribute_value_state(state)
            when state in [
                   :attribute_value_double_quoted,
                   :attribute_value_single_quoted,
                   :attribute_value_unquoted
                 ]

  defp parse_error(state), do: %{state | error_count: state.error_count + 1}

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Creates a new tokenizer state from input.

  The input is decoded as UTF-8 with U+FFFD replacement, newlines are
  normalized, and the input stream parse errors (controls, noncharacters)
  are counted into `error_count`.

  ## Options

  - `:initial_state` - Starting tokenizer state (default: `:data`)
  - `:last_start_tag` - Last start tag name for appropriate end tag checks
  """
  @spec new(String.t(), keyword()) :: t()
  def new(input, opts \\ []) when is_binary(input) do
    initial_state = Keyword.get(opts, :initial_state, :data)
    last_start_tag = Keyword.get(opts, :last_start_tag, nil)
    xml_violation_mode = Keyword.get(opts, :xml_violation_mode, false)

    decoded_input =
      input
      |> normalize_newlines()
      |> utf8_with_replacement()

    %__MODULE__{
      input: decoded_input,
      state: initial_state,
      return_state: nil,
      token: nil,
      buffer: "",
      attr_name: "",
      attr_value: "",
      last_start_tag: last_start_tag,
      pending_chars: [],
      deferred_token: nil,
      xml_violation_mode: xml_violation_mode,
      error_count: preprocess_error_count(decoded_input)
    }
  end

  @doc """
  Tokenizes an HTML string, returning a Stream of tokens.

  The stream is lazy - tokens are produced on demand as the stream is consumed.
  """
  @spec tokenize(String.t(), keyword()) :: Enumerable.t()
  def tokenize(input, opts \\ []) when is_binary(input) do
    input
    |> new(opts)
    |> Stream.unfold(&next_token/1)
    |> Stream.reject(&(&1 == :eof))
  end

  @doc """
  Tokenizes an HTML string and returns `{tokens, error_count}`, where the
  count follows the parse errors of the tokenizer and the input stream.
  """
  @spec tokenize_with_errors(String.t(), keyword()) :: {[term()], non_neg_integer()}
  def tokenize_with_errors(input, opts \\ []) when is_binary(input) do
    input
    |> new(opts)
    |> drain([])
  end

  defp drain(state, acc) do
    case next_token(state) do
      {:eof, state} -> {Enum.reverse(acc), state.error_count}
      {token, state} -> drain(state, [token | acc])
      nil -> {Enum.reverse(acc), state.error_count}
    end
  end

  @doc """
  Updates the foreign content context flag.

  When `in_foreign_content` is true, `<![CDATA[` will be parsed as a CDATA section.
  When false (default), it's treated as a bogus comment per HTML5 spec.
  """
  @spec set_foreign_content(t(), boolean()) :: t()
  def set_foreign_content(%__MODULE__{} = tokenizer, in_foreign_content) do
    %{tokenizer | adjusted_current_node_not_in_html_namespace: in_foreign_content}
  end

  @doc """
  Switches the tokenizer state. The tree builder does this for the generic
  raw text and RCDATA element parsing algorithms, script, and plaintext.
  """
  @spec set_state(t(), atom()) :: t()
  def set_state(%__MODULE__{} = tokenizer, state), do: %{tokenizer | state: state}

  # --------------------------------------------------------------------------
  # Token emission
  # --------------------------------------------------------------------------

  @doc """
  Gets the next token from the tokenizer.

  Returns `{token, updated_tokenizer}` or `nil` when done.
  """
  @spec next_token(t()) :: {token(), t()} | nil

  # First, check for a deferred token from previous flush
  def next_token(%__MODULE__{deferred_token: token} = state) when token != nil do
    {token, %{state | deferred_token: nil}}
  end

  # EOF already emitted — signal end of token stream
  def next_token(%__MODULE__{eof_emitted: true}), do: nil

  # States where EOF should flush pending chars and terminate without a parse error.
  # Excludes "less_than_sign" states which have implicit pending '<' to emit via step.
  @eof_flush_states [
    :data,
    :rawtext,
    :rcdata,
    :plaintext,
    :script_data,
    :script_data_escape_start,
    :script_data_escape_start_dash
  ]

  def next_token(%__MODULE__{input: "", state: s} = state)
      when s in @eof_flush_states do
    emit_eof(state)
  end

  def next_token(%__MODULE__{} = state) do
    case step(state) do
      {:emit_char, chars, new_state} ->
        # Accumulate characters instead of emitting immediately
        next_token(%{new_state | pending_chars: [chars | new_state.pending_chars]})

      {:emit, token, new_state} ->
        token = reverse_start_tag_attrs(token)

        # Flush pending chars before emitting non-char token
        case new_state.pending_chars do
          [] ->
            {maybe_coerce_token(token, new_state.xml_violation_mode), new_state}

          pending ->
            # Emit chars now, defer the non-char token
            deferred = maybe_coerce_token(token, new_state.xml_violation_mode)

            {flush_pending(pending, new_state.xml_violation_mode),
             %{new_state | pending_chars: [], deferred_token: deferred}}
        end

      {:continue, new_state} ->
        next_token(new_state)

      {:eof_parse_error, new_state} ->
        emit_eof(new_state)

      nil ->
        emit_eof(state)
    end
  end

  defp emit_eof(%__MODULE__{pending_chars: []} = state) do
    {:eof, %{state | eof_emitted: true}}
  end

  defp emit_eof(%__MODULE__{pending_chars: pending} = state) do
    {flush_pending(pending, state.xml_violation_mode),
     %{state | pending_chars: [], deferred_token: :eof, eof_emitted: true}}
  end

  defp flush_pending(pending, xml_violation_mode) do
    chars =
      pending
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    chars = if xml_violation_mode, do: coerce_chars_for_xml(chars), else: chars
    {:character, chars}
  end

  # XML infoset coercion for characters:
  # - U+FFFF (noncharacter) → U+FFFD (replacement character)
  # - U+000C (form feed) → space
  defp coerce_chars_for_xml(chars) do
    chars
    |> String.replace(<<0xFFFF::utf8>>, <<0xFFFD::utf8>>)
    |> String.replace(<<0x000C>>, " ")
  end

  # XML infoset coercion for comments: "--" → "- -"
  defp maybe_coerce_token({:comment, data}, true) do
    {:comment, String.replace(data, "--", "- -")}
  end

  defp maybe_coerce_token(token, _xml_violation_mode), do: token

  # --------------------------------------------------------------------------
  # State machine
  # --------------------------------------------------------------------------

  # Data state - the default state, reading regular content
  defp step(%{state: :data, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :tag_open, input: rest)
  end

  defp step(%{state: :data, input: <<?&, _rest::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :data)
  end

  defp step(%{state: :data, input: <<0, rest::binary>>} = state) do
    # Null character - parse error, emit as character
    state
    |> parse_error()
    |> emit_char(<<0>>, input: rest)
  end

  defp step(%{state: :data, input: input} = state) when input != "" do
    # Read ahead until we hit <, &, null, or end - emit coalesced characters
    {chars, rest} = chars_until_data(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :data, input: ""} = _state) do
    # Handled by next_token/1 - but keeping for completeness
    nil
  end

  # RAWTEXT state - for <style>, <xmp>, etc. No entity decoding.
  defp step(%{state: :rawtext, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :rawtext_less_than_sign, input: rest)
  end

  defp step(%{state: :rawtext, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rawtext, input: ""} = _state), do: nil

  defp step(%{state: :rawtext, input: input} = state) do
    {chars, rest} = chars_until_rawtext(input)
    emit_char(state, chars, input: rest)
  end

  # PLAINTEXT state - consumes everything until EOF, no end tag recognition
  defp step(%{state: :plaintext, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :plaintext, input: ""} = _state), do: nil

  defp step(%{state: :plaintext, input: input} = state) do
    {chars, rest} = chars_until_null(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :rawtext_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rawtext_end_tag_name,
      token: {:end_tag, ""},
      attr_names: [],
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :rawtext_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in rawtext state
      emit_end_tag_buffer(state, :rawtext, state.input)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in rawtext state
      emit_end_tag_buffer(state, :rawtext, state.input)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rawtext, token: nil, input: rest)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :rawtext, state.input)
  end

  # RCDATA state - for <textarea>, <title>. Processes entities.
  defp step(%{state: :rcdata, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :rcdata_less_than_sign, input: rest)
  end

  defp step(%{state: :rcdata, input: <<?&, _rest::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :rcdata)
  end

  defp step(%{state: :rcdata, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rcdata, input: ""} = _state), do: nil

  defp step(%{state: :rcdata, input: input} = state) do
    {chars, rest} = chars_until_data(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :rcdata_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rcdata_end_tag_name,
      token: {:end_tag, ""},
      attr_names: [],
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :rcdata_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in rcdata state
      emit_end_tag_buffer(state, :rcdata, state.input)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in rcdata state
      emit_end_tag_buffer(state, :rcdata, state.input)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rcdata, token: nil, input: rest)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :rcdata, state.input)
  end

  # Script data state - for <script>. Similar to RAWTEXT but handles escaped states.
  defp step(%{state: :script_data, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data, input: ""} = _state), do: nil

  defp step(%{state: :script_data, input: input} = state) do
    {chars, rest} = chars_until_rawtext(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :script_data_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: <<?!, rest::binary>>} = state) do
    emit_char(state, "<!", state: :script_data_escape_start, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_end_tag_name,
      token: {:end_tag, ""},
      attr_names: [],
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :script_data_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in script_data state
      emit_end_tag_buffer(state, :script_data, state.input)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in script_data state
      emit_end_tag_buffer(state, :script_data, state.input)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :script_data, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :script_data, state.input)
  end

  # Script data escape start
  defp step(%{state: :script_data_escape_start, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escape_start_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start, input: _} = state) do
    continue(state, state: :script_data)
  end

  defp step(%{state: :script_data_escape_start_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start_dash, input: _} = state) do
    continue(state, state: :script_data)
  end

  # Script data escaped state
  defp step(%{state: :script_data_escaped, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped, input: input} = state) do
    {chars, rest} = chars_until_comment(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?>, rest::binary>>} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_end_tag_open, buffer: "", input: rest)
  end

  # "Emit a U+003C LESS-THAN SIGN character token and the current input
  # character as a character token"; only the temporary buffer is lowercased.
  defp step(%{state: :script_data_escaped_less_than_sign, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>

    emit_char(state, <<?<, c>>,
      state: :script_data_double_escape_start,
      buffer: char,
      input: rest
    )
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_escaped_end_tag_name,
      token: {:end_tag, ""},
      attr_names: [],
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in script_data_escaped state
      emit_end_tag_buffer(state, :script_data_escaped, state.input)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in script_data_escaped state
      emit_end_tag_buffer(state, :script_data_escaped, state.input)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">",
        state: :script_data_escaped,
        token: nil,
        input: rest
      )
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :script_data_escaped, state.input)
  end

  # Script data double escape start
  defp step(%{state: :script_data_double_escape_start, input: <<c, rest::binary>>} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_start, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_start, input: _} = state) do
    continue(state, state: :script_data_escaped)
  end

  # Script data double escaped state
  defp step(%{state: :script_data_double_escaped, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_double_escaped, input: input} = state) do
    {chars, rest} = chars_until_comment(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?>, rest::binary>>} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: ""} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(
         %{state: :script_data_double_escaped_dash_dash, input: <<c::utf8, rest::binary>>} = state
       ) do
    emit_char(state, <<c::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(
         %{state: :script_data_double_escaped_less_than_sign, input: <<?/, rest::binary>>} = state
       ) do
    emit_char(state, "/", state: :script_data_double_escape_end, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_less_than_sign, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  defp step(%{state: :script_data_double_escape_end, input: <<c, rest::binary>>} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_end, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_end, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  # Tag open state - saw '<', determine what kind of tag
  defp step(%{state: :tag_open, input: <<?!, rest::binary>>} = state) do
    continue(state, state: :markup_declaration_open, input: rest)
  end

  defp step(%{state: :tag_open, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :end_tag_open, input: rest)
  end

  defp step(%{state: :tag_open, input: <<c, rest::binary>>} = state) when is_ascii_alpha(c) do
    continue(state,
      state: :tag_name,
      input: <<c, rest::binary>>,
      token: {:start_tag, "", [], false},
      attr_names: []
    )
  end

  defp step(%{state: :tag_open, input: <<??, rest::binary>>} = state) do
    continue(state, state: :processing_instruction_open, input: rest, buffer: "")
  end

  defp step(%{state: :tag_open, input: ""} = state) do
    # eof-before-tag-name parse error
    state
    |> parse_error()
    |> emit_char("<", state: :data)
  end

  defp step(%{state: :tag_open, input: _} = state) do
    # invalid-first-character-of-tag-name parse error
    state
    |> parse_error()
    |> emit_char("<", state: :data)
  end

  # Processing instruction open state
  defp step(%{state: :processing_instruction_open, input: <<c, _::binary>>} = state)
       when is_ascii_alpha(c) or c == ?_ do
    continue(state, state: :processing_instruction_target)
  end

  # EOF here (and in target, data, and questionable) is the tag-state shape,
  # not comment-state emit/1. The text is "eof-in-processing-instruction parse
  # error. Emit an end-of-file token." emit/1 would flush state.token, and
  # after the target state that is a half-built {:pi, target, ""}.
  defp step(%{state: :processing_instruction_open, input: ""} = state) do
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :processing_instruction_open, input: _} = state) do
    # invalid-first-character-of-processing-instruction-target
    state
    |> parse_error()
    |> convert_buffer_to_comment()
  end

  # Processing instruction target state
  defp step(%{state: :processing_instruction_target, input: <<c, _::binary>>} = state)
       when c in ~c[\t\n\f ?>] do
    finish_pi_target(state)
  end

  defp step(%{state: :processing_instruction_target, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) or is_ascii_digit(c) or c in [?-, ?_] do
    continue(state, buffer: state.buffer <> <<c>>, input: rest)
  end

  # eof-in-processing-instruction: emit EOF, not the current PI token.
  defp step(%{state: :processing_instruction_target, input: ""} = state) do
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :processing_instruction_target, input: _} = state) do
    # invalid-processing-instruction-target
    state
    |> parse_error()
    |> convert_buffer_to_comment()
  end

  # After processing instruction target state
  defp step(%{state: :after_processing_instruction_target, input: <<c, rest::binary>>} = state)
       when c in ~c[\t\n\f ] do
    continue(state, input: rest)
  end

  defp step(%{state: :after_processing_instruction_target, input: _} = state) do
    continue(state, state: :processing_instruction_data)
  end

  # Processing instruction data state
  defp step(%{state: :processing_instruction_data, input: <<??, rest::binary>>} = state) do
    continue(state, state: :processing_instruction_questionable, input: rest)
  end

  defp step(%{state: :processing_instruction_data, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  # eof-in-processing-instruction: emit EOF, not the current PI token.
  defp step(%{state: :processing_instruction_data, input: ""} = state) do
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :processing_instruction_data, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_pi_data(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Processing instruction questionable state
  defp step(%{state: :processing_instruction_questionable, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  # eof-in-processing-instruction: emit EOF, not the current PI token.
  defp step(%{state: :processing_instruction_questionable, input: ""} = state) do
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :processing_instruction_questionable, input: _} = state) do
    state
    |> append_to_pi_data("?")
    |> continue(state: :processing_instruction_data)
  end

  # End tag open state - saw '</'
  defp step(%{state: :end_tag_open, input: <<c, rest::binary>>} = state) when is_ascii_alpha(c) do
    continue(state,
      state: :tag_name,
      input: <<c, rest::binary>>,
      token: {:end_tag, ""},
      attr_names: []
    )
  end

  defp step(%{state: :end_tag_open, input: <<?>, rest::binary>>} = state) do
    # Missing end tag name - parse error, ignore token
    state
    |> parse_error()
    |> continue(state: :data, input: rest)
  end

  defp step(%{state: :end_tag_open, input: ""} = state) do
    # eof-before-tag-name parse error
    state
    |> parse_error()
    |> emit_char("</", state: :data)
  end

  defp step(%{state: :end_tag_open, input: _} = state) do
    # invalid-first-character-of-tag-name parse error
    state
    |> parse_error()
    |> continue(state: :bogus_comment, token: {:comment, ""})
  end

  # Tag name state - reading the tag name
  defp step(%{state: :tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :before_attribute_name)
  end

  defp step(%{state: :tag_name, input: <<?/, rest::binary>>} = state) do
    continue(state, input: rest, state: :self_closing_start_tag)
  end

  defp step(%{state: :tag_name, input: <<?>, rest::binary>>} = state) do
    state
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :tag_name, input: <<c, rest::binary>>} = state) when is_ascii_upper(c) do
    # Uppercase - lowercase it
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_tag_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: ""} = state) do
    # EOF in tag - discard the incomplete tag (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :tag_name, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_tag_name(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Before attribute name state
  defp step(%{state: :before_attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: <<c, _::binary>>} = state)
       when c in ~c[/>] do
    continue(state, state: :after_attribute_name)
  end

  defp step(%{state: :before_attribute_name, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :before_attribute_name, input: <<?=, rest::binary>>} = state) do
    # unexpected-equals-sign-before-attribute-name parse error
    state
    |> parse_error()
    |> start_new_attribute("=")
    |> continue(state: :attribute_name, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: _} = state) do
    state
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Attribute name state
  defp step(%{state: :attribute_name, input: <<c, _::binary>>} = state)
       when c in ~c[\t\n\f />] do
    state
    |> finalize_attribute_name()
    |> continue(state: :after_attribute_name)
  end

  defp step(%{state: :attribute_name, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_name, input: <<?=, rest::binary>>} = state) do
    state
    |> finalize_attribute_name()
    |> continue(state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c + 32>>)
  end

  defp step(%{state: :attribute_name, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, buffer: state.buffer <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_name, input: <<c, rest::binary>>} = state)
       when c in [?", ?', ?<] do
    # unexpected-character-in-attribute-name parse error
    state
    |> parse_error()
    |> continue(input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :attribute_name, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, buffer: state.buffer <> <<c::utf8>>)
  end

  # After attribute name state
  defp step(%{state: :after_attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?/, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?=, rest::binary>>} = state) do
    continue(state, state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?>, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_name, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :after_attribute_name, input: _} = state) do
    state
    |> finalize_attribute_value()
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Before attribute value state
  defp step(%{state: :before_attribute_value, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?", rest::binary>>} = state) do
    continue(state, state: :attribute_value_double_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?', rest::binary>>} = state) do
    continue(state, state: :attribute_value_single_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?>, rest::binary>>} = state) do
    # missing-attribute-value parse error
    state
    |> parse_error()
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :before_attribute_value, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :before_attribute_value, input: _} = state) do
    continue(state, state: :attribute_value_unquoted)
  end

  # Attribute value (double-quoted) state
  defp step(%{state: :attribute_value_double_quoted, input: <<?", rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_double_quoted)
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_double_quoted, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # Attribute value (single-quoted) state
  defp step(%{state: :attribute_value_single_quoted, input: <<?', rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_single_quoted)
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_single_quoted, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # Attribute value (unquoted) state
  defp step(%{state: :attribute_value_unquoted, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    state
    |> finalize_attribute_value()
    |> continue(state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_unquoted)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<?>, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_unquoted, input: ""} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_unquoted, input: <<c, rest::binary>>} = state)
       when c in [?", ?', ?<, ?=, ?`] do
    # unexpected-character-in-unquoted-attribute-value parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<c>>)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # After attribute value (quoted) state
  defp step(%{state: :after_attribute_value_quoted, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: <<?>, rest::binary>>} = state) do
    state
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: ""} = state) do
    # eof-in-tag parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :after_attribute_value_quoted, input: _} = state) do
    # missing-whitespace-between-attributes parse error
    state
    |> parse_error()
    |> continue(state: :before_attribute_name)
  end

  # Self-closing start tag state
  defp step(
         %{state: :self_closing_start_tag, input: <<?>, rest::binary>>, token: {:end_tag, _}} =
           state
       ) do
    # end-tag-with-trailing-solidus parse error
    state
    |> parse_error()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :self_closing_start_tag, input: <<?>, rest::binary>>} = state) do
    state
    |> set_self_closing()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :self_closing_start_tag, input: ""} = state) do
    # eof-in-tag parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :self_closing_start_tag, input: _} = state) do
    # unexpected-solidus-in-tag parse error
    state
    |> parse_error()
    |> continue(state: :before_attribute_name)
  end

  # Markup declaration open state - after '<!'
  defp step(%{state: :markup_declaration_open, input: <<"--", rest::binary>>} = state) do
    continue(state, state: :comment_start, input: rest, token: {:comment, ""})
  end

  defp step(%{state: :markup_declaration_open, input: <<prefix::56, rest::binary>>} = state)
       when is_doctype(prefix) do
    continue(state, state: :doctype, input: rest)
  end

  # CDATA section - only recognized in foreign content (SVG/MathML)
  defp step(
         %{
           state: :markup_declaration_open,
           input: <<"[CDATA[", rest::binary>>,
           adjusted_current_node_not_in_html_namespace: true
         } = state
       ) do
    continue(state, state: :cdata_section, input: rest, buffer: "")
  end

  # CDATA in HTML content - treat as bogus comment
  defp step(
         %{
           state: :markup_declaration_open,
           input: <<"[CDATA[", rest::binary>>,
           adjusted_current_node_not_in_html_namespace: false
         } = state
       ) do
    # Parse error: cdata-in-html-content
    state
    |> parse_error()
    |> continue(state: :bogus_comment, input: rest, token: {:comment, "[CDATA["})
  end

  defp step(%{state: :markup_declaration_open, input: _} = state) do
    # incorrectly-opened-comment parse error
    state
    |> parse_error()
    |> continue(state: :bogus_comment, token: {:comment, ""})
  end

  # Comment start state
  defp step(%{state: :comment_start, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_start_dash, input: rest)
  end

  defp step(%{state: :comment_start, input: <<?>, rest::binary>>} = state) do
    # abrupt-closing-of-empty-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_start, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment start dash state
  defp step(%{state: :comment_start_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_start_dash, input: <<?>, rest::binary>>} = state) do
    # abrupt-closing-of-empty-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_start_dash, input: ""} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_start_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment state
  defp step(%{state: :comment, input: <<?<, rest::binary>>} = state) do
    state
    |> append_to_comment("<")
    |> continue(state: :comment_less_than_sign, input: rest)
  end

  defp step(%{state: :comment, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :comment, input: ""} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_comment(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Comment less-than sign state
  defp step(%{state: :comment_less_than_sign, input: <<?!, rest::binary>>} = state) do
    state
    |> append_to_comment("!")
    |> continue(state: :comment_less_than_sign_bang, input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: <<?<, rest::binary>>} = state) do
    state
    |> append_to_comment("<")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang state
  defp step(%{state: :comment_less_than_sign_bang, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang dash state
  defp step(%{state: :comment_less_than_sign_bang_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash, input: _} = state) do
    continue(state, state: :comment_end_dash)
  end

  # Comment less-than sign bang dash dash state
  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: <<?>, _::binary>>} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: ""} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: _} = state) do
    # Nested comment - parse error
    state
    |> parse_error()
    |> continue(state: :comment_end)
  end

  # Comment end dash state
  defp step(%{state: :comment_end_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_end_dash, input: ""} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment end state
  defp step(%{state: :comment_end, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :comment_end, input: <<?!, rest::binary>>} = state) do
    continue(state, state: :comment_end_bang, input: rest)
  end

  defp step(%{state: :comment_end, input: <<?-, rest::binary>>} = state) do
    state
    |> append_to_comment("-")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_end, input: ""} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end, input: _} = state) do
    state
    |> append_to_comment("--")
    |> continue(state: :comment)
  end

  # Comment end bang state
  defp step(%{state: :comment_end_bang, input: <<?-, rest::binary>>} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment_end_bang, input: <<?>, rest::binary>>} = state) do
    # incorrectly-closed-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_end_bang, input: ""} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end_bang, input: _} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment)
  end

  # DOCTYPE state
  defp step(%{state: :doctype, input: <<c, rest::binary>>} = state) when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_name, input: rest)
  end

  defp step(%{state: :doctype, input: <<?>, _::binary>>} = state) do
    continue(state, state: :before_doctype_name)
  end

  defp step(%{state: :doctype, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> with_force_quirks_doctype()
    |> emit()
  end

  defp step(%{state: :doctype, input: _} = state) do
    # missing-whitespace-before-doctype-name parse error
    state
    |> parse_error()
    |> continue(state: :before_doctype_name)
  end

  # Before DOCTYPE name state
  defp step(%{state: :before_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<c + 32>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<0xFFFD::utf8>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: <<?>, rest::binary>>} = state) do
    # missing-doctype-name parse error
    state
    |> parse_error()
    |> with_force_quirks_doctype()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_name, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> with_force_quirks_doctype()
    |> emit()
  end

  defp step(%{state: :before_doctype_name, input: <<c::utf8, rest::binary>>} = state) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<c::utf8>>, nil, nil, false}
    )
  end

  # DOCTYPE name state
  defp step(%{state: :doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :after_doctype_name)
  end

  defp step(%{state: :doctype_name, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_doctype_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :doctype_name, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_doctype_name(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE name state
  defp step(%{state: :after_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_name, input: <<prefix::48, rest::binary>>} = state)
       when is_public(prefix) do
    continue(state, state: :after_doctype_public_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: <<prefix::48, rest::binary>>} = state)
       when is_system(prefix) do
    continue(state, state: :after_doctype_system_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: _} = state) do
    # invalid-character-sequence-after-doctype-name parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE public keyword state
  defp step(%{state: :after_doctype_public_keyword, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_public_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?", rest::binary>>} = state) do
    # missing-whitespace-after-doctype-public-keyword parse error
    state
    |> parse_error()
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?', rest::binary>>} = state) do
    # missing-whitespace-after-doctype-public-keyword parse error
    state
    |> parse_error()
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?>, rest::binary>>} = state) do
    # missing-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_public_keyword, input: _} = state) do
    # missing-quote-before-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE public identifier state
  defp step(%{state: :before_doctype_public_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?>, rest::binary>>} = state) do
    # missing-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :before_doctype_public_identifier, input: _} = state) do
    # missing-quote-before-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE public identifier (double-quoted) state
  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<?", rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<0, rest::binary>>} = state
       ) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<?>, rest::binary>>} = state
       ) do
    # abrupt-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_double_quoted, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_public_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # DOCTYPE public identifier (single-quoted) state
  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<?', rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<0, rest::binary>>} = state
       ) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<?>, rest::binary>>} = state
       ) do
    # abrupt-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_single_quoted, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_public_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE public identifier state
  defp step(%{state: :after_doctype_public_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :between_doctype_public_and_system_identifiers, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?", rest::binary>>} = state) do
    # missing-whitespace-between-doctype-public-and-system-identifiers parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?', rest::binary>>} = state) do
    # missing-whitespace-between-doctype-public-and-system-identifiers parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_public_identifier, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Between DOCTYPE public and system identifiers state
  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<c, rest::binary>>} =
           state
       )
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?>, rest::binary>>} =
           state
       ) do
    emit(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?", rest::binary>>} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?', rest::binary>>} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE system keyword state
  defp step(%{state: :after_doctype_system_keyword, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_system_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?", rest::binary>>} = state) do
    # missing-whitespace-after-doctype-system-keyword parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?', rest::binary>>} = state) do
    # missing-whitespace-after-doctype-system-keyword parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?>, rest::binary>>} = state) do
    # missing-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_system_keyword, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE system identifier state
  defp step(%{state: :before_doctype_system_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?>, rest::binary>>} = state) do
    # missing-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :before_doctype_system_identifier, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE system identifier (double-quoted) state
  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<?", rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<0, rest::binary>>} = state
       ) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<?>, rest::binary>>} = state
       ) do
    # abrupt-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_double_quoted, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_system_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # DOCTYPE system identifier (single-quoted) state
  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<?', rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<0, rest::binary>>} = state
       ) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<?>, rest::binary>>} = state
       ) do
    # abrupt-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_single_quoted, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_system_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE system identifier state
  defp step(%{state: :after_doctype_system_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: ""} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_system_identifier, input: _} = state) do
    # unexpected-character-after-doctype-system-identifier parse error
    state
    |> parse_error()
    |> continue(state: :bogus_doctype)
  end

  # Bogus comment state
  defp step(%{state: :bogus_comment, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_comment, input: ""} = state) do
    emit(state)
  end

  defp step(%{state: :bogus_comment, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :bogus_comment, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_comment(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Bogus DOCTYPE state
  defp step(%{state: :bogus_doctype, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_doctype, input: ""} = state) do
    emit(state)
  end

  defp step(%{state: :bogus_doctype, input: <<0, rest::binary>>} = state) do
    # unexpected-null-character parse error; ignore the character
    state
    |> parse_error()
    |> continue(input: rest)
  end

  defp step(%{state: :bogus_doctype, input: <<_, rest::binary>>} = state) do
    continue(state, input: rest)
  end

  # CDATA section state - consume content until ]]>
  defp step(%{state: :cdata_section, input: <<"]]>", rest::binary>>, buffer: ""} = state) do
    # Empty CDATA - don't emit anything, just continue
    continue(state, state: :data, input: rest)
  end

  defp step(%{state: :cdata_section, input: <<"]]>", rest::binary>>} = state) do
    # End of CDATA - emit accumulated content as character token
    emit_char(state, state.buffer, state: :data, input: rest, buffer: "")
  end

  defp step(%{state: :cdata_section, input: <<"]", rest::binary>>} = state) do
    continue(state, state: :cdata_section_bracket, input: rest)
  end

  defp step(%{state: :cdata_section, input: "", buffer: ""} = state) do
    # eof-in-cdata parse error
    state
    |> parse_error()
    |> continue(state: :data)
  end

  defp step(%{state: :cdata_section, input: ""} = state) do
    # eof-in-cdata parse error
    state
    |> parse_error()
    |> emit_char(state.buffer, state: :data, buffer: "")
  end

  defp step(%{state: :cdata_section, input: <<0, rest::binary>>} = state) do
    # NUL in CDATA - pass through unchanged (unlike other states)
    continue(state, input: rest, buffer: state.buffer <> <<0>>)
  end

  defp step(%{state: :cdata_section, input: input} = state) do
    # Consume characters until ] or NUL or end
    {chars, rest} = chars_until_cdata(input)
    continue(state, input: rest, buffer: state.buffer <> chars)
  end

  defp step(%{state: :cdata_section_bracket, input: <<"]", rest::binary>>} = state) do
    continue(state, state: :cdata_section_end, input: rest)
  end

  defp step(%{state: :cdata_section_bracket, input: _} = state) do
    # Not ]], add the ] to buffer and continue
    continue(state, state: :cdata_section, buffer: state.buffer <> "]")
  end

  defp step(%{state: :cdata_section_end, input: <<"]", rest::binary>>} = state) do
    # Additional ] - keep accumulating
    continue(state, input: rest, buffer: state.buffer <> "]")
  end

  defp step(%{state: :cdata_section_end, input: <<?>, rest::binary>>, buffer: ""} = state) do
    # ]]> found with empty content - don't emit anything
    continue(state, state: :data, input: rest)
  end

  defp step(%{state: :cdata_section_end, input: <<?>, rest::binary>>} = state) do
    # ]]> found - emit content
    emit_char(state, state.buffer, state: :data, input: rest, buffer: "")
  end

  defp step(%{state: :cdata_section_end, input: _} = state) do
    # Not ]]>, add ]] to buffer and continue
    continue(state, state: :cdata_section, buffer: state.buffer <> "]]")
  end

  # Character reference state - handles &entities;
  defp step(%{state: :character_reference, input: <<"&#", rest::binary>>} = state) do
    continue(state, input: rest, buffer: "", state: :numeric_character_reference)
  end

  defp step(%{state: :character_reference, input: <<?&, next, _::binary>> = input} = state)
       when is_ascii_alpha(next) or is_ascii_digit(next) do
    case Entities.lookup(input) do
      {chars, rest} ->
        consume_named_entity(state, input, chars, rest)

      nil ->
        <<_, after_amp::binary>> = input

        state
        |> ambiguous_ampersand_error(after_amp)
        |> flush_char_ref("&", after_amp)
    end
  end

  defp step(%{state: :character_reference, input: <<?&, rest::binary>>} = state) do
    flush_char_ref(state, "&", rest)
  end

  # Numeric character reference state
  defp step(%{state: :numeric_character_reference, input: <<c, rest::binary>>} = state)
       when c in ~c[xX] do
    # Store the x/X in buffer to preserve case if we need to emit it as text
    continue(state, input: rest, buffer: <<c>>, state: :hexadecimal_character_reference_start)
  end

  defp step(%{state: :numeric_character_reference, input: _} = state) do
    continue(state, buffer: "", state: :decimal_character_reference_start)
  end

  # Decimal character reference start
  defp step(%{state: :decimal_character_reference_start, input: <<c, _::binary>>} = state)
       when is_ascii_digit(c) do
    continue(state, state: :decimal_character_reference)
  end

  defp step(%{state: :decimal_character_reference_start, input: _} = state) do
    # absence-of-digits-in-numeric-character-reference parse error
    state
    |> parse_error()
    |> emit_failed_char_ref("&#")
  end

  # Decimal character reference
  defp step(%{state: :decimal_character_reference, input: <<c, rest::binary>>} = state)
       when is_ascii_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :decimal_character_reference, input: <<?;, rest::binary>>} = state) do
    finish_numeric_char_ref(state, rest, 10)
  end

  defp step(%{state: :decimal_character_reference, input: _} = state) do
    # missing-semicolon-after-character-reference parse error
    state
    |> parse_error()
    |> finish_numeric_char_ref(state.input, 10)
  end

  # Hexadecimal character reference start
  defp step(%{state: :hexadecimal_character_reference_start, input: <<c, _::binary>>} = state)
       when is_ascii_hex_digit(c) do
    # Clear the x/X from buffer, start collecting digits
    continue(state, buffer: "", state: :hexadecimal_character_reference)
  end

  defp step(%{state: :hexadecimal_character_reference_start, input: _} = state) do
    # absence-of-digits-in-numeric-character-reference parse error
    state
    |> parse_error()
    |> emit_failed_char_ref("&#" <> state.buffer)
  end

  # Hexadecimal character reference
  defp step(%{state: :hexadecimal_character_reference, input: <<c, rest::binary>>} = state)
       when is_ascii_hex_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :hexadecimal_character_reference, input: <<?;, rest::binary>>} = state) do
    finish_numeric_char_ref(state, rest, 16)
  end

  defp step(%{state: :hexadecimal_character_reference, input: _} = state) do
    # missing-semicolon-after-character-reference parse error
    state
    |> parse_error()
    |> finish_numeric_char_ref(state.input, 16)
  end

  defp emit_failed_char_ref(state, prefix) do
    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          attr_value: state.attr_value <> prefix,
          state: state.return_state,
          return_state: nil
        )

      return_state ->
        emit_char(state, prefix, state: return_state, return_state: nil)
    end
  end

  # Windows-1252 replacements for 0x80-0x9F per HTML5 spec
  @windows_1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp finish_numeric_char_ref(state, rest, base) do
    codepoint = String.to_integer(state.buffer, base)
    state = check_numeric_char_ref(state, codepoint)
    char = codepoint_to_char(codepoint)

    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          input: rest,
          attr_value: state.attr_value <> char,
          state: state.return_state,
          return_state: nil,
          buffer: ""
        )

      return_state ->
        emit_char(state, char, input: rest, state: return_state, return_state: nil, buffer: "")
    end
  end

  # Check numeric character reference for parse errors per WHATWG spec
  defp check_numeric_char_ref(state, 0) do
    # null-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when is_outside_unicode_range(cp) do
    # character-reference-outside-unicode-range parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when is_surrogate(cp) do
    # surrogate-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when cp in 0x80..0x9F do
    # control-character-reference parse error (C1 controls, including those
    # not in the Windows-1252 replacement table: 0x81, 0x8D, 0x8F, 0x90, 0x9D)
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp)
       when cp in 0x01..0x08 or cp in 0x0E..0x1F or cp in [0x0B, 0x0D] do
    # control-character-reference parse error: "the number is 0x0D, or a
    # control that's not ASCII whitespace" (C0 except HT, LF, FF)
    parse_error(state)
  end

  defp check_numeric_char_ref(state, 0x7F) do
    # control-character-reference parse error (DEL)
    parse_error(state)
  end

  # Noncharacters: U+FDD0..U+FDEF, plus U+FFFE/U+FFFF in each of the 17 planes.
  defp check_numeric_char_ref(state, cp)
       when cp in 0xFDD0..0xFDEF or rem(cp, 0x10000) in [0xFFFE, 0xFFFF] do
    # noncharacter-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, _cp), do: state

  # --------------------------------------------------------------------------
  # Helper functions
  # --------------------------------------------------------------------------

  # Convert numeric character reference codepoint to UTF-8 char (per HTML5 spec)
  defp codepoint_to_char(0), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_outside_unicode_range(cp), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_surrogate(cp), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_map_key(@windows_1252, cp), do: <<@windows_1252[cp]::utf8>>
  defp codepoint_to_char(cp), do: <<cp::utf8>>

  # Specialized continue/2 clauses for common patterns (avoids struct! overhead)
  defp continue(state, state: new_state, input: new_input) do
    {:continue, %{state | state: new_state, input: new_input}}
  end

  defp continue(state, state: new_state) do
    {:continue, %{state | state: new_state}}
  end

  defp continue(state, input: new_input) do
    {:continue, %{state | input: new_input}}
  end

  defp continue(state, input: new_input, attr_value: new_attr_value) do
    {:continue, %{state | input: new_input, attr_value: new_attr_value}}
  end

  defp continue(state, state: new_state, return_state: new_return_state) do
    {:continue, %{state | state: new_state, return_state: new_return_state}}
  end

  defp continue(state, input: new_input, buffer: new_buffer) do
    {:continue, %{state | input: new_input, buffer: new_buffer}}
  end

  # Fallback for remaining patterns
  defp continue(state, updates) do
    {:continue, struct!(state, updates)}
  end

  defp emit(state), do: emit(state, [])

  # Common pattern: input: rest
  defp emit(state, input: new_input) do
    {:emit, state.token, %{state | state: :data, token: nil, input: new_input}}
  end

  defp emit(state, []) do
    {:emit, state.token, %{state | state: :data, token: nil}}
  end

  # Fallback with other updates
  defp emit(state, updates) do
    all_updates = Keyword.merge([state: :data, token: nil], updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  # Specialized emit_char/3 clauses for common patterns
  defp emit_char(state, char, state: new_state, input: new_input) do
    {:emit_char, char, %{state | state: new_state, input: new_input}}
  end

  defp emit_char(state, char, input: new_input) do
    {:emit_char, char, %{state | input: new_input}}
  end

  defp emit_char(state, char, state: new_state) do
    {:emit_char, char, %{state | state: new_state}}
  end

  # Fallback for remaining patterns
  defp emit_char(state, char, updates) do
    {:emit_char, char, struct!(state, updates)}
  end

  defp append_to_tag_name(%{token: {:start_tag, name, attrs, sc}} = state, char) do
    %{state | token: {:start_tag, name <> char, attrs, sc}}
  end

  defp append_to_tag_name(%{token: {:end_tag, name}} = state, char) do
    %{state | token: {:end_tag, name <> char}}
  end

  defp start_new_attribute(state, initial_char) do
    %{state | attr_name: initial_char, attr_value: "", buffer: "", duplicate_attr: false}
  end

  # "end-tag-with-attributes": counted once when the end tag is emitted.
  defp maybe_end_tag_with_attributes(%{token: {:end_tag, _}, attr_names: [_ | _]} = state) do
    parse_error(state)
  end

  defp maybe_end_tag_with_attributes(state), do: state

  # The duplicate check happens on leaving the attribute name state. A
  # duplicate stays the current attribute: its value is consumed, then dropped.
  defp finalize_attribute_name(state) do
    name = state.attr_name <> state.buffer

    if name in state.attr_names do
      parse_error(%{state | attr_name: name, buffer: "", duplicate_attr: true})
    else
      %{state | attr_name: name, buffer: "", attr_names: [name | state.attr_names]}
    end
  end

  defp finalize_attribute_value(%{attr_name: ""} = state), do: state

  defp finalize_attribute_value(%{duplicate_attr: true} = state) do
    %{state | attr_name: "", attr_value: "", duplicate_attr: false}
  end

  defp finalize_attribute_value(%{token: {:start_tag, name, attrs, sc}} = state) do
    attrs = [{state.attr_name, state.attr_value} | attrs]
    %{state | token: {:start_tag, name, attrs, sc}, attr_name: "", attr_value: ""}
  end

  # An end tag keeps no attributes; the names were recorded for the checks.
  defp finalize_attribute_value(%{token: {:end_tag, _}} = state) do
    %{state | attr_name: "", attr_value: ""}
  end

  defp set_self_closing(%{token: {:start_tag, name, attrs, _}} = state) do
    %{state | token: {:start_tag, name, attrs, true}}
  end

  defp set_self_closing(state), do: state

  defp reverse_start_tag_attrs({:start_tag, name, attrs, sc}) do
    {:start_tag, name, Enum.reverse(attrs), sc}
  end

  defp reverse_start_tag_attrs(token), do: token

  defp with_force_quirks_doctype(state) do
    %{state | token: {:doctype, nil, nil, nil, true}}
  end

  defp append_to_doctype_name(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, (name || "") <> char, pub, sys, quirks}}
  end

  defp set_force_quirks(%{token: {:doctype, name, pub, sys, _}} = state) do
    %{state | token: {:doctype, name, pub, sys, true}}
  end

  defp set_force_quirks(state), do: state

  defp set_doctype_public_id(%{token: {:doctype, name, _pub, sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, value, sys, quirks}}
  end

  defp append_to_doctype_public_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, (pub || "") <> char, sys, quirks}}
  end

  defp set_doctype_system_id(%{token: {:doctype, name, pub, _sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, pub, value, quirks}}
  end

  defp append_to_doctype_system_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, pub, (sys || "") <> char, quirks}}
  end

  defp append_to_comment(%{token: {:comment, data}} = state, char) do
    %{state | token: {:comment, data <> char}}
  end

  defp append_to_pi_data(%{token: {:pi, target, data}} = state, chunk) do
    %{state | token: {:pi, target, data <> chunk}}
  end

  # Comment data is "?" plus the temporary buffer; reconsume in bogus comment.
  defp convert_buffer_to_comment(%{buffer: buffer} = state) do
    continue(state, state: :bogus_comment, token: {:comment, "?" <> buffer}, buffer: "")
  end

  defp finish_pi_target(%{buffer: target} = state) do
    down = String.downcase(target, :ascii)

    if down == "xml" or down == "xml-stylesheet" do
      state
      |> parse_error()
      |> convert_buffer_to_comment()
    else
      continue(state,
        state: :after_processing_instruction_target,
        token: {:pi, target, ""},
        buffer: ""
      )
    end
  end

  defp maybe_update_last_start_tag(%{token: {:start_tag, name, _, _}} = state) do
    %{state | last_start_tag: name}
  end

  defp maybe_update_last_start_tag(state), do: state

  defp appropriate_end_tag?(%{token: {:end_tag, name}, last_start_tag: last}) do
    name == last
  end

  defp appropriate_end_tag?(_state), do: false

  defp emit_end_tag_buffer(state, next_state, rest) do
    emit_char(state, "</" <> state.buffer, state: next_state, token: nil, input: rest)
  end

  defp flush_char_ref(%{return_state: return_state} = state, chars, rest)
       when is_attribute_value_state(return_state) do
    continue(state,
      input: rest,
      attr_value: state.attr_value <> chars,
      state: return_state,
      return_state: nil
    )
  end

  defp flush_char_ref(state, chars, rest) do
    emit_char(state, chars, input: rest, state: state.return_state, return_state: nil)
  end

  defp consume_named_entity(state, input, chars, rest) do
    has_semicolon? = entity_has_semicolon?(input, rest)

    if consumable_entity?(state.return_state, has_semicolon?, rest) do
      # missing-semicolon-after-character-reference parse error
      state = if has_semicolon?, do: state, else: parse_error(state)
      flush_char_ref(state, chars, rest)
    else
      <<_, after_amp::binary>> = input
      flush_char_ref(state, "&", after_amp)
    end
  end

  # Ambiguous ampersand state: the alphanumerics after the ampersand go back to
  # the return state as ordinary characters. Only a semicolon ending that run
  # is an unknown-named-character-reference parse error.
  defp ambiguous_ampersand_error(state, input) do
    case skip_ascii_alphanumerics(input) do
      <<?;, _::binary>> -> parse_error(state)
      _ -> state
    end
  end

  defp skip_ascii_alphanumerics(<<c, rest::binary>>) when is_ascii_alpha(c) or is_ascii_digit(c),
    do: skip_ascii_alphanumerics(rest)

  defp skip_ascii_alphanumerics(rest), do: rest

  # The matched text is the prefix of input that Entities.lookup consumed.
  # Legacy references like "&amp" match without a terminating semicolon.
  defp entity_has_semicolon?(input, rest) do
    matched_len = byte_size(input) - byte_size(rest)
    <<matched::binary-size(^matched_len), _::binary>> = input
    String.ends_with?(matched, ";")
  end

  # Per HTML5 spec: in attribute values, legacy entities (no semicolon) followed
  # by = or alphanumeric should NOT be consumed (to preserve URLs like ?a=1&lang=en)
  defp consumable_entity?(return_state, has_semicolon?, rest)
       when is_attribute_value_state(return_state) do
    legacy_follows_problematic_char? =
      case rest do
        <<?=, _::binary>> -> true
        <<c, _::binary>> when is_ascii_digit(c) or is_ascii_alpha(c) -> true
        _ -> false
      end

    has_semicolon? or not legacy_follows_problematic_char?
  end

  defp consumable_entity?(_, _, _), do: true

  # Read characters until we hit one of the stop characters
  # Returns {collected_chars, remaining_input}
  # Specialized functions with guards for each stop set (faster than Enum.member?)

  # Data state: stop on <, &, or null
  # Uses multi-byte scanning with guards for better performance on long text runs
  defguardp is_data_safe(c) when c != ?< and c != ?& and c != 0 and c < 128

  defp chars_until_data(input), do: chars_until_data(input, [])

  # 8-byte fast path - processes 8 ASCII chars per function call
  defp chars_until_data(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when is_data_safe(a) and is_data_safe(b) and is_data_safe(c) and is_data_safe(d) and
              is_data_safe(e) and is_data_safe(f) and is_data_safe(g) and is_data_safe(h) do
    chars_until_data(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # 4-byte path
  defp chars_until_data(<<a, b, c, d, rest::binary>>, acc)
       when is_data_safe(a) and is_data_safe(b) and is_data_safe(c) and is_data_safe(d) do
    chars_until_data(rest, [<<a, b, c, d>> | acc])
  end

  # 2-byte path
  defp chars_until_data(<<a, b, rest::binary>>, acc)
       when is_data_safe(a) and is_data_safe(b) do
    chars_until_data(rest, [<<a, b>> | acc])
  end

  # 1-byte ASCII path (handles tail bytes before delimiter/UTF-8)
  defp chars_until_data(<<c, rest::binary>>, acc) when is_data_safe(c) do
    chars_until_data(rest, [c | acc])
  end

  # Stop on delimiter
  defp chars_until_data(<<c, _::binary>> = input, acc) when c == ?< or c == ?& or c == 0 do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), input}
  end

  # UTF-8 multibyte characters (>= 128 leading byte)
  defp chars_until_data(<<c::utf8, rest::binary>>, acc) do
    chars_until_data(rest, [<<c::utf8>> | acc])
  end

  # Fallback for invalid UTF-8 bytes
  defp chars_until_data(<<c, rest::binary>>, acc) do
    chars_until_data(rest, [c | acc])
  end

  # End of input
  defp chars_until_data("", acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), ""}
  end

  # Rawtext/script: stop on < or null
  # Uses multi-byte scanning with guards for better performance
  defguardp is_rawtext_safe(c) when c != ?< and c != 0 and c < 128

  defp chars_until_rawtext(input), do: chars_until_rawtext(input, [])

  # 8-byte fast path
  defp chars_until_rawtext(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when is_rawtext_safe(a) and is_rawtext_safe(b) and is_rawtext_safe(c) and
              is_rawtext_safe(d) and is_rawtext_safe(e) and is_rawtext_safe(f) and
              is_rawtext_safe(g) and is_rawtext_safe(h) do
    chars_until_rawtext(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # 4-byte path
  defp chars_until_rawtext(<<a, b, c, d, rest::binary>>, acc)
       when is_rawtext_safe(a) and is_rawtext_safe(b) and is_rawtext_safe(c) and
              is_rawtext_safe(d) do
    chars_until_rawtext(rest, [<<a, b, c, d>> | acc])
  end

  # 2-byte path
  defp chars_until_rawtext(<<a, b, rest::binary>>, acc)
       when is_rawtext_safe(a) and is_rawtext_safe(b) do
    chars_until_rawtext(rest, [<<a, b>> | acc])
  end

  # 1-byte ASCII path
  defp chars_until_rawtext(<<c, rest::binary>>, acc) when is_rawtext_safe(c) do
    chars_until_rawtext(rest, [c | acc])
  end

  # Stop on delimiter
  defp chars_until_rawtext(<<c, _::binary>> = input, acc) when c == ?< or c == 0 do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), input}
  end

  # UTF-8 multibyte characters
  defp chars_until_rawtext(<<c::utf8, rest::binary>>, acc) do
    chars_until_rawtext(rest, [<<c::utf8>> | acc])
  end

  # Fallback for invalid UTF-8 bytes
  defp chars_until_rawtext(<<c, rest::binary>>, acc) do
    chars_until_rawtext(rest, [c | acc])
  end

  # End of input
  defp chars_until_rawtext("", acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), ""}
  end

  # Plaintext/CDATA: stop on null only
  # Uses multi-byte scanning with guards for better performance
  defguardp is_null_safe(c) when c != 0 and c < 128

  defp chars_until_null(input), do: chars_until_null(input, [])

  # 8-byte fast path
  defp chars_until_null(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when is_null_safe(a) and is_null_safe(b) and is_null_safe(c) and is_null_safe(d) and
              is_null_safe(e) and is_null_safe(f) and is_null_safe(g) and is_null_safe(h) do
    chars_until_null(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # 4-byte path
  defp chars_until_null(<<a, b, c, d, rest::binary>>, acc)
       when is_null_safe(a) and is_null_safe(b) and is_null_safe(c) and is_null_safe(d) do
    chars_until_null(rest, [<<a, b, c, d>> | acc])
  end

  # 2-byte path
  defp chars_until_null(<<a, b, rest::binary>>, acc)
       when is_null_safe(a) and is_null_safe(b) do
    chars_until_null(rest, [<<a, b>> | acc])
  end

  # 1-byte ASCII path
  defp chars_until_null(<<c, rest::binary>>, acc) when is_null_safe(c) do
    chars_until_null(rest, [c | acc])
  end

  # Stop on null
  defp chars_until_null(<<0, _::binary>> = input, acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), input}
  end

  # UTF-8 multibyte characters
  defp chars_until_null(<<c::utf8, rest::binary>>, acc) do
    chars_until_null(rest, [<<c::utf8>> | acc])
  end

  # Fallback for invalid UTF-8 bytes
  defp chars_until_null(<<c, rest::binary>>, acc) do
    chars_until_null(rest, [c | acc])
  end

  # End of input
  defp chars_until_null("", acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), ""}
  end

  # Comment: stop on -, <, or null
  # Uses multi-byte scanning with guards for better performance
  defguardp is_comment_safe(c) when c != ?- and c != ?< and c != 0 and c < 128

  defp chars_until_comment(input), do: chars_until_comment(input, [])

  # 8-byte fast path
  defp chars_until_comment(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when is_comment_safe(a) and is_comment_safe(b) and is_comment_safe(c) and
              is_comment_safe(d) and is_comment_safe(e) and is_comment_safe(f) and
              is_comment_safe(g) and is_comment_safe(h) do
    chars_until_comment(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # 4-byte path
  defp chars_until_comment(<<a, b, c, d, rest::binary>>, acc)
       when is_comment_safe(a) and is_comment_safe(b) and is_comment_safe(c) and
              is_comment_safe(d) do
    chars_until_comment(rest, [<<a, b, c, d>> | acc])
  end

  # 2-byte path
  defp chars_until_comment(<<a, b, rest::binary>>, acc)
       when is_comment_safe(a) and is_comment_safe(b) do
    chars_until_comment(rest, [<<a, b>> | acc])
  end

  # 1-byte ASCII path
  defp chars_until_comment(<<c, rest::binary>>, acc) when is_comment_safe(c) do
    chars_until_comment(rest, [c | acc])
  end

  # Stop on delimiter
  defp chars_until_comment(<<c, _::binary>> = input, acc) when c == ?- or c == ?< or c == 0 do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), input}
  end

  # UTF-8 multibyte characters
  defp chars_until_comment(<<c::utf8, rest::binary>>, acc) do
    chars_until_comment(rest, [<<c::utf8>> | acc])
  end

  # Fallback for invalid UTF-8 bytes
  defp chars_until_comment(<<c, rest::binary>>, acc) do
    chars_until_comment(rest, [c | acc])
  end

  # End of input
  defp chars_until_comment("", acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), ""}
  end

  # CDATA: stop on ] or null
  # Uses multi-byte scanning with guards for better performance
  defguardp is_cdata_safe(c) when c != ?] and c != 0 and c < 128

  defp chars_until_cdata(input), do: chars_until_cdata(input, [])

  # 8-byte fast path
  defp chars_until_cdata(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when is_cdata_safe(a) and is_cdata_safe(b) and is_cdata_safe(c) and is_cdata_safe(d) and
              is_cdata_safe(e) and is_cdata_safe(f) and is_cdata_safe(g) and is_cdata_safe(h) do
    chars_until_cdata(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # 4-byte path
  defp chars_until_cdata(<<a, b, c, d, rest::binary>>, acc)
       when is_cdata_safe(a) and is_cdata_safe(b) and is_cdata_safe(c) and is_cdata_safe(d) do
    chars_until_cdata(rest, [<<a, b, c, d>> | acc])
  end

  # 2-byte path
  defp chars_until_cdata(<<a, b, rest::binary>>, acc)
       when is_cdata_safe(a) and is_cdata_safe(b) do
    chars_until_cdata(rest, [<<a, b>> | acc])
  end

  # 1-byte ASCII path
  defp chars_until_cdata(<<c, rest::binary>>, acc) when is_cdata_safe(c) do
    chars_until_cdata(rest, [c | acc])
  end

  # Stop on delimiter
  defp chars_until_cdata(<<c, _::binary>> = input, acc) when c == ?] or c == 0 do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), input}
  end

  # UTF-8 multibyte characters
  defp chars_until_cdata(<<c::utf8, rest::binary>>, acc) do
    chars_until_cdata(rest, [<<c::utf8>> | acc])
  end

  # End of input
  defp chars_until_cdata("", acc) do
    {acc |> :lists.reverse() |> IO.iodata_to_binary(), ""}
  end

  # Single-pass newline normalization: CRLF → LF, CR → LF
  # More efficient than two String.replace calls
  defp normalize_newlines(input), do: normalize_newlines(input, [])

  # 8-byte fast path for ASCII without CR
  defp normalize_newlines(<<a, b, c, d, e, f, g, h, rest::binary>>, acc)
       when a != ?\r and b != ?\r and c != ?\r and d != ?\r and
              e != ?\r and f != ?\r and g != ?\r and h != ?\r do
    normalize_newlines(rest, [<<a, b, c, d, e, f, g, h>> | acc])
  end

  # CRLF → LF
  defp normalize_newlines(<<"\r\n", rest::binary>>, acc) do
    normalize_newlines(rest, [?\n | acc])
  end

  # Lone CR → LF
  defp normalize_newlines(<<"\r", rest::binary>>, acc) do
    normalize_newlines(rest, [?\n | acc])
  end

  # Regular byte
  defp normalize_newlines(<<c, rest::binary>>, acc) do
    normalize_newlines(rest, [c | acc])
  end

  # End of input
  defp normalize_newlines(<<>>, acc) do
    acc |> :lists.reverse() |> IO.iodata_to_binary()
  end

  defp preprocess_error_count(input), do: preprocess_error_count(input, 0)

  defp preprocess_error_count(<<cp::utf8, rest::binary>>, n) when is_input_stream_error(cp) do
    preprocess_error_count(rest, n + 1)
  end

  defp preprocess_error_count(<<_::utf8, rest::binary>>, n), do: preprocess_error_count(rest, n)
  defp preprocess_error_count(<<>>, n), do: n

  # Decode as UTF-8 with U+FFFD replacement, matching the spec input stream.
  defp utf8_with_replacement(input) do
    case :unicode.characters_to_binary(input, :utf8, :utf8) do
      out when is_binary(out) -> out
      {:error, good, rest} -> replace_invalid_utf8(good, rest)
      {:incomplete, good, rest} -> good <> incomplete_utf8_replacements(rest)
    end
  end

  defp replace_invalid_utf8(good, <<>>) do
    good
  end

  defp replace_invalid_utf8(good, <<_bad, rest::binary>>) do
    good <> <<0xFFFD::utf8>> <> utf8_with_replacement(rest)
  end

  defp incomplete_utf8_replacements(rest) do
    String.duplicate(<<0xFFFD::utf8>>, byte_size(rest))
  end
end
