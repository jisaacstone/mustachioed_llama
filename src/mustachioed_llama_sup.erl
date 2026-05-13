%%%-------------------------------------------------------------------
%% mustachioed_llama top level supervisor.
%%%-------------------------------------------------------------------

-module(mustachioed_llama_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 1
    },
    Mode = case init:get_argument(ask) of
        {ok, [[Question | _]]} -> {one_shot, Question};
        error -> application:get_env(mustachioed_llama, repl_mode, stdio)
    end,
    ChildSpecs = [
        #{
            id      => lsp_client,
            start   => {lsp_client, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type    => worker,
            modules => [lsp_client]
        },
        #{
            id      => mustachioed_llama_repl,
            start   => {mustachioed_llama_repl, start_link, [Mode]},
            restart => permanent,
            shutdown => 5000,
            type    => worker,
            modules => [mustachioed_llama_repl]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
