%%%-------------------------------------------------------------------
%% Stateful REPL for mustachioed_llama.
%%
%% Runs an input loop in its own process. Each user message is sent to
%% Ollama along with a rolling window of recent history, and the reply
%% is printed and appended to the history.
%%
%% The I/O source is pluggable via an io_backend(). Two backends are
%% provided: stdio (default) and pid (message-passing). Custom backends
%% can be passed directly to start_link/1.
%%
%% Configuration (sys.config):
%%   {mustachioed_llama, [{num_ctx, N}]}       -- Ollama context length in tokens (default 1024)
%%   {mustachioed_llama, [{max_history, N}]}   -- rolling window of messages in chat history (default 20)
%%
%% Override at launch:
%%   erl ... -mustachioed_llama num_ctx 4096
%%%-------------------------------------------------------------------

-module(mustachioed_llama_repl).

-behaviour(gen_server).

-export([start_link/0, start_link/1, chat/1, get_messages/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([loop/1]).

-define(SERVER, ?MODULE).
-define(MODEL, <<"llama3.2">>).
-define(DEFAULT_NUM_CTX,     1024).
-define(DEFAULT_MAX_HISTORY, 20).

%% An I/O backend: read/0 returns the next user input, write/1 delivers output.
-type io_backend() :: #{
    read  := fun(() -> {ok, string()} | eof | {error, term()}),
    write := fun((iodata()) -> ok)
}.

-record(state, {
    messages    = [] :: [map()],
    num_ctx          :: pos_integer(),
    max_history      :: pos_integer()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start_link() ->
    start_link(stdio).

%% Mode can be: stdio | headless | {pid, Pid} | io_backend()
start_link(Mode) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Mode], []).

chat(Input) ->
    gen_server:call(?SERVER, {chat, Input}, 60000).

get_messages() ->
    gen_server:call(?SERVER, get_messages).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Mode]) ->
    NumCtx     = application:get_env(mustachioed_llama, num_ctx,     ?DEFAULT_NUM_CTX),
    MaxHistory = application:get_env(mustachioed_llama, max_history, ?DEFAULT_MAX_HISTORY),
    case io_backend(Mode) of
        undefined -> ok;
        Backend   -> spawn_link(?MODULE, loop, [Backend])
    end,
    {ok, #state{num_ctx = NumCtx, max_history = MaxHistory}}.

handle_call({chat, Input}, _From, #state{messages = Msgs, num_ctx = NumCtx, max_history = MaxHistory} = State) ->
    UserMsg = #{role => ~"user", content => list_to_binary(Input)},
    History = Msgs ++ [UserMsg],
    Context = lists:nthtail(max(0, length(History) - MaxHistory), History),
    Opts = #{stream => false, options => #{num_ctx => NumCtx}, tools => llama_tools:definitions()},
    case do_chat(Context, Opts) of
        {ok, FinalContent, FinalMsgs} ->
            {reply, {ok, FinalContent}, State#state{messages = FinalMsgs}};
        {error, Reason} ->
            {reply, {error, Reason}, State#state{messages = History}}
    end;

handle_call(get_messages, _From, #state{messages = Msgs} = State) ->
    {reply, Msgs, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State)            -> {noreply, State}.
handle_info(_Info, State)           -> {noreply, State}.
terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% I/O backends
%%--------------------------------------------------------------------

-spec io_backend(stdio | headless | {pid, pid()} | io_backend()) -> io_backend() | undefined.
io_backend(headless) ->
    undefined;
io_backend(stdio) ->
    #{
        read  => fun() ->
            case io:get_line(">> ") of
                eof        -> eof;
                {error, R} -> {error, R};
                Line       -> {ok, string:trim(Line, trailing, "\n\r")}
            end
        end,
        write => fun(Output) -> io:format("~s~n~n", [Output]) end
    };
io_backend({pid, Pid}) ->
    #{
        read  => fun() ->
            Pid ! {repl_prompt, self()},
            receive
                {repl_input, Input} -> {ok, Input};
                repl_eof            -> eof
            after 300000 -> eof
            end
        end,
        write => fun(Output) -> Pid ! {repl_output, Output}, ok end
    };
io_backend(Backend) when is_map(Backend) ->
    Backend.

%%--------------------------------------------------------------------
%% Input loop
%%--------------------------------------------------------------------

-spec loop(io_backend()) -> no_return().
loop(#{read := Read, write := Write} = IO) ->
    case Read() of
        eof        -> shutdown();
        {error, _} -> shutdown();
        {ok, ""}   -> loop(IO);
        {ok, "exit"} -> shutdown();
        {ok, Input}  ->
            Output = case chat(Input) of
                {ok, Reply}     -> Reply;
                {error, Reason} -> io_lib:format("[error] ~p", [Reason])
            end,
            Write(Output),
            loop(IO)
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

do_chat(Messages, Opts) ->
    case guanco_app:generate_chat_completion(?MODEL, Messages, Opts) of
        {ok, #{~"message" := #{~"tool_calls" := ToolCalls} = AssistantMsg}} ->
            WithAssistant = Messages ++ [AssistantMsg],
            ToolResultMsgs = [execute_tool_call(TC) || TC <- ToolCalls],
            do_chat(WithAssistant ++ ToolResultMsgs, Opts);
        {ok, #{~"message" := #{~"content" := Content} = AssistantMsg}} ->
            {ok, Content, Messages ++ [AssistantMsg]};
        {ok, Other} ->
            {error, {unexpected_response, Other}};
        {error, Reason} ->
            {error, Reason}
    end.

execute_tool_call(#{~"function" := #{~"name" := Name, ~"arguments" := Args}}) ->
    io:format("[tool:~s] ~p~n", [Name, Args]),
    Result = llama_tools:execute(Name, Args),
    io:format("[tool:~s result]~n~s~n", [Name, Result]),
    #{role => ~"tool", content => Result};
execute_tool_call(Other) ->
    io:format("[tool] unexpected call format: ~p~n", [Other]),
    #{role => ~"tool", content => ~"error: unrecognised tool call format"}.

shutdown() ->
    io:format("Shutting down.~n"),
    init:stop().
