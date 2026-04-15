-module(llama_tool_bash).

-behaviour(llama_tool).

-include("llama_tool.hrl").

-export([definition/0, execute/1]).

-spec definition() -> llama_tool:tool_def().
definition() ->
    #tool_def{
        name        = <<"bash">>,
        description = <<"Execute a bash command and return its output (stdout and stderr combined)">>,
        parameters  = #{
            <<"command">> => #param_spec{
                type        = <<"string">>,
                description = <<"The bash command to run">>
            }
        },
        required    = [<<"command">>]
    }.

-spec execute(#{binary() => term()}) -> binary().
execute(#{<<"command">> := Cmd}) ->
    Output = os:cmd(binary_to_list(Cmd) ++ " 2>&1"),
    list_to_binary(Output);
execute(Args) ->
    iolist_to_binary(io_lib:format("error: missing 'command' argument, got: ~p", [Args])).
