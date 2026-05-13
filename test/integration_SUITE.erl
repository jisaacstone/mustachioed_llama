%% Integration test suite.
%%
%% Only mocks guanco_app (Ollama). Everything else — ELP, file I/O, bash
%% execution, the LSP framing layer, and the full tool dispatch chain — runs
%% against real implementations.
%%
%% Requires ELP on PATH (or common Homebrew/Linux paths). Skips if absent.

-module(integration_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
     %% LSP
     lsp_client_ready,
     symbol_lookup_known,
     symbol_lookup_unknown,
     apply_edit_clean,
     apply_edit_with_error,
     %% REPL + tools
     chat_simple,
     chat_with_bash_tool,
     history_accumulates
    ].

%%--------------------------------------------------------------------
%% Suite setup / teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    case find_elp() of
        false ->
            {skip, "elp binary not found"};
        ElpPath ->
            ok = application:set_env(mustachioed_llama, elp_path, ElpPath),
            ok = application:set_env(mustachioed_llama, repl_mode, headless),
            {ok, _} = application:ensure_all_started(mustachioed_llama),
            meck:new(guanco_app, [passthrough, no_link]),
            [{elp_path, ElpPath} | Config]
    end.

end_per_suite(_Config) ->
    meck:unload(guanco_app),
    application:stop(mustachioed_llama),
    ok.

%%--------------------------------------------------------------------
%% Per-test setup / teardown
%%--------------------------------------------------------------------

init_per_testcase(TC, Config) when TC =:= apply_edit_clean;
                                   TC =:= apply_edit_with_error ->
    Path = write_tmp_source(),
    [{tmp_path, Path} | Config];

init_per_testcase(TC, Config) when TC =:= chat_simple;
                                   TC =:= chat_with_bash_tool;
                                   TC =:= history_accumulates ->
    %% Fresh REPL with empty history for each chat test
    ok = supervisor:terminate_child(mustachioed_llama_sup, mustachioed_llama_repl),
    {ok, _} = supervisor:restart_child(mustachioed_llama_sup, mustachioed_llama_repl),
    Config;

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(TC, Config) when TC =:= apply_edit_clean;
                                  TC =:= apply_edit_with_error ->
    file:delete(proplists:get_value(tmp_path, Config)),
    ok;

end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% LSP tests
%%--------------------------------------------------------------------

%% symbol_lookup blocks until the lsp_client has queued it and ELP has
%% finished indexing source files.  lsp_client handles the queueing
%% internally; this test just confirms ELP is available and responsive.
%% workspace/symbol in ELP returns module names.  This call blocks
%% until lsp_client has finished loading the ELP index.
lsp_client_ready(_Config) ->
    ct:timetrap({minutes, 2}),
    Result = lsp_client:symbol_lookup(<<"lsp_client">>),
    true = (Result =/= {error, elp_unavailable}).

symbol_lookup_known(_Config) ->
    {ok, #{uri := URI, line := Line, snippet := Snippet}} =
        lsp_client:symbol_lookup(<<"lsp_client">>),
    true = is_binary(URI),
    true = is_integer(Line),
    true = Line > 0,
    true = byte_size(Snippet) > 0,
    nomatch =/= binary:match(URI, <<"lsp_client.erl">>).

symbol_lookup_unknown(_Config) ->
    {error, not_found} =
        lsp_client:symbol_lookup(<<"zzz_no_such_module_xyz_integration_test">>).

%% Apply a no-op edit (replace "ok" with "ok") — should produce no errors.
apply_edit_clean(Config) ->
    PathBin = list_to_binary(proplists:get_value(tmp_path, Config)),
    {ok, Diags} = lsp_client:apply_edit(PathBin, 1, 11, 1, 13, <<"ok">>),
    Errors = [D || D <- Diags, maps:get(~"severity", D, 4) =:= 1],
    [] = Errors.

%% Replace "ok" with "!!!" to introduce a syntax error — ELP should report it.
apply_edit_with_error(Config) ->
    PathBin = list_to_binary(proplists:get_value(tmp_path, Config)),
    {ok, Diags} = lsp_client:apply_edit(PathBin, 1, 11, 1, 13, <<"!!!">>),
    true = length(Diags) > 0,
    true = lists:any(fun(D) -> maps:get(~"severity", D, 4) =:= 1 end, Diags).

%%--------------------------------------------------------------------
%% REPL + tool tests
%%--------------------------------------------------------------------

chat_simple(_Config) ->
    meck:expect(guanco_app, generate_chat_completion,
        fun(_Model, _Msgs, _Opts) ->
            {ok, #{~"message" => #{~"role"    => ~"assistant",
                                   ~"content" => ~"Hello!"}}}
        end),
    {ok, ~"Hello!"} = mustachioed_llama_repl:chat("hi"),
    [_, _] = mustachioed_llama_repl:get_messages().

%% Ollama returns a bash tool call on the first turn. The REPL executes
%% the real bash command and feeds the result back. Ollama then returns
%% a text reply. Verify the tool output appears in history.
chat_with_bash_tool(_Config) ->
    meck:expect(guanco_app, generate_chat_completion,
        fun(_Model, Messages, _Opts) ->
            case length(Messages) of
                1 ->
                    {ok, #{~"message" => #{
                        ~"role"       => ~"assistant",
                        ~"tool_calls" => [#{~"function" => #{
                            ~"name"      => ~"bash",
                            ~"arguments" => #{~"command" => <<"echo integration_ok">>}
                        }}]
                    }}};
                _ ->
                    {ok, #{~"message" => #{~"role"    => ~"assistant",
                                           ~"content" => ~"Done."}}}
            end
        end),
    {ok, ~"Done."} = mustachioed_llama_repl:chat("run echo"),
    Messages = mustachioed_llama_repl:get_messages(),
    %% user + assistant(tool_calls) + tool_result + assistant(content)
    4 = length(Messages),
    ToolMsg = lists:nth(3, Messages),
    ~"tool" = maps:get(role, ToolMsg),
    nomatch =/= binary:match(maps:get(content, ToolMsg), <<"integration_ok">>).

history_accumulates(_Config) ->
    meck:expect(guanco_app, generate_chat_completion,
        fun(_Model, _Msgs, _Opts) ->
            {ok, #{~"message" => #{~"role" => ~"assistant", ~"content" => ~"ok"}}}
        end),
    0 = length(mustachioed_llama_repl:get_messages()),
    mustachioed_llama_repl:chat("one"),
    mustachioed_llama_repl:chat("two"),
    4 = length(mustachioed_llama_repl:get_messages()).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Walk up the directory tree until we find rebar.config (project root).
find_project_root(Dir) ->
    RebarConfig = filename:join(Dir, "rebar.config"),
    case filelib:is_regular(RebarConfig) of
        true  -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true  -> error(project_root_not_found);
                false -> find_project_root(Parent)
            end
    end.

find_elp() ->
    Candidates = ["elp",
                  "/opt/homebrew/bin/elp",
                  "/usr/local/bin/elp",
                  "/usr/bin/elp"],
    lists:foldl(fun
        (_, Found) when Found =/= false -> Found;
        (Name, false) ->
            case os:find_executable(Name) of
                false ->
                    case filelib:is_regular(Name) of
                        true  -> Name;
                        false -> false
                    end;
                Path -> Path
            end
    end, false, Candidates).

%% Creates a valid Erlang source file in src/ that ELP will analyze.
%% Returns the absolute path.
%%
%% File content (line numbers 0-indexed):
%%   line 0: -module(<name>).
%%   line 1: hello() -> ok.
%%
%% "ok" on line 1 spans columns 11-12 (0-indexed), so the LSP range
%% to replace it is {line:1, char:11} to {line:1, char:13}.
write_tmp_source() ->
    ProjectRoot = find_project_root(code:lib_dir(mustachioed_llama)),
    Name = lists:flatten(
        io_lib:format("tmp_integration_~w", [erlang:unique_integer([positive])])),
    Path = filename:join([ProjectRoot, "src", Name ++ ".erl"]),
    Content = iolist_to_binary([
        "-module(", Name, ").\n",
        "hello() -> ok.\n"
    ]),
    ok = file:write_file(Path, Content),
    Path.
