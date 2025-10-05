-module(compile_all).
-export([go/0]).

go() ->
    filelib:ensure_dir("lib/placeholder"),
    lists:foreach(
      fun(F) -> compile:file(F, [{outdir,"lib"}]) end,
      filelib:wildcard("*.erl")
    ),
    halt().
