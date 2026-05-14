%%%-------------------------------------------------------------------
%% mustachioed_llama public API
%%%-------------------------------------------------------------------

-module(mustachioed_llama_app).

-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% -model NAME overrides the configured model.  Handled here rather than via
    %% -mustachioed_llama model NAME because Ollama tag syntax (e.g. llama3.1:8b)
    %% is not a valid Erlang term and would be rejected by the app controller.
    case init:get_argument(model) of
        {ok, [[Name | _]]} -> application:set_env(mustachioed_llama, model, Name);
        error              -> ok
    end,
    Host = application:get_env(mustachioed_llama, host, "localhost"),
    Port = application:get_env(mustachioed_llama, port, 11434),
    Url = lists:flatten(io_lib:format("http://~s:~w", [Host, Port])),
    ?LOG_INFO("Starting mustachioed_llama with url ~s, dir ~s, path ~s", [Url, file:get_cwd(), os:getenv("PATH")]),
    application:set_env(guanco, ollama_api_url, Url),
    mustachioed_llama_sup:start_link().

stop(_State) ->
    ok.
