%% @doc Registry of available tools.
%%
%% To register a new tool, add its module to all/0.

-module(llama_tools).

-export([all/0, definitions/0, execute/2]).

-include("llama_tool.hrl").

%% The list of all tool modules (each implements the llama_tool behaviour).
-spec all() -> [module()].
all() ->
    [llama_tool_bash].

%% Returns Ollama-format tool definitions for every registered tool.
-spec definitions() -> [map()].
definitions() ->
    [llama_tool:to_ollama(Mod:definition()) || Mod <- all()].

%% Dispatch a tool call by name, returning the output as a binary.
-spec execute(Name :: binary(), Args :: map()) -> binary().
execute(Name, Args) ->
    case lists:keyfind(Name, 1, [{tool_name(M), M} || M <- all()]) of
        {Name, Mod} -> Mod:execute(Args);
        false       -> iolist_to_binary(io_lib:format("unknown tool: ~s", [Name]))
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

tool_name(Mod) ->
    (Mod:definition())#tool_def.name.
