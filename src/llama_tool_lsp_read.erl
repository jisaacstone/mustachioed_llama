-module(llama_tool_lsp_read).

-behaviour(llama_tool).

-include("llama_tool.hrl").

-export([definition/0, execute/1]).

-spec definition() -> llama_tool:tool_def().
definition() ->
    #tool_def{
        name        = ~"lsp_read",
        description = ~"Look up an Erlang symbol by name using ELP. Returns its file location and a source snippet. Use 'module:function' format to look up a function (e.g. 'mustachioed_llama_repl:do_chat'). Use a bare module name to look up a module (e.g. 'lsp_client').",
        parameters  = #{
            ~"symbol" => #param_spec{
                type        = ~"string",
                description = ~"Symbol to look up. For functions: 'module:function' (e.g. 'mustachioed_llama_repl:do_chat'). For modules: bare module name (e.g. 'lsp_client')."
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
