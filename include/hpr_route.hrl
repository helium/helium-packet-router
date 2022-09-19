-record(eui_pair, {
    app_eui :: non_neg_integer(),
    dev_eui :: non_neg_integer()
}).

-record(route, {
    net_id :: non_neg_integer(),
    lns :: binary(),
    protocol :: lns_protocol(),
    oui :: non_neg_integer(),
    devaddr_ranges = [] :: [devaddr_range()],
    euis = [] :: [eui_pair()]
}).

-type devaddr_range() :: {non_neg_integer(), non_neg_integer()}.

-type eui_pair() :: {non_neg_integer(), non_neg_integer()}.

-type lns_protocol() :: http | gwmp | router.

-type route() :: #route{}.
