%%%-------------------------------------------------------------------
%% @doc mustachioed_llama top level supervisor.
%% @end
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
        strategy => one_for_all,
        intensity => 5,
        period => 1
    },
    ChildSpecs = [
        #{
            id      => mustachioed_llama_repl,
            start   => {mustachioed_llama_repl, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type    => worker,
            modules => [mustachioed_llama_repl]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
