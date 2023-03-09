-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '_hpr_metrics_tick').

-define(METRICS_GRPC_CONNECTION_GAUGE, "hpr_grpc_connection_gauge").
-define(METRICS_PACKET_UP_HISTOGRAM, "hpr_packet_up_histogram").
-define(METRICS_ROUTES_GAUGE, "hpr_routes_gauge").
-define(METRICS_EUI_PAIRS_GAUGE, "hpr_eui_pairs_gauge").
-define(METRICS_SKFS_GAUGE, "hpr_skfs_gauge").

-define(METRICS_VM_ETS_MEMORY, "hpr_vm_ets_memory").
-define(METRICS_VM_PROC_Q, "hpr_vm_process_queue").

-define(METRICS, [
    {?METRICS_GRPC_CONNECTION_GAUGE, prometheus_gauge, [], "Number of active GRPC Connections"},
    {?METRICS_PACKET_UP_HISTOGRAM, prometheus_histogram, [type, status, routes],
        "Packet UP duration"},
    {?METRICS_ROUTES_GAUGE, prometheus_gauge, [], "Number of Routes"},
    {?METRICS_EUI_PAIRS_GAUGE, prometheus_gauge, [], "Number of EUI Pairs"},
    {?METRICS_SKFS_GAUGE, prometheus_gauge, [], "Number of SKFs"},
    {?METRICS_VM_ETS_MEMORY, prometheus_gauge, [name], "HPR ets memory"},
    {?METRICS_VM_PROC_Q, prometheus_gauge, [name], "HPR process queue"}
]).
