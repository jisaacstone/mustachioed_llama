%%%-------------------------------------------------------------------
%% Stateful REPL for mustachioed_llama.
%%
%% Runs an input loop in its own process. Each user message is sent to
%% Ollama along with a rolling window of recent history, and the reply
%% is printed and appended to the history.
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

-export([start_link/0, chat/1, get_messages/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([loop/0]).

-define(SERVER, ?MODULE).
-define(MODEL, <<"llama3.2">>).
-define(DEFAULT_NUM_CTX,     1024).
-define(DEFAULT_MAX_HISTORY, 20).

-record(state, {
    messages    = [] :: [map()],
    num_ctx          :: pos_integer(),
    max_history      :: pos_integer()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Send a user message, get the assistant reply back.
chat(Input) ->
    gen_server:call(?SERVER, {chat, Input}, 60000).

get_messages() ->
    gen_server:call(?SERVER, get_messages).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    NumCtx     = application:get_env(mustachioed_llama, num_ctx,      ?DEFAULT_NUM_CTX),
    MaxHistory = application:get_env(mustachioed_llama, max_history,  ?DEFAULT_MAX_HISTORY),
    spawn_link(?MODULE, loop, []),
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

handle_cast(_Msg, State)     -> {noreply, State}.
handle_info(_Info, State)    -> {noreply, State}.
terminate(_Reason, _State)   -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% REPL input loop
%%--------------------------------------------------------------------

loop() ->
    case io:get_line(">> ") of
        eof             -> shutdown();
        {error, _}      -> shutdown();
        Line ->
            Input = string:trim(Line, trailing, "\n\r"),
            case Input of
                "exit" ->
                    shutdown();
                "" ->
                    loop();
                _ ->
                    case chat(Input) of
                        {ok, Reply} ->
                            io:format("~s~n~n", [Reply]);
                        {error, Reason} ->
                            io:format("[error] ~p~n~n", [Reason])
                    end,
                    loop()
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

%% Calls Ollama and loops if it responds with tool calls, returning
%% the final text reply and the updated full message list.
do_chat(Messages, Opts) ->
    case guanco_app:generate_chat_completion(?MODEL, Messages, Opts) of
        {ok, #{~"message" := #{~"tool_calls" := ToolCalls} = AssistantMsg}} ->
            %% Store the assistant turn (with tool_calls) then execute each tool.
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
