-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '_hpr_metrics_tick').

-define(METRICS_GRPC_CONNECTION_GAUGE, "hpr_grpc_connection_gauge").
-define(METRICS_PACKET_UP_HISTOGRAM, "hpr_packet_up_histogram").

-define(METRICS, [
    {?METRICS_GRPC_CONNECTION_GAUGE, prometheus_gauge, [], "Number of active GRPC Connections"},
    {?METRICS_PACKET_UP_HISTOGRAM, prometheus_histogram, [type, status, routes],
        "Packet UP duration"}
]).
