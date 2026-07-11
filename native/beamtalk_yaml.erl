%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%%% **DDD Context:** Object System Context

-module(beamtalk_yaml).

-moduledoc """
YAML class implementation — YAML parsing and generation via yamerl.

Yaml provides class-side methods for parsing and generating YAML strings.
Uses the `yamerl` library (pure Erlang, no NIFs) with detailed node
construction for reliable type-safe parsing.

## Type Mapping

| YAML          | Beamtalk     |
|---------------|--------------|
| mapping       | Dictionary (keys typed per scalar) |
| sequence      | List         |
| string        | String       |
| integer       | Integer      |
| float         | Float        |
| true/false    | Boolean      |
| null/~        | nil          |

Custom objects can opt into YAML generation by implementing an `asYaml`
instance method returning a YAML-representable value (mirrors `asJson`,
see beamtalk_json.erl / JsonRepresentable in the core stdlib).

## Methods

| Selector        | Description                                        |
|-----------------|----------------------------------------------------|
| `parse:`        | YAML string → Beamtalk value (first document)      |
| `parseAll:`     | YAML string → List of all documents                |
| `generate:`     | Beamtalk value → YAML string (flow style)          |
| `prettyPrint:`  | Beamtalk value → YAML string (block style)         |
| `parseFile:`    | Read file then parse first YAML document           |
""".

-export(['parse:'/1, 'parseAll:'/1, 'generate:'/1, 'prettyPrint:'/1, 'parseFile:'/1]).
-export([parse/1, parseAll/1, generate/1, prettyPrint/1, parseFile/1]).

-include_lib("beamtalk_runtime/include/beamtalk.hrl").
-include_lib("kernel/include/logger.hrl").

%%% ============================================================================
%%% Public API
%%% ============================================================================

-doc """
Parse a YAML string into a Beamtalk value (first document).

YAML mappings become Dictionaries (maps whose key types follow the YAML
scalar type — string keys become Strings, integer keys become Integers),
sequences become Lists, strings become Strings, integers become Integers,
floats become Floats, true/false become booleans, null/~ become nil.

Returns `Result ok: value` on success, `Result error:` on invalid YAML.
Type error (non-String argument) still raises.
""".
-spec 'parse:'(binary()) -> beamtalk_result:t().
'parse:'(YamlStr) when is_binary(YamlStr) ->
    case parse_yaml_string(YamlStr, 'parse:') of
        {error, _} = Err ->
            beamtalk_result:from_tagged_tuple(Err);
        {ok, Docs} ->
            try
                Value =
                    case Docs of
                        [] -> nil;
                        [Doc | _] -> convert_node(Doc, 'parse:')
                    end,
                beamtalk_result:from_tagged_tuple({ok, Value})
            catch
                error:#{error := #beamtalk_error{}} = E ->
                    beamtalk_result:from_tagged_tuple({error, maps:get(error, E)})
            end
    end;
'parse:'(_) ->
    Error0 = beamtalk_error:new(type_error, 'Yaml'),
    Error1 = beamtalk_error:with_selector(Error0, 'parse:'),
    Error2 = beamtalk_error:with_hint(Error1, <<"Argument must be a String">>),
    beamtalk_error:raise(Error2).

-doc """
Parse a YAML string containing multiple documents.

Returns `Result ok: list` where list contains one value per YAML document
(separated by ---). Returns `Result error:` on invalid YAML.
Type error (non-String argument) still raises.
""".
-spec 'parseAll:'(binary()) -> beamtalk_result:t().
'parseAll:'(YamlStr) when is_binary(YamlStr) ->
    case parse_yaml_string(YamlStr, 'parseAll:') of
        {error, _} = Err ->
            beamtalk_result:from_tagged_tuple(Err);
        {ok, Docs} ->
            try
                beamtalk_result:from_tagged_tuple(
                    {ok, [convert_node(Doc, 'parseAll:') || Doc <- Docs]}
                )
            catch
                error:#{error := #beamtalk_error{}} = E ->
                    beamtalk_result:from_tagged_tuple({error, maps:get(error, E)})
            end
    end;
'parseAll:'(_) ->
    Error0 = beamtalk_error:new(type_error, 'Yaml'),
    Error1 = beamtalk_error:with_selector(Error0, 'parseAll:'),
    Error2 = beamtalk_error:with_hint(Error1, <<"Argument must be a String">>),
    beamtalk_error:raise(Error2).

-doc """
Generate a YAML string from a Beamtalk value (flow style).

Produces valid YAML 1.2 in flow style. Dictionaries become YAML mappings,
Lists become sequences, Strings become YAML strings, Integer/Float become
numbers, true/false become YAML booleans, nil becomes null. Custom objects
that implement `asYaml` are converted via that hook (see the module doc).
""".
-spec 'generate:'(term()) -> binary().
'generate:'(Value) ->
    try
        Prepared = prepare_for_encode(Value),
        generate_flow(Prepared)
    catch
        error:#{error := #beamtalk_error{}} = E:_ ->
            error(E);
        _:Reason ->
            Error0 = beamtalk_error:new(type_error, 'Yaml'),
            Error1 = beamtalk_error:with_selector(Error0, 'generate:'),
            Error2 = beamtalk_error:with_details(Error1, #{reason => Reason}),
            Error3 = beamtalk_error:with_hint(Error2, <<"Value cannot be converted to YAML">>),
            beamtalk_error:raise(Error3)
    end.

-doc """
Generate a pretty-printed YAML string in block style (indented, no `{}`/`[]`).

Shares the same `asYaml` hook and type coercion as `generate:` — only the
container layout differs.
""".
-spec 'prettyPrint:'(term()) -> binary().
'prettyPrint:'(Value) ->
    try
        Prepared = prepare_for_encode(Value),
        generate_block(Prepared)
    catch
        error:#{error := #beamtalk_error{}} = E:_ ->
            error(E);
        _:Reason ->
            Error0 = beamtalk_error:new(type_error, 'Yaml'),
            Error1 = beamtalk_error:with_selector(Error0, 'prettyPrint:'),
            Error2 = beamtalk_error:with_details(Error1, #{reason => Reason}),
            Error3 = beamtalk_error:with_hint(Error2, <<"Value cannot be converted to YAML">>),
            beamtalk_error:raise(Error3)
    end.

-doc """
Read a file and parse it as YAML (first document).

Returns `Result ok: value` on success, `Result error:` if the file cannot
be read or the YAML is invalid. Type error (non-String argument) still raises.
""".
-spec 'parseFile:'(binary()) -> beamtalk_result:t().
'parseFile:'(Path) when is_binary(Path) ->
    case file:read_file(Path) of
        {ok, Content} ->
            'parse:'(Content);
        {error, Reason} ->
            Error0 = beamtalk_error:new(parse_error, 'Yaml'),
            Error1 = beamtalk_error:with_selector(Error0, 'parseFile:'),
            Error2 = beamtalk_error:with_details(Error1, #{path => Path, reason => Reason}),
            Error3 = beamtalk_error:with_hint(
                Error2, <<"Check that the file exists and is readable">>
            ),
            beamtalk_result:from_tagged_tuple({error, Error3})
    end;
'parseFile:'(_) ->
    Error0 = beamtalk_error:new(type_error, 'Yaml'),
    Error1 = beamtalk_error:with_selector(Error0, 'parseFile:'),
    Error2 = beamtalk_error:with_hint(Error1, <<"Argument must be a String">>),
    beamtalk_error:raise(Error2).

%%% ============================================================================
%%% FFI aliases — no-colon names for Erlang FFI dispatch
%%% ============================================================================

-doc "FFI alias for parse:/1 — called via (Erlang beamtalk_yaml) parse: str.".
-spec parse(binary()) -> beamtalk_result:t().
parse(X) -> 'parse:'(X).

-doc "FFI alias for parseAll:/1 — called via (Erlang beamtalk_yaml) parseAll: str.".
-spec parseAll(binary()) -> beamtalk_result:t().
parseAll(X) -> 'parseAll:'(X).

-doc "FFI alias for generate:/1 — called via (Erlang beamtalk_yaml) generate: val.".
-spec generate(term()) -> binary().
generate(X) -> 'generate:'(X).

-doc "FFI alias for prettyPrint:/1 — called via (Erlang beamtalk_yaml) prettyPrint: val.".
-spec prettyPrint(term()) -> binary().
prettyPrint(X) -> 'prettyPrint:'(X).

-doc "FFI alias for parseFile:/1 — called via (Erlang beamtalk_yaml) parseFile: str.".
-spec parseFile(binary()) -> beamtalk_result:t().
parseFile(X) -> 'parseFile:'(X).

%%% ============================================================================
%%% Internal Functions — Parsing
%%% ============================================================================
-doc """
Parse a YAML binary using yamerl detailed mode.

Returns `{ok, Docs}` or `{error, #beamtalk_error{}}`.

Uses `{detailed_constr, true}` to get typed yamerl node records, which
allows reliable type-safe conversion without the string/sequence ambiguity
present in simplified mode.

Ensures yamerl is started before use. The test runner does not start OTP
applications via application:ensure_all_started, so yamerl must be started
lazily here.
""".
-spec parse_yaml_string(binary(), atom()) -> {ok, [term()]} | {error, #beamtalk_error{}}.
parse_yaml_string(YamlStr, Selector) ->
    case ensure_yamerl_started(Selector) of
        {error, _} = Err ->
            Err;
        ok ->
            try
                Docs = yamerl_constr:string(YamlStr, [{detailed_constr, true}]),
                {ok, [unwrap_doc(D) || D <- Docs]}
            catch
                error:#{error := #beamtalk_error{}} = E:_ ->
                    error(E);
                throw:{yamerl_exception, _} = Ex ->
                    Error0 = beamtalk_error:new(parse_error, 'Yaml'),
                    Error1 = beamtalk_error:with_selector(Error0, Selector),
                    Error2 = beamtalk_error:with_details(Error1, #{reason => Ex}),
                    Error3 = beamtalk_error:with_hint(
                        Error2, <<"Check that the string is valid YAML">>
                    ),
                    {error, Error3};
                _:Reason ->
                    Error0 = beamtalk_error:new(parse_error, 'Yaml'),
                    Error1 = beamtalk_error:with_selector(Error0, Selector),
                    Error2 = beamtalk_error:with_details(Error1, #{reason => Reason}),
                    Error3 = beamtalk_error:with_hint(
                        Error2, <<"Check that the string is valid YAML">>
                    ),
                    {error, Error3}
            end
    end.

%% Ensure yamerl is started as an OTP application.
%%
%% yamerl requires its application to be started before use. The beamtalk
%% test runner does not use application:ensure_all_started, so yamerl must
%% be started lazily. This call is idempotent.
%%
%% Returns `ok` on success or `{error, #beamtalk_error{}}` on failure.
-doc false.
-spec ensure_yamerl_started(atom()) -> ok | {error, #beamtalk_error{}}.
ensure_yamerl_started(Selector) ->
    case application:ensure_all_started(yamerl) of
        {ok, _Started} ->
            ok;
        {error, Reason} ->
            Error0 = beamtalk_error:new(parse_error, 'Yaml'),
            Error1 = beamtalk_error:with_selector(Error0, Selector),
            Error2 = beamtalk_error:with_hint(
                Error1, <<"Failed to start yamerl YAML library">>
            ),
            Error3 = beamtalk_error:with_details(Error2, #{reason => Reason}),
            {error, Error3}
    end.

-doc """
Unwrap a {yamerl_doc, Node} document wrapper.
""".
-spec unwrap_doc(term()) -> term().
unwrap_doc({yamerl_doc, Node}) -> Node;
unwrap_doc(Node) -> Node.
-doc """
Convert a yamerl detailed node to a Beamtalk value.

yamerl detailed nodes are tagged tuples with type information.
This converter handles all standard YAML types. Unsupported node types
(anchors, aliases, custom tags) raise a parse_error.
The Selector parameter is used for error attribution (parse: vs parseAll:).
""".
-spec convert_node(term(), atom()) -> term().
convert_node({yamerl_str, _, _, _, Charlist}, _Selector) ->
    %% Strings are returned as charlists in yamerl detailed mode.
    %% Use unicode:characters_to_binary/1 (not list_to_binary/1) to safely
    %% handle codepoints > 255, which list_to_binary/1 would crash on.
    unicode:characters_to_binary(Charlist);
convert_node({yamerl_int, _, _, _, Value}, _Selector) ->
    Value;
convert_node({yamerl_float, _, _, _, Value}, _Selector) ->
    Value;
convert_node({yamerl_bool, _, _, _, true}, _Selector) ->
    true;
convert_node({yamerl_bool, _, _, _, false}, _Selector) ->
    false;
convert_node({yamerl_null, _, _, _}, _Selector) ->
    nil;
convert_node({yamerl_seq, _, _, _, Items, _Count}, Selector) ->
    [convert_node(Item, Selector) || Item <- Items];
convert_node({yamerl_map, _, _, _, Pairs}, Selector) ->
    maps:from_list([
        {convert_node(K, Selector), convert_node(V, Selector)}
     || {K, V} <- Pairs
    ]);
convert_node(Other, Selector) ->
    %% Fallback for unsupported node types: anchors, aliases, custom tags.
    %% Log only the node type tag to avoid exposing potentially sensitive values
    %% from YAML files (e.g. API keys, passwords) in log output.
    NodeType = element(1, Other),
    ?LOG_WARNING("beamtalk_yaml: unsupported yamerl node type", #{node_type => NodeType}),
    Error0 = beamtalk_error:new(parse_error, 'Yaml'),
    Error1 = beamtalk_error:with_selector(Error0, Selector),
    Error2 = beamtalk_error:with_details(Error1, #{node_type => NodeType}),
    Error3 = beamtalk_error:with_hint(
        Error2,
        <<"YAML anchors/aliases and custom tags are not supported">>
    ),
    beamtalk_error:raise(Error3).

%%% ============================================================================
%%% Internal Functions — Generation
%%% ============================================================================

-doc """
Prepare a Beamtalk value for YAML encoding.

Beamtalk uses `nil` for null; YAML generator expects `null`.
Maps with `$beamtalk_class` tags are stripped of metadata.

Custom objects (Value instances, actors, ...) that implement `asYaml`
are converted via that hook (mirrors `asJson`, BT-2818): the hook's return
value is prepared recursively, so it may itself contain further `asYaml`
objects. Tagged maps whose class does not implement `asYaml` keep the
legacy behaviour of encoding their user fields directly as a YAML mapping.
""".
-spec prepare_for_encode(term()) -> term().
prepare_for_encode(Value) ->
    prepare_for_encode(Value, []).

-doc """
Same as `prepare_for_encode/1`, threading `Seen` — the receivers whose
`asYaml` hook is currently being resolved higher up this call chain.

Only actors can produce a cycle (Value instances are immutable, so a
Beamtalk value can never contain itself): actor A's `asYaml` embedding
actor B, whose `asYaml` embeds A back, would otherwise recurse until the
process runs out of stack. `Seen` is extended only at the point a hook is
about to be invoked (`try_as_yaml_hook/2`), so plain Dictionary/List
recursion is unaffected.
""".
-spec prepare_for_encode(term(), [term()]) -> term().
prepare_for_encode(nil, _Seen) ->
    null;
prepare_for_encode(Map, Seen) when is_map(Map) ->
    case beamtalk_tagged_map:class_of(Map) of
        undefined ->
            encode_map_fields(Map, Seen);
        'Dictionary' ->
            encode_map_fields(Map, Seen);
        _Class ->
            case try_as_yaml_hook(Map, Seen) of
                {ok, Prepared} -> Prepared;
                no_hook -> encode_map_fields(Map, Seen)
            end
    end;
prepare_for_encode(List, Seen) when is_list(List) ->
    [prepare_for_encode(E, Seen) || E <- List];
prepare_for_encode(true, _Seen) ->
    true;
prepare_for_encode(false, _Seen) ->
    false;
prepare_for_encode(V, _Seen) when is_integer(V) -> V;
prepare_for_encode(V, _Seen) when is_float(V) -> V;
prepare_for_encode(V, _Seen) when is_binary(V) -> V;
prepare_for_encode(V, _Seen) when is_atom(V) ->
    %% Convert atoms (symbols) to strings for YAML compatibility
    atom_to_binary(V, utf8);
prepare_for_encode(Other, Seen) ->
    case try_as_yaml_hook(Other, Seen) of
        {ok, Prepared} ->
            Prepared;
        no_hook ->
            %% No selector — callers add the correct one via their catch blocks
            Error0 = beamtalk_error:new(type_error, 'Yaml'),
            Error1 = beamtalk_error:with_details(Error0, #{value => Other}),
            Error2 = beamtalk_error:with_hint(
                Error1,
                <<
                    "Only Dictionary, List, String, Integer, Float, Boolean, and nil "
                    "convert to YAML natively; implement asYaml to give this class "
                    "a YAML representation"
                >>
            ),
            beamtalk_error:raise(Error2)
    end.

-doc """
Encode a map's entries as a YAML mapping, stripping the `$beamtalk_class` tag.
""".
-spec encode_map_fields(map(), [term()]) -> map().
encode_map_fields(Map, Seen) ->
    Cleaned = maps:remove('$beamtalk_class', Map),
    maps:map(fun(_K, V) -> prepare_for_encode(V, Seen) end, Cleaned).

-doc """
Dispatch the `asYaml` conversion hook on a custom object (mirrors `asJson`).

Returns `{ok, Prepared}` when the object understands `asYaml`, `no_hook`
otherwise. Uses `beamtalk_message_dispatch` (the unified send entry point)
so the check and the call behave exactly like Beamtalk-level
`value respondsTo: #asYaml` / `value asYaml` for every receiver shape —
value-type tagged maps and live actors alike.

A receiver already in `Seen` — either because its hook returned itself
directly, or because it reappears deeper inside its own YAML output via
one or more intermediate objects — raises a type error instead of
recursing forever.
""".
-spec try_as_yaml_hook(term(), [term()]) -> {ok, term()} | no_hook.
try_as_yaml_hook(Value, Seen) ->
    case lists:member(Value, Seen) of
        true ->
            Error0 = beamtalk_error:new(type_error, 'Yaml'),
            Error1 = beamtalk_error:with_details(Error0, #{value => Value}),
            Error2 = beamtalk_error:with_hint(
                Error1,
                <<
                    "asYaml produced a cycle: this object reappeared inside "
                    "its own YAML output"
                >>
            ),
            beamtalk_error:raise(Error2);
        false ->
            case beamtalk_message_dispatch:send(Value, 'respondsTo:', ['asYaml']) of
                true ->
                    Yaml = beamtalk_message_dispatch:send(Value, 'asYaml', []),
                    {ok, prepare_for_encode(Yaml, [Value | Seen])};
                _ ->
                    no_hook
            end
    end.

-doc """
Generate YAML in flow style from a prepared Erlang term.

Flow-style YAML is valid YAML 1.2 and is parseable by yamerl.
All string values and map keys are double-quoted for unambiguous round-trip.
""".
-spec generate_flow(term()) -> binary().
generate_flow(null) ->
    <<"null">>;
generate_flow(true) ->
    <<"true">>;
generate_flow(false) ->
    <<"false">>;
generate_flow(N) when is_integer(N) -> integer_to_binary(N);
generate_flow(F) when is_float(F) -> float_to_binary(F, [short]);
generate_flow(B) when is_binary(B) -> yaml_double_quote(B);
generate_flow(Map) when is_map(Map), map_size(Map) =:= 0 -> <<"{}">>;
generate_flow(Map) when is_map(Map) ->
    Pairs = [
        <<(render_key(K))/binary, ": ", (generate_flow(V))/binary>>
     || {K, V} <- maps:to_list(Map)
    ],
    <<"{", (iolist_to_binary(lists:join(<<", ">>, Pairs)))/binary, "}">>;
generate_flow([]) ->
    <<"[]">>;
generate_flow(List) when is_list(List) ->
    Items = [generate_flow(Item) || Item <- List],
    <<"[", (iolist_to_binary(lists:join(<<", ">>, Items)))/binary, "]">>.

-doc """
Generate YAML in block style from a prepared Erlang term (used by `prettyPrint:`).

Block style is idiomatic, indented YAML: mappings are `key: value` lines
and sequences are `- item` lines, nested by two-space indentation, with no
`{}`/`[]` delimiters. Empty containers and scalars still render inline via
`generate_flow/1` — block style has no natural representation for them.

A non-empty container nested as a list item has its first line folded onto
the `- ` marker (e.g. `- name: Ada` rather than a separate line per YAML
convention), matching how most YAML tools render lists of mappings.
""".
-spec generate_block(term()) -> binary().
generate_block(Value) ->
    case block_shape(Value) of
        {scalar, Bin} -> Bin;
        container -> iolist_to_binary(lists:join(<<"\n">>, block_lines(Value, 0)))
    end.

%% Distinguish scalars (and empty containers, rendered inline via
%% generate_flow/1) from non-empty containers (rendered as a multi-line block).
-spec block_shape(term()) -> {scalar, binary()} | container.
block_shape(Map) when is_map(Map), map_size(Map) =:= 0 -> {scalar, <<"{}">>};
block_shape(List) when is_list(List), List =:= [] -> {scalar, <<"[]">>};
block_shape(Map) when is_map(Map) -> container;
block_shape(List) when is_list(List) -> container;
block_shape(Other) -> {scalar, generate_flow(Other)}.

-spec block_lines(term(), non_neg_integer()) -> [binary()].
block_lines(Map, Depth) when is_map(Map) ->
    lists:flatmap(fun({K, V}) -> map_entry_lines(K, V, Depth) end, maps:to_list(Map));
block_lines(List, Depth) when is_list(List) ->
    lists:flatmap(fun(Item) -> list_item_lines(Item, Depth) end, List).

-spec map_entry_lines(term(), term(), non_neg_integer()) -> [binary()].
map_entry_lines(K, V, Depth) ->
    KeyBin = render_key(K),
    case block_shape(V) of
        {scalar, Bin} ->
            [<<(block_indent(Depth))/binary, KeyBin/binary, ": ", Bin/binary>>];
        container ->
            [<<(block_indent(Depth))/binary, KeyBin/binary, ":">> | block_lines(V, Depth + 1)]
    end.

-spec list_item_lines(term(), non_neg_integer()) -> [binary()].
list_item_lines(Item, Depth) ->
    case block_shape(Item) of
        {scalar, Bin} ->
            [<<(block_indent(Depth))/binary, "- ", Bin/binary>>];
        container ->
            [SubFirst | SubRest] = block_lines(Item, Depth + 1),
            ChildIndentSize = byte_size(block_indent(Depth + 1)),
            <<_:ChildIndentSize/binary, Trimmed/binary>> = SubFirst,
            First = <<(block_indent(Depth))/binary, "- ", Trimmed/binary>>,
            [First | SubRest]
    end.

-spec block_indent(non_neg_integer()) -> binary().
block_indent(0) -> <<>>;
block_indent(N) -> binary:copy(<<"  ">>, N).

-doc """
Render a map key for YAML flow output.

Typed scalar keys (integer, float, boolean, nil) are emitted unquoted so
a parse → generate round-trip preserves key types. String and atom keys
are double-quoted to prevent ambiguity with YAML reserved words.
""".
-spec render_key(term()) -> binary().
render_key(nil) -> <<"null">>;
render_key(true) -> <<"true">>;
render_key(false) -> <<"false">>;
render_key(K) when is_integer(K) -> integer_to_binary(K);
render_key(K) when is_float(K) -> float_to_binary(K, [short]);
render_key(K) when is_atom(K) -> yaml_double_quote(atom_to_binary(K, utf8));
render_key(K) when is_binary(K) -> yaml_double_quote(K).

-doc """
Wrap a binary in double quotes, escaping internal special characters.
""".
-spec yaml_double_quote(binary()) -> binary().
yaml_double_quote(B) when is_binary(B) ->
    Escaped = escape_yaml_string(B),
    <<$", Escaped/binary, $">>.

-doc """
Escape special characters in a binary for YAML output.
""".
-spec escape_yaml_string(binary()) -> binary().
escape_yaml_string(B) ->
    B1 = binary:replace(B, <<"\\">>, <<"\\\\">>, [global]),
    B2 = binary:replace(B1, <<"\"">>, <<"\\\"">>, [global]),
    B3 = binary:replace(B2, <<"\n">>, <<"\\n">>, [global]),
    B4 = binary:replace(B3, <<"\r">>, <<"\\r">>, [global]),
    binary:replace(B4, <<"\t">>, <<"\\t">>, [global]).
