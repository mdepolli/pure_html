defmodule PureHtml.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a stream of tokens.

  This module can be tested independently against html5lib tree-construction tests.
  """

  alias PureHtml.Document

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @head_elements ~w(base basefont bgsound link meta noframes noscript script style template title)

  # SVG tag name case adjustments (per HTML5 spec)
  @svg_tag_adjustments %{
    "altglyph" => "altGlyph",
    "altglyphdef" => "altGlyphDef",
    "altglyphitem" => "altGlyphItem",
    "animatecolor" => "animateColor",
    "animatemotion" => "animateMotion",
    "animatetransform" => "animateTransform",
    "clippath" => "clipPath",
    "feblend" => "feBlend",
    "fecolormatrix" => "feColorMatrix",
    "fecomponenttransfer" => "feComponentTransfer",
    "fecomposite" => "feComposite",
    "feconvolvematrix" => "feConvolveMatrix",
    "fediffuselighting" => "feDiffuseLighting",
    "fedisplacementmap" => "feDisplacementMap",
    "fedistantlight" => "feDistantLight",
    "feflood" => "feFlood",
    "fefunca" => "feFuncA",
    "fefuncb" => "feFuncB",
    "fefuncg" => "feFuncG",
    "fefuncr" => "feFuncR",
    "fegaussianblur" => "feGaussianBlur",
    "feimage" => "feImage",
    "femerge" => "feMerge",
    "femergenode" => "feMergeNode",
    "femorphology" => "feMorphology",
    "feoffset" => "feOffset",
    "fepointlight" => "fePointLight",
    "fespecularlighting" => "feSpecularLighting",
    "fespotlight" => "feSpotLight",
    "fetile" => "feTile",
    "feturbulence" => "feTurbulence",
    "foreignobject" => "foreignObject",
    "glyphref" => "glyphRef",
    "lineargradient" => "linearGradient",
    "radialgradient" => "radialGradient",
    "textpath" => "textPath"
  }

  # SVG attribute name case adjustments
  @svg_attr_adjustments %{
    "attributename" => "attributeName",
    "attributetype" => "attributeType",
    "basefrequency" => "baseFrequency",
    "baseprofile" => "baseProfile",
    "calcmode" => "calcMode",
    "clippathunits" => "clipPathUnits",
    "diffuseconstant" => "diffuseConstant",
    "edgemode" => "edgeMode",
    "filterunits" => "filterUnits",
    "glyphref" => "glyphRef",
    "gradienttransform" => "gradientTransform",
    "gradientunits" => "gradientUnits",
    "kernelmatrix" => "kernelMatrix",
    "kernelunitlength" => "kernelUnitLength",
    "keypoints" => "keyPoints",
    "keysplines" => "keySplines",
    "keytimes" => "keyTimes",
    "lengthadjust" => "lengthAdjust",
    "limitingconeangle" => "limitingConeAngle",
    "markerheight" => "markerHeight",
    "markerunits" => "markerUnits",
    "markerwidth" => "markerWidth",
    "maskcontentunits" => "maskContentUnits",
    "maskunits" => "maskUnits",
    "numoctaves" => "numOctaves",
    "pathlength" => "pathLength",
    "patterncontentunits" => "patternContentUnits",
    "patterntransform" => "patternTransform",
    "patternunits" => "patternUnits",
    "pointsatx" => "pointsAtX",
    "pointsaty" => "pointsAtY",
    "pointsatz" => "pointsAtZ",
    "preservealpha" => "preserveAlpha",
    "preserveaspectratio" => "preserveAspectRatio",
    "primitiveunits" => "primitiveUnits",
    "refx" => "refX",
    "refy" => "refY",
    "repeatcount" => "repeatCount",
    "repeatdur" => "repeatDur",
    "requiredextensions" => "requiredExtensions",
    "requiredfeatures" => "requiredFeatures",
    "specularconstant" => "specularConstant",
    "specularexponent" => "specularExponent",
    "spreadmethod" => "spreadMethod",
    "startoffset" => "startOffset",
    "stddeviation" => "stdDeviation",
    "stitchtiles" => "stitchTiles",
    "surfacescale" => "surfaceScale",
    "systemlanguage" => "systemLanguage",
    "tablevalues" => "tableValues",
    "targetx" => "targetX",
    "targety" => "targetY",
    "textlength" => "textLength",
    "viewbox" => "viewBox",
    "viewtarget" => "viewTarget",
    "xchannelselector" => "xChannelSelector",
    "ychannelselector" => "yChannelSelector",
    "zoomandpan" => "zoomAndPan"
  }

  # MathML attribute name case adjustments
  @mathml_attr_adjustments %{
    "definitionurl" => "definitionURL"
  }

  # HTML integration points - SVG/MathML elements that can contain HTML
  @html_integration_points MapSet.new([
    {"svg", "foreignObject"},
    {"svg", "desc"},
    {"svg", "title"},
    {"math", "annotation-xml"}
  ])

  # MathML text integration points
  @mathml_text_integration_points MapSet.new([
    {"math", "mi"},
    {"math", "mo"},
    {"math", "mn"},
    {"math", "ms"},
    {"math", "mtext"}
  ])

  # Elements that cause breakout from foreign content
  @foreign_breakout_elements MapSet.new(~w(
    b big blockquote body br center code dd div dl dt em embed
    h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr
    ol p pre ruby s small span strong strike sub sup table tt u ul var
  ))

  # Elements that implicitly close an open <p> element
  @closes_p ~w(address article aside blockquote center details dialog dir div dl
               fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header
               hgroup hr listing main menu nav ol p plaintext pre section summary table ul xmp)

  # Formatting elements subject to the adoption agency algorithm
  @formatting_elements ~w(a b big code em font i nobr s small strike strong tt u)

  # Special elements that are scope boundaries for adoption agency
  @special_elements ~w(address applet area article aside base basefont bgsound blockquote
                       body br button caption center col colgroup dd details dir div dl dt
                       embed fieldset figcaption figure footer form frame frameset h1 h2 h3
                       h4 h5 h6 head header hgroup hr html iframe img input keygen li link
                       listing main marquee menu meta nav noembed noframes noscript object
                       ol p param plaintext pre script section select source style summary
                       table tbody td template textarea tfoot th thead title tr track ul wbr xmp)

  defstruct [:document, :stack, :head_id, :body_id, :strip_next_newline, :active_formatting]

  @type t :: %__MODULE__{
          document: Document.t(),
          stack: [non_neg_integer()],
          head_id: non_neg_integer() | nil,
          body_id: non_neg_integer() | nil,
          strip_next_newline: boolean(),
          active_formatting: list()
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
      strip_next_newline: false,
      active_formatting: []
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

  # SVG and MathML foreign content
  defp process(state, {:start_tag, "svg", attrs, self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> ensure_body()
    |> insert_element("svg", attrs, self_closing?, &(stack_first_id(&1.stack) || &1.body_id), "svg")
  end

  defp process(state, {:start_tag, "math", attrs, self_closing?}) do
    state
    |> ensure_html(%{})
    |> ensure_head()
    |> ensure_body()
    |> insert_element("math", attrs, self_closing?, &(stack_first_id(&1.stack) || &1.body_id), "math")
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

  defp process(state, {:end_tag, tag}) when tag in @formatting_elements do
    run_adoption_agency(state, tag)
  end

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

  defp insert_element(state, tag, attrs, self_closing?, parent_fn, namespace \\ nil) do
    parent_id = parent_fn.(state)
    parent_id = adjust_for_template(state.document, parent_id)

    # Get inherited namespace context
    inherited_ns = get_inherited_namespace(state)

    # Check if we're at an HTML integration point or if this is a breakout element
    {tag, attrs, namespace} =
      cond do
        # Explicit SVG namespace provided (for svg root element)
        namespace == "svg" ->
          adjusted_tag = Map.get(@svg_tag_adjustments, tag, tag)
          adjusted_attrs = adjust_svg_attributes(attrs)
          {adjusted_tag, adjusted_attrs, "svg"}

        # Explicit MathML namespace provided (for math root element)
        namespace == "math" ->
          adjusted_attrs = adjust_mathml_attributes(attrs)
          {tag, adjusted_attrs, "math"}

        # No inherited namespace - regular HTML
        inherited_ns == nil ->
          {tag, attrs, nil}

        # In SVG/MathML but at an integration point - check for breakout
        in_html_integration_point?(state) and MapSet.member?(@foreign_breakout_elements, tag) ->
          # Breakout to HTML - no namespace
          {tag, attrs, nil}

        # In MathML text integration point - check for breakout
        in_mathml_text_integration_point?(state) and MapSet.member?(@foreign_breakout_elements, tag) ->
          # Breakout to HTML - no namespace
          {tag, attrs, nil}

        # In SVG namespace - apply SVG adjustments
        inherited_ns == "svg" ->
          adjusted_tag = Map.get(@svg_tag_adjustments, tag, tag)
          adjusted_attrs = adjust_svg_attributes(attrs)
          {adjusted_tag, adjusted_attrs, "svg"}

        # In MathML namespace - apply MathML adjustments
        inherited_ns == "math" ->
          adjusted_attrs = adjust_mathml_attributes(attrs)
          {tag, adjusted_attrs, "math"}

        # Other foreign namespace - inherit as-is
        true ->
          {tag, attrs, inherited_ns}
      end

    {document, node_id} = Document.add_element(state.document, tag, attrs, parent_id, namespace)

    stack =
      if self_closing? or tag in @void_elements, do: state.stack, else: [node_id | state.stack]

    # Track formatting elements for adoption agency
    active_formatting =
      if tag in @formatting_elements and not self_closing? do
        [{node_id, tag, attrs} | state.active_formatting]
      else
        state.active_formatting
      end

    %{state | document: document, stack: stack, active_formatting: active_formatting}
  end

  defp get_inherited_namespace(state) do
    # Check if current element is in a foreign namespace
    case state.stack do
      [current | _] ->
        current_id = stack_entry_id(current)
        node = Document.get_node(state.document, current_id)
        node[:namespace]
      [] ->
        nil
    end
  end

  # Check if current element is an HTML integration point
  defp in_html_integration_point?(state) do
    case state.stack do
      [current | _] ->
        current_id = stack_entry_id(current)
        node = Document.get_node(state.document, current_id)
        ns = node[:namespace]
        tag = node.tag
        MapSet.member?(@html_integration_points, {ns, tag})
      [] ->
        false
    end
  end

  # Check if current element is a MathML text integration point
  defp in_mathml_text_integration_point?(state) do
    case state.stack do
      [current | _] ->
        current_id = stack_entry_id(current)
        node = Document.get_node(state.document, current_id)
        ns = node[:namespace]
        tag = node.tag
        MapSet.member?(@mathml_text_integration_points, {ns, tag})
      [] ->
        false
    end
  end

  # Adjust SVG attribute names to proper case
  defp adjust_svg_attributes(attrs) do
    Map.new(attrs, fn {name, value} ->
      adjusted_name = Map.get(@svg_attr_adjustments, name, name)
      {adjusted_name, value}
    end)
  end

  # Adjust MathML attribute names to proper case
  defp adjust_mathml_attributes(attrs) do
    Map.new(attrs, fn {name, value} ->
      adjusted_name = Map.get(@mathml_attr_adjustments, name, name)
      {adjusted_name, value}
    end)
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

  # Adoption Agency Algorithm
  # See: https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm

  defp run_adoption_agency(state, subject) do
    # Step 1: If current node is the subject and not in active formatting, just pop it
    case state.stack do
      [current | _rest] ->
        current_id = stack_entry_id(current)
        current_node = Document.get_node(state.document, current_id)

        if current_node.tag == subject and not has_active_formatting?(state, subject) do
          case close_until(state.stack, state.document, subject) do
            {:found, new_stack} -> %{state | stack: new_stack}
            :not_found -> state
          end
        else
          adoption_agency_outer_loop(state, subject, 0)
        end

      [] ->
        state
    end
  end

  defp has_active_formatting?(state, tag) do
    Enum.any?(state.active_formatting, fn
      {_id, t, _attrs} -> t == tag
      :marker -> false
    end)
  end

  defp adoption_agency_outer_loop(state, _subject, 8), do: state

  defp adoption_agency_outer_loop(state, subject, iteration) do
    # Step 3: Find formatting element in active formatting list
    case find_formatting_element_index(state.active_formatting, subject) do
      nil ->
        # No formatting element - done
        state

      fe_af_index ->
        {fe_id, fe_tag, fe_attrs} = Enum.at(state.active_formatting, fe_af_index)

        # Step 4: Check if formatting element is in open elements
        case find_in_stack(state.stack, fe_id) do
          nil ->
            # Not in stack - remove from active formatting and return
            new_af = List.delete_at(state.active_formatting, fe_af_index)
            %{state | active_formatting: new_af}

          fe_stack_index ->
            # Step 7: Find furthest block
            case find_furthest_block(state.stack, state.document, fe_stack_index) do
              nil ->
                # No furthest block - pop until formatting element inclusive
                new_stack = Enum.drop(state.stack, fe_stack_index + 1)
                new_af = List.delete_at(state.active_formatting, fe_af_index)
                %{state | stack: new_stack, active_formatting: new_af}

              fb_stack_index ->
                # Complex case - run the full algorithm
                state = run_adoption_agency_inner(
                  state, subject,
                  {fe_id, fe_tag, fe_attrs}, fe_af_index, fe_stack_index,
                  fb_stack_index
                )
                # Continue outer loop
                adoption_agency_outer_loop(state, subject, iteration + 1)
            end
        end
    end
  end

  defp find_formatting_element_index(active_formatting, tag) do
    Enum.find_index(active_formatting, fn
      {_id, t, _attrs} -> t == tag
      :marker -> false
    end)
  end

  defp find_in_stack(stack, target_id) do
    Enum.find_index(stack, fn entry ->
      stack_entry_id(entry) == target_id
    end)
  end

  defp find_furthest_block(stack, document, fe_stack_index) do
    # Look for the first special element between top of stack and formatting element
    stack
    |> Enum.take(fe_stack_index)
    |> Enum.with_index()
    |> Enum.find(fn {entry, _idx} ->
      node = Document.get_node(document, stack_entry_id(entry))
      node.tag in @special_elements
    end)
    |> case do
      nil -> nil
      {_entry, idx} -> idx
    end
  end

  defp run_adoption_agency_inner(state, _subject, {fe_id, fe_tag, fe_attrs}, fe_af_index, fe_stack_index, fb_stack_index) do
    fb_id = stack_entry_id(Enum.at(state.stack, fb_stack_index))

    # Step 8: Bookmark starts after formatting element in active formatting
    bookmark = fe_af_index + 1

    # Step 9: node = last_node = furthest_block
    # Step 10: Inner loop - restructure nodes between furthest block and formatting element
    {state, last_node_id, bookmark} =
      run_inner_loop(state, fe_id, fe_stack_index, fb_stack_index, fb_id, bookmark, 0)

    # Step 11: Insert last_node into common ancestor
    common_ancestor_id =
      case Enum.at(state.stack, fe_stack_index + 1) do
        nil -> state.body_id
        entry -> stack_entry_id(entry)
      end

    # Remove last_node from its current parent and append to common ancestor
    document = Document.remove_from_parent(state.document, last_node_id)
    document = Document.append_child(document, common_ancestor_id, last_node_id)

    # Step 12: Create new formatting element
    {document, new_fe_id} = Document.add_element(document, fe_tag, fe_attrs, nil)

    # Step 13: Move all children of furthest block to new formatting element
    document = Document.move_children(document, fb_id, new_fe_id)

    # Append new formatting element to furthest block
    document = Document.append_child(document, fb_id, new_fe_id)

    # Step 14: Update active formatting list
    # Remove old formatting element entry
    new_af = List.delete_at(state.active_formatting, fe_af_index)
    # Adjust bookmark if needed
    bookmark = if fe_af_index < bookmark, do: bookmark - 1, else: bookmark
    # Insert new entry at bookmark
    new_af = List.insert_at(new_af, bookmark, {new_fe_id, fe_tag, fe_attrs})

    # Step 15: Update open elements stack
    # Remove old formatting element
    new_stack = Enum.reject(state.stack, fn entry -> stack_entry_id(entry) == fe_id end)
    # Insert new formatting element after furthest block
    # Find new position of furthest block
    fb_new_index = Enum.find_index(new_stack, fn entry -> stack_entry_id(entry) == fb_id end)
    new_stack = List.insert_at(new_stack, fb_new_index, new_fe_id)

    %{state | document: document, stack: new_stack, active_formatting: new_af}
  end

  defp run_inner_loop(state, _fe_id, _fe_stack_index, _fb_stack_index, last_node_id, bookmark, counter) when counter >= 3 do
    # After 3 iterations, we're done with the inner loop for simplicity
    # The full spec allows continuing but removes nodes from active formatting
    {state, last_node_id, bookmark}
  end

  defp run_inner_loop(state, fe_id, fe_stack_index, fb_stack_index, last_node_id, bookmark, counter) do
    # Find node above last_node in stack (moving toward formatting element)
    last_node_stack_index = find_in_stack(state.stack, last_node_id)

    if last_node_stack_index == nil or last_node_stack_index >= fe_stack_index do
      # Reached formatting element or error
      {state, last_node_id, bookmark}
    else
      node_stack_index = last_node_stack_index + 1
      node_entry = Enum.at(state.stack, node_stack_index)
      node_id = stack_entry_id(node_entry)

      if node_id == fe_id do
        # Reached formatting element - done with inner loop
        {state, last_node_id, bookmark}
      else
        # Check if node is in active formatting
        node_af_index = Enum.find_index(state.active_formatting, fn
          {id, _, _} -> id == node_id
          :marker -> false
        end)

        cond do
          counter > 3 and node_af_index != nil ->
            # Remove from active formatting
            new_af = List.delete_at(state.active_formatting, node_af_index)
            bookmark = if node_af_index < bookmark, do: bookmark - 1, else: bookmark
            state = %{state | active_formatting: new_af}
            # Also remove from stack and continue
            new_stack = List.delete_at(state.stack, node_stack_index)
            state = %{state | stack: new_stack}
            run_inner_loop(state, fe_id, fe_stack_index - 1, fb_stack_index, last_node_id, bookmark, counter + 1)

          node_af_index == nil ->
            # Not in active formatting - remove from stack and continue
            new_stack = List.delete_at(state.stack, node_stack_index)
            state = %{state | stack: new_stack}
            run_inner_loop(state, fe_id, fe_stack_index - 1, fb_stack_index, last_node_id, bookmark, counter + 1)

          true ->
            # Create new element, replace in active formatting and stack
            {_node_id_old, node_tag, node_attrs} = Enum.at(state.active_formatting, node_af_index)
            {document, new_node_id} = Document.add_element(state.document, node_tag, node_attrs, nil)

            # Update active formatting
            new_af = List.replace_at(state.active_formatting, node_af_index, {new_node_id, node_tag, node_attrs})

            # Update stack
            new_stack = List.replace_at(state.stack, node_stack_index, new_node_id)

            # Update bookmark if last_node is furthest block
            bookmark = if last_node_id == stack_entry_id(Enum.at(state.stack, fb_stack_index)) do
              node_af_index + 1
            else
              bookmark
            end

            # Reparent last_node to new_node
            document = Document.remove_from_parent(document, last_node_id)
            document = Document.append_child(document, new_node_id, last_node_id)

            state = %{state | document: document, stack: new_stack, active_formatting: new_af}
            run_inner_loop(state, fe_id, fe_stack_index, fb_stack_index, new_node_id, bookmark, counter + 1)
        end
      end
    end
  end
end
