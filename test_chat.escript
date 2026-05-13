#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/mustachioed_llama/ebin _build/default/lib/guanco/ebin _build/default/lib/hackney/ebin _build/default/lib/jiffy/ebin _build/default/lib/certifi/ebin _build/default/lib/ssl_verify_fun/ebin _build/default/lib/idna/ebin _build/default/lib/mimerl/ebin _build/default/lib/metrics/ebin _build/default/lib/unicode_util_compat/ebin _build/default/lib/poolboy/ebin _build/default/lib/parse_trans/ebin _build/default/lib/worker_pool/ebin

main(_Args) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(guanco),
    {ok, _} = lsp_client:start_link(),
    {ok, _} = mustachioed_llama_repl:start_link(headless),

    io:format("Sending: Hello! Who are you?~n~n"),
    case mustachioed_llama_repl:chat("Hello! Who are you?") of
        {ok, Reply} ->
            io:format("=== REPLY ===~n~s~n=============~n", [Reply]);
        {error, Reason} ->
            io:format("ERROR: ~p~n", [Reason])
    end.
