-module(llama_tool_lsp_write).

-behaviour(llama_tool).

-include("llama_tool.hrl").

-export([definition/0, execute/1]).

-spec definition() -> llama_tool:tool_def().
definition() ->
    #tool_def{
        name        = ~"lsp_write",
        description = ~"Apply a text edit to an Erlang source file and return ELP diagnostics. Lines and characters are 0-indexed.",
        parameters  = #{
            ~"path"       => #param_spec{type = ~"string",  description = ~"Absolute path to the .erl file"},
            ~"start_line" => #param_spec{type = ~"integer", description = ~"0-indexed start line of the range to replace"},
            ~"start_char" => #param_spec{type = ~"integer", description = ~"0-indexed start character offset within start_line"},
            ~"end_line"   => #param_spec{type = ~"integer", description = ~"0-indexed end line of the range to replace"},
            ~"end_char"   => #param_spec{type = ~"integer", description = ~"0-indexed end character offset within end_line"},
            ~"new_text"   => #param_spec{type = ~"string",  description = ~"Replacement text (may span multiple lines)"}
        },
        required    = [~"path", ~"start_line", ~"start_char",
                       ~"end_line", ~"end_char", ~"new_text"]
    }.

-spec execute(#{binary() => term()}) -> binary().
execute(#{~"path"       := Path,
          ~"start_line" := SL,
          ~"start_char" := SC,
          ~"end_line"   := EL,
          ~"end_char"   := EC,
          ~"new_text"   := NewText}) when is_binary(Path), is_number(SL), is_number(SC), is_number(EL), is_number(EC), is_binary(NewText) ->
    case lsp_client:apply_edit(Path, SL, SC, EL, EC, NewText) of
        {ok, []} ->
            ~"Edit applied successfully. No diagnostics.";
        {ok, Diags} ->
            Lines = [format_diagnostic(D) || D <- Diags],
            iolist_to_binary(["Edit applied. Diagnostics:\n" | Lines]);
        {error, Reason} ->
            iolist_to_binary(io_lib:format("Error: ~p", [Reason]))
    end;
execute(Args) ->
    iolist_to_binary(io_lib:format("error: missing required arguments, got: ~p", [Args])).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

format_diagnostic(#{~"severity" := Sev, ~"message" := Msg,
                    ~"range" := #{~"start" := #{~"line" := L}}}) ->
    SevStr = case Sev of 1 -> "error"; 2 -> "warning"; 3 -> "info"; _ -> "hint" end,
    io_lib:format("  [~s] line ~w: ~s\n", [SevStr, L + 1, Msg]);
format_diagnostic(D) ->
    io_lib:format("  ~p\n", [D]).
