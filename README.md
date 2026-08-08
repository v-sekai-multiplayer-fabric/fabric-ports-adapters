# fabric-quickstart

Recreate a FoundationDB-backed Rivet cluster locally on **podman + systemd
quadlets**.

```sh
mix test                                          # no podman needed
mix run -e 'RivetFabric.CLI.main(["doctor"])'     # check prerequisites
mix run -e 'RivetFabric.CLI.main(["fdb-up"])'     # bring up the cluster
mix run -e 'RivetFabric.CLI.main(["destroy"])'    # tear it down
```
