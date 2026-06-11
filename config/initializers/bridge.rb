# Local bridge delegation reliability (docs/local-bridge.md, "Reliability").
#
# Progress is the heartbeat: claiming a delegated task and posting events
# both stamp tasks.last_reported_at. A claim silent past claim_ttl is
# reclaimed by ReclaimSilentBridgeTasksJob — returned to the unclaimed
# pool for the next pull. The TTL must sit above the progress cadence the
# served skill teaches, or a healthy-but-quiet client gets reclaimed
# mid-work.
Rails.application.config.x.bridge.claim_ttl =
  ENV.fetch("METIS_BRIDGE_CLAIM_TTL_MINUTES", "15").to_i.minutes

# Reclaims before the sweeper gives up: the task fails and the run
# surfaces it. A step that keeps killing its client should not cycle
# silently forever.
Rails.application.config.x.bridge.reclaim_cap =
  ENV.fetch("METIS_BRIDGE_RECLAIM_CAP", "3").to_i
