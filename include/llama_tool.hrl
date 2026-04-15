-record(param_spec, {
    type        :: binary(),
    description :: binary()
}).

-record(tool_def, {
    name        :: binary(),
    description :: binary(),
    parameters  :: #{binary() => #param_spec{}},
    required    :: [binary()]
}).
