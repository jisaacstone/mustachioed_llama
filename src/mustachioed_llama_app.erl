%%%-------------------------------------------------------------------
%% @doc mustachioed_llama public API
%% @end
%%%-------------------------------------------------------------------

-module(mustachioed_llama_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Host = application:get_env(mustachioed_llama, host, "localhost"),
    Port = application:get_env(mustachioed_llama, port, 11434),
    Url = lists:flatten(io_lib:format("http://~s:~w", [Host, Port])),
    application:set_env(guanco, ollama_api_url, Url),
    mustachioed_llama_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
