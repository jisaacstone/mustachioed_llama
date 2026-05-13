%% LSP client gen_server.
%%
%% Manages a persistent connection to the ELP language server over stdio.
%% Handles the initialize/initialized handshake, then dispatches requests
%% and correlates async responses back to callers.

-module(lsp_client).

-behaviour(gen_server).

-export([start_link/0]).
-export([symbol_lookup/1, apply_edit/6, uri_to_path/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DIAG_TIMEOUT, 10000).

-record(state, {
    port         :: port() | nil,
    buffer       = <<>>        :: binary(),
    next_id      = 1           :: integer(),
    %% initializing: waiting for initialize response
    %% loading: handshake done, ELP indexing source files
    %% ready: fully indexed, all requests accepted
    %% unavailable: ELP not found
    status       = initializing :: initializing | loading | ready | unavailable,
    pending      = #{}         :: #{integer() => {gen_server:from(), atom()}},
    diag_waiters = #{}         :: #{binary() => {gen_server:from(), reference()}},
    open_uris                  :: sets:set(binary()),
    queue                      :: queue:queue()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Look up a symbol by name. Returns {ok, #{uri, line, snippet}} or {error, Reason}.
-spec symbol_lookup(binary()) -> {ok, map()} | {error, term()}.
symbol_lookup(Name) ->
    gen_server:call(?SERVER, {symbol_lookup, Name}, 60000).

%% Apply a text edit (0-indexed line/char range) to a file on disk,
%% notify ELP, and wait for diagnostics. Returns {ok, [Diagnostic]} or {error, Reason}.
-spec apply_edit(binary(), non_neg_integer(), non_neg_integer(),
                 non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, [map()]} | {error, term()}.
apply_edit(Path, StartLine, StartChar, EndLine, EndChar, NewText) ->
    gen_server:call(?SERVER, {apply_edit, Path, StartLine, StartChar,
                               EndLine, EndChar, NewText}, 15000).

-spec uri_to_path(binary()) -> binary().
uri_to_path(<<"file://", Path/binary>>) -> Path;
uri_to_path(Other)                       -> Other.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ElpName = application:get_env('mustachioed_llama', elp_path, "elp"),
    case os:find_executable(ElpName) of
        false ->
            logger:warning("lsp_client: elp (~s) not found (~s), LSP tools unavailable", [ElpName, os:getenv("PATH")]),
            {ok, #state{port      = nil,
                        status    = unavailable,
                        open_uris = sets:new([{version, 2}]),
                        queue     = queue:new()}};
        ElpPath ->
            Port = open_port({spawn_executable, ElpPath},
                             [{args, ["server"]}, binary, use_stdio, exit_status]),
            {ok, #state{port      = Port,
                        open_uris = sets:new([{version, 2}]),
                        queue     = queue:new()},
             {continue, initialize}}
    end.

handle_continue(initialize, #state{port = Port} = State) ->
    Msg = #{jsonrpc => ~"2.0",
            id      => 0,
            method  => ~"initialize",
            params  => #{
                processId  => list_to_integer(os:getpid()),
                rootUri    => path_to_uri(project_root()),
                clientInfo => #{name => ~"mustachioed_llama", version => ~"0.1.0"},
                capabilities => #{
                    workspace => #{symbol => #{dynamicRegistration => false}}
                }
            }},
    port_command(Port, frame(Msg)),
    {noreply, State}.

handle_call(_Request, _From, #state{status = unavailable} = State) ->
    {reply, {error, elp_unavailable}, State};

%% Queue calls that arrive before the initialize handshake or source-file
%% loading completes.  symbol_lookup needs the full index; apply_edit only
%% needs the LSP handshake, so it is not queued during loading.
handle_call({symbol_lookup, _} = Request, From,
            #state{status = S, queue = Q} = State)
        when S =:= initializing; S =:= loading ->
    {noreply, State#state{queue = queue:in({Request, From}, Q)}};

handle_call(Request, From, #state{status = initializing, queue = Q} = State) ->
    {noreply, State#state{queue = queue:in({Request, From}, Q)}};

handle_call({symbol_lookup, Name}, From,
            #state{port = Port, next_id = Id, pending = P} = State) ->
    case binary:split(Name, ~B[":"]) of
        [Module, Function] ->
            %% Qualified module:function — find the module file via workspace/symbol,
            %% then locate the function via textDocument/documentSymbol.
            Msg = #{jsonrpc => ~"2.0",
                    id      => Id,
                    method  => ~"workspace/symbol",
                    params  => #{query => Module}},
            port_command(Port, frame(Msg)),
            {noreply, State#state{next_id = Id + 1,
                                  pending = P#{Id => {From, {function_in_module, Function}}}}};
        [_] ->
            %% Unqualified — workspace/symbol directly (works for module names).
            Msg = #{jsonrpc => ~"2.0",
                    id      => Id,
                    method  => ~"workspace/symbol",
                    params  => #{query => Name}},
            port_command(Port, frame(Msg)),
            {noreply, State#state{next_id = Id + 1,
                                  pending = P#{Id => {From, symbol_lookup}}}}
    end;

handle_call({apply_edit, Path, SL, SC, EL, EC, NewText}, From,
            #state{port = Port, next_id = Id,
                   diag_waiters = DW, open_uris = OU} = State) ->
    URI     = path_to_uri(Path),
    {ok, Original} = file:read_file(Path),
    Patched = apply_text_edit(Original, SL, SC, EL, EC, NewText),
    ok      = file:write_file(Path, Patched),
    case sets:is_element(URI, OU) of
        false ->
            Notif = #{jsonrpc => ~"2.0",
                      method  => ~"textDocument/didOpen",
                      params  => #{textDocument => #{
                          uri        => URI,
                          languageId => ~"erlang",
                          version    => 1,
                          text       => Patched
                      }}},
            port_command(Port, frame(Notif));
        true ->
            Notif = #{jsonrpc => ~"2.0",
                      method  => ~"textDocument/didChange",
                      params  => #{
                          textDocument   => #{uri => URI, version => Id},
                          contentChanges => [#{text => Patched}]
                      }},
            port_command(Port, frame(Notif))
    end,
    TRef    = erlang:start_timer(?DIAG_TIMEOUT, self(), {diag_timeout, URI}),
    {noreply, State#state{next_id      = Id + 1,
                          open_uris    = sets:add_element(URI, OU),
                          diag_waiters = DW#{URI => {From, TRef}}}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({Port, {data, Chunk}}, #state{port = Port, buffer = Buf} = State) ->
    NewBuf = <<Buf/binary, Chunk/binary>>,
    {Frames, Rest} = parse_frames(NewBuf, []),
    NewState = lists:foldl(fun(F, S) -> handle_message(json:decode(F), S) end,
                           State#state{buffer = Rest},
                           Frames),
    {noreply, NewState};

handle_info({Port, {exit_status, Code}}, #state{port = Port} = State) ->
    {stop, {elp_exited, Code}, State};

handle_info({timeout, TRef, {diag_timeout, URI}},
            #state{diag_waiters = DW} = State) ->
    case maps:take(URI, DW) of
        {{From, TRef}, NewDW} ->
            gen_server:reply(From, {error, diagnostics_timeout}),
            {noreply, State#state{diag_waiters = NewDW}};
        _ ->
            {noreply, State}
    end;

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{port = Port, open_uris = OU}) ->
    sets:fold(fun(URI, _) ->
        Notif = #{jsonrpc => ~"2.0",
                  method  => ~"textDocument/didClose",
                  params  => #{textDocument => #{uri => URI}}},
        port_command(Port, frame(Notif))
    end, ok, OU),
    port_close(Port).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

handle_message(#{~"id" := 0, ~"result" := _},
               #state{port = Port, status = initializing} = State) ->
    %% Send initialized notification.
    port_command(Port, frame(#{jsonrpc => ~"2.0",
                               method  => ~"initialized",
                               params  => #{}})),
    %% Open one source file to trigger ELP's lazy project load.
    %% Without this, workspace/symbol always returns -32801 "still loading".
    TriggerFile = path_to_uri(lsp_client_src_path()),
    case file:read_file(lsp_client_src_path()) of
        {ok, Content} ->
            port_command(Port, frame(#{jsonrpc => ~"2.0",
                                       method  => ~"textDocument/didOpen",
                                       params  => #{textDocument => #{
                                           uri        => TriggerFile,
                                           languageId => ~"erlang",
                                           version    => 1,
                                           text       => Content
                                       }}}));
        {error, _} ->
            ok
    end,
    %% Transition to loading; symbol_lookup calls stay queued until
    %% $/progress reports "Loading source files" complete.
    State#state{status = loading};

handle_message(#{~"id" := Id, ~"result" := Result},
               #state{pending = P} = State) ->
    case maps:take(Id, P) of
        {{From, symbol_lookup}, NewP} ->
            gen_server:reply(From, format_symbol_result(Result)),
            State#state{pending = NewP};
        {{From, {function_in_module, Function}}, NewP} ->
            handle_module_symbol_result(Result, Function, From, State#state{pending = NewP});
        {{From, {doc_symbol_search, Function, URI}}, NewP} ->
            gen_server:reply(From, find_function_in_doc_symbols(Result, Function, URI)),
            State#state{pending = NewP};
        {{From, _}, NewP} ->
            gen_server:reply(From, {ok, Result}),
            State#state{pending = NewP};
        error ->
            State
    end;

handle_message(#{~"id" := Id, ~"error" := Error},
               #state{pending = P} = State) ->
    case maps:take(Id, P) of
        {{From, _}, NewP} ->
            gen_server:reply(From, {error, Error}),
            State#state{pending = NewP};
        error ->
            State
    end;

handle_message(#{~"method" := ~"textDocument/publishDiagnostics",
                 ~"params" := #{~"uri" := URI, ~"diagnostics" := Diags}},
               #state{diag_waiters = DW} = State) ->
    case maps:take(URI, DW) of
        {{From, TRef}, NewDW} ->
            erlang:cancel_timer(TRef),
            gen_server:reply(From, {ok, Diags}),
            State#state{diag_waiters = NewDW};
        error ->
            State
    end;

%% ELP finishes indexing: transition loading -> ready and drain queued calls.
handle_message(#{~"method" := ~"$/progress",
                 ~"params" := #{~"value" := #{~"kind" := ~"end",
                                              ~"message" := ~"Loading source files"}}},
               #state{status = loading, queue = Q} = State) ->
    drain_queue(queue:to_list(Q), State#state{status = ready, queue = queue:new()});

%% Server-to-client requests (capability (un)registration): just acknowledge.
handle_message(#{~"id" := Id, ~"method" := ~"client/registerCapability"},
               #state{port = Port} = State) ->
    port_command(Port, frame(#{jsonrpc => ~"2.0", id => Id, result => null})),
    State;

handle_message(#{~"id" := Id, ~"method" := ~"client/unregisterCapability"},
               #state{port = Port} = State) ->
    port_command(Port, frame(#{jsonrpc => ~"2.0", id => Id, result => null})),
    State;

%% Server-to-client requests for code-lens refresh etc.: acknowledge.
handle_message(#{~"id" := Id, ~"method" := _},
               #state{port = Port} = State) ->
    port_command(Port, frame(#{jsonrpc => ~"2.0", id => Id, result => null})),
    State;

handle_message(_Other, State) -> State.

drain_queue([], State) -> State;
drain_queue([{Request, From} | Rest], State) ->
    {noreply, NewState} = handle_call(Request, From, State),
    drain_queue(Rest, NewState).

format_symbol_result(null)  -> {error, not_found};
format_symbol_result([])    -> {error, not_found};
format_symbol_result([First | _]) ->
    #{~"location" := #{~"uri"   := URI,
                       ~"range" := #{~"start" := #{~"line" := Line}}}} = First,
    Path    = uri_to_path(URI),
    Snippet = read_snippet(Path, Line),
    {ok, #{uri => URI, line => Line + 1, snippet => Snippet}}.

%% Step 2 of qualified lookup: got the module file, now request documentSymbol.
handle_module_symbol_result(null, _, From, State) ->
    gen_server:reply(From, {error, not_found}), State;
handle_module_symbol_result([], _, From, State) ->
    gen_server:reply(From, {error, not_found}), State;
handle_module_symbol_result([#{~"location" := #{~"uri" := URI}} | _], Function, From,
                             #state{port = Port, next_id = Id, pending = P,
                                    open_uris = OU} = State) ->
    NewOU = case sets:is_element(URI, OU) of
        false ->
            Path = uri_to_path(URI),
            case file:read_file(Path) of
                {ok, Content} ->
                    port_command(Port, frame(#{jsonrpc => ~"2.0",
                                               method  => ~"textDocument/didOpen",
                                               params  => #{textDocument => #{
                                                   uri        => URI,
                                                   languageId => ~"erlang",
                                                   version    => 1,
                                                   text       => Content
                                               }}}));
                {error, _} -> ok
            end,
            sets:add_element(URI, OU);
        true ->
            OU
    end,
    Msg = #{jsonrpc => ~"2.0",
            id      => Id,
            method  => ~"textDocument/documentSymbol",
            params  => #{textDocument => #{uri => URI}}},
    port_command(Port, frame(Msg)),
    State#state{next_id   = Id + 1,
                pending   = P#{Id => {From, {doc_symbol_search, Function, URI}}},
                open_uris = NewOU}.

%% Search a (possibly hierarchical) DocumentSymbol list for a function by name.
%% ELP names functions as "name/arity", so "do_chat" matches "do_chat/2".
find_function_in_doc_symbols(null, _, _)  -> {error, not_found};
find_function_in_doc_symbols([], _, _)    -> {error, not_found};
find_function_in_doc_symbols(Syms, Func, URI) when is_list(Syms) ->
    Path = uri_to_path(URI),
    Flat = flatten_doc_symbols(Syms),
    case [S || S <- Flat, function_name_match(maps:get(~"name", S, <<>>), Func)] of
        [] ->
            {error, not_found};
        [First | _] ->
            Range  = maps:get(~"selectionRange", First, maps:get(~"range", First, #{})),
            Line   = maps:get(~"line", maps:get(~"start", Range, #{}), 0),
            {ok, #{uri => URI, line => Line + 1, snippet => read_snippet(Path, Line)}}
    end.

%% Flatten hierarchical DocumentSymbol trees (children field) into a flat list.
flatten_doc_symbols([]) -> [];
flatten_doc_symbols([S | Rest]) ->
    Children = maps:get(~"children", S, []),
    [S | flatten_doc_symbols(Children)] ++ flatten_doc_symbols(Rest).

%% Match ELP's "name/arity" symbol names against a bare function name query.
function_name_match(SymName, QueryName) ->
    QLen = byte_size(QueryName),
    case SymName of
        <<Pfx:QLen/binary, $/, _/binary>> -> Pfx =:= QueryName;
        _                                 -> SymName =:= QueryName
    end.

read_snippet(Path, Line) ->
    case file:read_file(Path) of
        {ok, Content} ->
            Lines  = binary:split(Content, ~"\n", [global]),
            Start  = max(0, Line - 1),
            Count  = min(length(Lines) - Start, 8),
            Slice  = lists:sublist(Lines, Start + 1, Count),
            iolist_to_binary(lists:join(~"\n", Slice));
        {error, _} ->
            <<>>
    end.

parse_frames(Buf, Acc) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [Header, Rest] ->
            case extract_content_length(Header) of
                {ok, Len} when byte_size(Rest) >= Len ->
                    <<Body:Len/binary, Remaining/binary>> = Rest,
                    parse_frames(Remaining, [Body | Acc]);
                _ ->
                    {lists:reverse(Acc), Buf}
            end;
        [_] ->
            {lists:reverse(Acc), Buf}
    end.

extract_content_length(Header) ->
    case re:run(Header, ~"Content-Length: (\\d+)", [{capture, [1], binary}]) of
        {match, [N]} -> {ok, binary_to_integer(N)};
        nomatch      -> {error, no_content_length}
    end.

frame(Map) ->
    Body   = json:encode(Map),
    Length = iolist_size(Body),
    ["Content-Length: ", integer_to_list(Length), "\r\n\r\n", Body].

%% Locate the project root by walking up from the compiled beam file
%% until we find rebar.config.
project_root() ->
    BeamFile = code:which(?MODULE),
    find_project_root(filename:dirname(BeamFile)).

lsp_client_src_path() ->
    filename:join([project_root(), "src", "lsp_client.erl"]).

find_project_root(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true  -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true  -> Dir;
                false -> find_project_root(Parent)
            end
    end.

path_to_uri(Path) when is_binary(Path) ->
    AbsPath = filename:absname(Path),
    <<"file://", AbsPath/binary>>;
path_to_uri(Path) ->
    path_to_uri(list_to_binary(Path)).

apply_text_edit(Content, SL, SC, EL, EC, NewText) ->
    Lines     = binary:split(Content, ~"\n", [global]),
    StartOff  = line_col_offset(Lines, SL, SC),
    EndOff    = line_col_offset(Lines, EL, EC),
    ReplLen   = EndOff - StartOff,
    <<Before:StartOff/binary, _:ReplLen/binary, After/binary>> = Content,
    iolist_to_binary([Before, NewText, After]).

line_col_offset(Lines, TargetLine, TargetCol) ->
    line_col_offset(Lines, 0, TargetLine, TargetCol, 0).

line_col_offset(_, Line, TargetLine, TargetCol, Offset) when Line =:= TargetLine ->
    Offset + TargetCol;
line_col_offset([L | Rest], Line, TargetLine, TargetCol, Offset) ->
    line_col_offset(Rest, Line + 1, TargetLine, TargetCol,
                    Offset + byte_size(L) + 1);  %% +1 for \n
line_col_offset([], _, _, TargetCol, Offset) ->
    Offset + TargetCol.
