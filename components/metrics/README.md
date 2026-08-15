# components/metrics/

Not yet implemented.

Will provide: the pod label (`observability.scrap.io/scrape: "true"`) and the `metrics`-named
container port convention that the single, cluster-wide `PodMonitor` in `platform/observability/`
already scrapes. An application never ships its own `PodMonitor`.
