%% @doc Behavior and shared types for tool definitions.
%%
%% To add a new tool:
%%   1. Create llama_tool_<name>.erl implementing this behavior.
%%   2. Add the module to the list in llama_tools:all/0.
%%
%% The behavior enforces two callbacks:
%%   definition/0  -- returns a #tool_def{} describing the tool for Ollama
%%   execute/1     -- receives the argument map from Ollama, returns output as binary

-module(llama_tool).

-export([to_ollama/1]).

-include("llama_tool.hrl").

-type param_spec() :: #param_spec{}.
-type tool_def()   :: #tool_def{}.

-export_type([param_spec/0, tool_def/0]).

%%--------------------------------------------------------------------
%% Behavior
%%--------------------------------------------------------------------

-callback definition() -> tool_def().
-callback execute(Args :: #{binary() => term()}) -> binary().

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Convert a #tool_def{} to the map format expected by Ollama/guanco.
-spec to_ollama(tool_def()) -> map().
to_ollama(#tool_def{name = Name, description = Desc,
                    parameters = Params, required = Required}) ->
    Properties = maps:map(fun(_K, #param_spec{type = T, description = D}) ->
        #{type => T, description => D}
    end, Params),
    #{
        type     => <<"function">>,
        function => #{
            name        => Name,
            description => Desc,
            parameters  => #{
                type       => <<"object">>,
                properties => Properties,
                required   => Required
            }
        }
    }.
