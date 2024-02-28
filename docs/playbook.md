# Playbook

# Issues and Fixes

## Drop in IOT Config Service updates

When HPR stops receiving updates from ICS (IOT Config Service) it means that no new device, joining devices or remove devices can transit threw this HPR anymore.

1. If updates started coming in again on their own run the command `hpr config route refresh_all` to make sure that we have all updates for each route.
2. If still no updates are coming in:
   1. Run `hpr config reset stream --commit`, this will create a new stream to ICS over the same connection.
   2. Run `hpr config reset channel --commit`, this will create a new connectdion to ICS and then a new stream.
   3. If neither of those work, restart the HPR service

*Notes:*
- *When updates stop it is hard to know if connection went down or if load balancer is doing something weird.*
- *HPR can be restarted safely at any time as it it keeping all the routing information on disk for quick restart.*

# Commands

`hpr info key` Print HPR's Public Key

`hpr trace` Create log file to trace device or gateway
```
Usage:

trace gateway <gateway_name>    - Trace Gateway (ex: happy-yellow-bird)
trace devaddr <devaddr>         - Trace Device Address (ex: 00000010)
trace app_eui <app_eui>         - Trace App EUI (ex: B216CDC4ABB9437)
trace dev_eui <dev_eui>         - Trace Dev EUI (ex: B216CDC4ABB9437)
```

`hpr config`

```
Usage:

config ls                                   - List
config oui <oui>                            - Info for OUI
    [--display_euis] default: false (EUIs not included)
    [--display_skfs] default: false (SKFs not included)
config route <route_id>                     - Info for route
    [--display_euis] default: false (EUIs not included)
    [--display_skfs] default: false (SKFs not included)
config route refresh_all                    - Refresh all routes
    [--minimum] default: 1 (need a minimum of 1 SKFs ro be updated)
config route refresh <route_id>             - Refresh route
config route activate <route_id>            - Activate route
config route deactivate <route_id>          - Deactivate route
config skf <DevAddr/Session Key>            - List all Session Key Filters for Devaddr or Session Key
config eui --app <app_eui> --dev <dev_eui>  - List all Routes with EUI pair


config counts                       - Simple Counts of Configuration
config checkpoint next              - Time until next writing of configuration to disk
config checkpoint write             - Write current configuration to disk
config reset checkpoint [--commit]  - Set checkpoint timestamp to beginning of time (0)
config reset stream [--commit]      - Reset stream to Configuration Service
config reset channel [--commit]     - Reset channel to Configuration Service
```
