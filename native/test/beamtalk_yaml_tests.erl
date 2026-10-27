%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%%% @doc EUnit tests for beamtalk_yaml module (BT-1122).
%%%
%%% **DDD Context:** Object System Context
%%%
%%% Tests parse:, parseAll:, generate:, parseFile:,
%%% type conversion, error paths, and round-trip correctness.

-module(beamtalk_yaml_tests).
-moduledoc "EUnit tests for beamtalk_yaml module (BT-1122).".

-include_lib("eunit/include/eunit.hrl").
-include_lib("beamtalk_runtime/include/beamtalk.hrl").

%%% ============================================================================
%%% parse: — scalar types
%%% ============================================================================

parse_integer_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(42, unwrap_ok(beamtalk_yaml:'parse:'(<<"42">>))).

parse_negative_integer_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(-7, unwrap_ok(beamtalk_yaml:'parse:'(<<"-7">>))).

parse_float_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(3.14, unwrap_ok(beamtalk_yaml:'parse:'(<<"3.14">>))).

parse_string_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual({beamtalk_string, <<"hello">>}, unwrap_ok(beamtalk_yaml:'parse:'(<<"hello">>))).

parse_unicode_string_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(
        {beamtalk_string, <<"héllo"/utf8>>}, unwrap_ok(beamtalk_yaml:'parse:'(<<"héllo"/utf8>>))
    ).

parse_true_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(true, unwrap_ok(beamtalk_yaml:'parse:'(<<"true">>))).

parse_false_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(false, unwrap_ok(beamtalk_yaml:'parse:'(<<"false">>))).

parse_null_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(nil, unwrap_ok(beamtalk_yaml:'parse:'(<<"null">>))).

parse_tilde_null_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(nil, unwrap_ok(beamtalk_yaml:'parse:'(<<"~">>))).

parse_empty_document_test() ->
    application:ensure_all_started(yamerl),
    %% Empty YAML string produces nil (no documents)
    ?assertEqual(nil, unwrap_ok(beamtalk_yaml:'parse:'(<<"">>))).

%%% ============================================================================
%%% parse: — sequences
%%% ============================================================================

parse_empty_sequence_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([], unwrap_ok(beamtalk_yaml:'parse:'(<<"[]">>))).

parse_integer_sequence_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([1, 2, 3], unwrap_ok(beamtalk_yaml:'parse:'(<<"[1, 2, 3]">>))).

parse_mixed_sequence_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(
        [1, {beamtalk_string, <<"hello">>}, true, nil],
        unwrap_ok(beamtalk_yaml:'parse:'(<<"[1, hello, true, null]">>))
    ).

parse_nested_sequence_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([[1, 2], [3, 4]], unwrap_ok(beamtalk_yaml:'parse:'(<<"[[1, 2], [3, 4]]">>))).

%%% ============================================================================
%%% parse: — mappings
%%% ============================================================================

parse_string_key_mapping_test() ->
    application:ensure_all_started(yamerl),
    Result = unwrap_ok(beamtalk_yaml:'parse:'(<<"{name: Ada, age: 36}">>)),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, Result)),
    ?assertEqual(36, maps:get({beamtalk_string, <<"age">>}, Result)).

parse_integer_key_mapping_test() ->
    application:ensure_all_started(yamerl),
    %% Integer keys remain as integers (not coerced to strings)
    Result = unwrap_ok(beamtalk_yaml:'parse:'(<<"{1: one, 2: two}">>)),
    ?assertEqual({beamtalk_string, <<"one">>}, maps:get(1, Result)),
    ?assertEqual({beamtalk_string, <<"two">>}, maps:get(2, Result)).

parse_empty_mapping_test() ->
    application:ensure_all_started(yamerl),
    Result = unwrap_ok(beamtalk_yaml:'parse:'(<<"{}">>)),
    ?assert(is_map(Result)),
    ?assertEqual(0, map_size(Result)).

parse_nested_mapping_test() ->
    application:ensure_all_started(yamerl),
    Result = unwrap_ok(beamtalk_yaml:'parse:'(<<"{user: {name: Ada, age: 36}}">>)),
    User = maps:get({beamtalk_string, <<"user">>}, Result),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, User)),
    ?assertEqual(36, maps:get({beamtalk_string, <<"age">>}, User)).

%%% ============================================================================
%%% parse: — type errors
%%% ============================================================================

parse_type_error_integer_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:'parse:'(42)
    ).

parse_type_error_atom_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:'parse:'(hello)
    ).

%%% ============================================================================
%%% parse: — parse errors
%%% ============================================================================

parse_invalid_yaml_test() ->
    application:ensure_all_started(yamerl),
    R = beamtalk_yaml:'parse:'(<<"key: [unclosed">>),
    ?assertMatch(
        #{
            '$beamtalk_class' := 'Result',
            'isOk' := false,
            'errReason' := #{'$beamtalk_class' := _, error := #beamtalk_error{kind = parse_error}}
        },
        R
    ).

%%% ============================================================================
%%% parse: — unsupported YAML features (BT-1126)
%%% ============================================================================

parse_binary_tag_returns_result_error_test() ->
    %% !!binary produces a yamerl_binary node — unsupported, must return Result error
    %% with parse_error attributed to the parse: selector.
    %% "SGVsbG8=" is base64 for "Hello".
    application:ensure_all_started(yamerl),
    R = beamtalk_yaml:'parse:'(<<"!!binary \"SGVsbG8=\"">>),
    ?assertMatch(
        #{
            '$beamtalk_class' := 'Result',
            'isOk' := false,
            'errReason' := #{
                '$beamtalk_class' := _,
                error := #beamtalk_error{kind = parse_error, selector = 'parse:'}
            }
        },
        R
    ).

parse_all_binary_tag_returns_result_error_test() ->
    %% Same unsupported node via parseAll: — error selector must be parseAll:.
    application:ensure_all_started(yamerl),
    R = beamtalk_yaml:'parseAll:'(<<"!!binary \"SGVsbG8=\"">>),
    ?assertMatch(
        #{
            '$beamtalk_class' := 'Result',
            'isOk' := false,
            'errReason' := #{
                '$beamtalk_class' := _,
                error := #beamtalk_error{kind = parse_error, selector = 'parseAll:'}
            }
        },
        R
    ).

%%% ============================================================================
%%% parseAll:
%%% ============================================================================

parse_all_single_document_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([42], unwrap_ok(beamtalk_yaml:'parseAll:'(<<"42">>))).

parse_all_multi_document_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([42, 43], unwrap_ok(beamtalk_yaml:'parseAll:'(<<"42\n---\n43">>))).

parse_all_sequence_document_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([[1, 2, 3]], unwrap_ok(beamtalk_yaml:'parseAll:'(<<"[1, 2, 3]">>))).

parse_all_type_error_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:'parseAll:'(not_a_binary)
    ).

%%% ============================================================================
%%% generate:
%%% ============================================================================

generate_integer_test() ->
    ?assertEqual({beamtalk_string, <<"42">>}, beamtalk_yaml:'generate:'(42)).

generate_negative_integer_test() ->
    ?assertEqual({beamtalk_string, <<"-7">>}, beamtalk_yaml:'generate:'(-7)).

generate_float_test() ->
    ?assertEqual({beamtalk_string, <<"3.14">>}, beamtalk_yaml:'generate:'(3.14)).

generate_string_test() ->
    ?assertEqual({beamtalk_string, <<"\"hello\"">>}, beamtalk_yaml:'generate:'(<<"hello">>)).

generate_string_with_special_chars_test() ->
    %% Double-quotes and backslashes must be escaped
    ?assertEqual({beamtalk_string, <<"\"a\\\"b\"">>}, beamtalk_yaml:'generate:'(<<"a\"b">>)).

generate_true_test() ->
    ?assertEqual({beamtalk_string, <<"true">>}, beamtalk_yaml:'generate:'(true)).

generate_false_test() ->
    ?assertEqual({beamtalk_string, <<"false">>}, beamtalk_yaml:'generate:'(false)).

generate_nil_test() ->
    ?assertEqual({beamtalk_string, <<"null">>}, beamtalk_yaml:'generate:'(nil)).

generate_empty_list_test() ->
    ?assertEqual({beamtalk_string, <<"[]">>}, beamtalk_yaml:'generate:'([])).

generate_integer_list_test() ->
    ?assertEqual({beamtalk_string, <<"[1, 2, 3]">>}, beamtalk_yaml:'generate:'([1, 2, 3])).

generate_empty_map_test() ->
    ?assertEqual({beamtalk_string, <<"{}">>}, beamtalk_yaml:'generate:'(#{})).

generate_map_test() ->
    %% Single key to avoid ordering non-determinism
    ?assertEqual(
        {beamtalk_string, <<"{\"name\": \"Ada\"}">>},
        beamtalk_yaml:'generate:'(#{<<"name">> => <<"Ada">>})
    ).

generate_atom_as_string_test() ->
    %% Atoms are converted to strings for YAML compatibility
    ?assertEqual({beamtalk_string, <<"\"ok\"">>}, beamtalk_yaml:'generate:'(ok)).

generate_type_error_test() ->
    %% Tuples cannot be serialised to YAML
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:'generate:'({a, tuple})
    ).

%%% ============================================================================
%%% Round-trip: generate: then parse:
%%% ============================================================================

roundtrip_integer_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(42, unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(42)))).

roundtrip_float_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(3.14, unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(3.14)))).

roundtrip_string_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(
        {beamtalk_string, <<"hello">>},
        unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(<<"hello">>)))
    ).

roundtrip_true_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(true, unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(true)))).

roundtrip_nil_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(nil, unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(nil)))).

roundtrip_list_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(
        [1, 2, 3], unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'([1, 2, 3])))
    ).

roundtrip_map_test() ->
    application:ensure_all_started(yamerl),
    Original = #{<<"name">> => <<"Ada">>, <<"age">> => 36},
    Result = unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(Original))),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, Result)),
    ?assertEqual(36, maps:get({beamtalk_string, <<"age">>}, Result)).

roundtrip_nested_test() ->
    application:ensure_all_started(yamerl),
    Original = #{<<"user">> => #{<<"age">> => 36}},
    Result = unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(Original))),
    ?assertEqual(
        36, maps:get({beamtalk_string, <<"age">>}, maps:get({beamtalk_string, <<"user">>}, Result))
    ).

roundtrip_unicode_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(
        {beamtalk_string, <<"héllo"/utf8>>},
        unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(<<"héllo"/utf8>>)))
    ).

roundtrip_integer_key_map_test() ->
    %% Integer keys must survive generate: → parse: as integers, not strings
    application:ensure_all_started(yamerl),
    Original = #{1 => <<"one">>, 2 => <<"two">>},
    Result = unwrap_ok(beamtalk_yaml:'parse:'(beamtalk_yaml:'generate:'(Original))),
    ?assertEqual({beamtalk_string, <<"one">>}, maps:get(1, Result)),
    ?assertEqual({beamtalk_string, <<"two">>}, maps:get(2, Result)).

generate_integer_key_unquoted_test() ->
    %% Integer keys must be emitted without quotes so they parse as integers
    {beamtalk_string, Generated} = beamtalk_yaml:'generate:'(#{1 => <<"x">>}),
    ?assertNotMatch(<<"{\"-", _/binary>>, Generated),
    ?assertNotMatch(<<"{\"", _/binary>>, Generated).

%%% ============================================================================
%%% parseFile:
%%% ============================================================================

parse_file_test() ->
    application:ensure_all_started(yamerl),
    Path = write_temp_yaml(<<"42">>),
    ?assertEqual(42, unwrap_ok(beamtalk_yaml:'parseFile:'(Path))),
    file:delete(Path).

parse_file_mapping_test() ->
    application:ensure_all_started(yamerl),
    Path = write_temp_yaml(<<"{name: Ada, age: 36}">>),
    Result = unwrap_ok(beamtalk_yaml:'parseFile:'(Path)),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, Result)),
    file:delete(Path).

parse_file_not_found_test() ->
    application:ensure_all_started(yamerl),
    R = beamtalk_yaml:'parseFile:'(<<"/nonexistent/path/that/does/not/exist.yaml">>),
    ?assertMatch(
        #{
            '$beamtalk_class' := 'Result',
            'isOk' := false,
            'errReason' := #{'$beamtalk_class' := _, error := #beamtalk_error{kind = parse_error}}
        },
        R
    ).

parse_file_type_error_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:'parseFile:'(not_a_binary)
    ).

%%% ============================================================================
%%% FFI no-colon aliases (BT-1142)
%%% ============================================================================

parse_alias_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual(42, unwrap_ok(beamtalk_yaml:parse(<<"42">>))).

parse_alias_type_error_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:parse(not_a_binary)
    ).

parse_all_alias_test() ->
    application:ensure_all_started(yamerl),
    ?assertEqual([42, 43], unwrap_ok(beamtalk_yaml:parseAll(<<"42\n---\n43">>))).

generate_alias_test() ->
    ?assertEqual({beamtalk_string, <<"42">>}, beamtalk_yaml:generate(42)).

parse_file_alias_type_error_test() ->
    ?assertError(
        #{'$beamtalk_class' := _, error := #beamtalk_error{kind = type_error}},
        beamtalk_yaml:parseFile(not_a_binary)
    ).

%%% ============================================================================
%%% BT-4171 — string leaves answer String (validated at the boundary)
%%% ============================================================================

string_leaf_answers_string_test() ->
    application:ensure_all_started(yamerl),
    Leaf = unwrap_ok(beamtalk_yaml:'parse:'(<<"hello">>)),
    ?assertEqual({beamtalk_string, <<"hello">>}, Leaf),
    ?assertEqual('String', beamtalk_primitive:class_of(Leaf)).

unicode_leaf_answers_string_test() ->
    application:ensure_all_started(yamerl),
    Leaf = unwrap_ok(beamtalk_yaml:'parse:'(<<"héllo"/utf8>>)),
    ?assertEqual({beamtalk_string, <<"héllo"/utf8>>}, Leaf),
    ?assertEqual('String', beamtalk_primitive:class_of(Leaf)).

sequence_items_answer_string_test() ->
    application:ensure_all_started(yamerl),
    Items = unwrap_ok(beamtalk_yaml:'parse:'(<<"[a, b]">>)),
    ?assertEqual([{beamtalk_string, <<"a">>}, {beamtalk_string, <<"b">>}], Items),
    lists:foreach(
        fun(I) -> ?assertEqual('String', beamtalk_primitive:class_of(I)) end,
        Items
    ).

mapping_keys_and_values_answer_string_test() ->
    application:ensure_all_started(yamerl),
    Map = unwrap_ok(beamtalk_yaml:'parse:'(<<"{\"name\": \"Ada\"}">>)),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, Map)),
    ?assertEqual(
        'String', beamtalk_primitive:class_of(maps:get({beamtalk_string, <<"name">>}, Map))
    ),
    lists:foreach(
        fun(K) -> ?assertEqual('String', beamtalk_primitive:class_of(K)) end,
        maps:keys(Map)
    ).

integer_keys_keep_class_test() ->
    application:ensure_all_started(yamerl),
    %% Yaml keys follow the scalar type: only string scalars become Strings.
    Map = unwrap_ok(beamtalk_yaml:'parse:'(<<"{1: \"one\"}">>)),
    ?assertEqual('Integer', beamtalk_primitive:class_of(hd(maps:keys(Map)))),
    ?assertEqual('String', beamtalk_primitive:class_of(maps:get(1, Map))).

parse_all_leaves_answer_string_test() ->
    application:ensure_all_started(yamerl),
    Docs = unwrap_ok(beamtalk_yaml:'parseAll:'(<<"a\n---\nb">>)),
    ?assertEqual([{beamtalk_string, <<"a">>}, {beamtalk_string, <<"b">>}], Docs),
    lists:foreach(
        fun(D) -> ?assertEqual('String', beamtalk_primitive:class_of(D)) end,
        Docs
    ).

%%% ============================================================================
%%% Helpers
%%% ============================================================================

%% @private Unwrap a Result ok value, failing the test if it is an error.
unwrap_ok(#{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := V}) ->
    V;
unwrap_ok(Other) ->
    error({expected_result_ok, Other}).

%% @private Write content to a temporary file and return its binary path.
write_temp_yaml(Content) ->
    Path = filename:join(
        [filename:basedir(user_cache, "beamtalk_yaml_tests"), "test.yaml"]
    ),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    list_to_binary(Path).
