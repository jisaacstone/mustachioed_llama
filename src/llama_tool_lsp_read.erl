-module(llama_tool_lsp_read).

-behaviour(llama_tool).

-include("llama_tool.hrl").

-export([definition/0, execute/1]).

-spec definition() -> llama_tool:tool_def().
definition() ->
    #tool_def{
        name        = ~"lsp_read",
        description = ~"Look up an Erlang symbol by name using ELP. Returns its file location and a source snippet.",
        parameters  = #{
            ~"symbol" => #param_spec{
                type        = ~"string",
                description = ~"The symbol name to look up (e.g. a function or module name)"
            }
        },
        required    = [~"symbol"]
    }.

-spec execute(#{binary() => term()}) -> binary().
execute(#{~"symbol" := Symbol}) ->
    case lsp_client:symbol_lookup(Symbol) of
        {ok, #{uri := URI, line := Line, snippet := Snippet}} ->
            Path = lsp_client:uri_to_path(URI),
            iolist_to_binary(io_lib:format("~s line ~w:\n\n~s", [Path, Line, Snippet]));
        {error, not_found} ->
            ~"Symbol not found.";
        {error, Reason} ->
            iolist_to_binary(io_lib:format("Error: ~p", [Reason]))
    end;
execute(Args) ->
    iolist_to_binary(io_lib:format("error: missing 'symbol' argument, got: ~p", [Args])).
