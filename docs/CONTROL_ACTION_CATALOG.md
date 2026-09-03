# DevelopmentSupervisor Control Action Catalog

This document defines the initial canonical manual/automatic command surface for the AllasCode DevelopmentSupervisor.

## Fundamental rule

**Anything the system can do automatically must be invokable manually through the same `CommandRegistry`.**

Automation must not call privileged implementation functions directly. It emits the same `RuntimeCommand` a human/operator would invoke from the TUI, REST API or WebSocket.

Every command should declare:

- canonical command name
- target type
- parameter schema
- required capability
- read-only / mutating / destructive classification
- idempotency semantics
- timeout/deadline
- dry-run support
- rollback support
- audit requirements

---

# 1. Supervisor and runtime lifecycle

- `runtime.start`
- `runtime.stop`
- `runtime.restart`
- `runtime.pause`
- `runtime.resume`
- `runtime.shutdown_gracefully`
- `runtime.shutdown_now`
- `runtime.health_check`
- `runtime.snapshot`
- `runtime.dump_state`
- `runtime.restore_state`
- `runtime.reload`
- `runtime.set_log_level`
- `runtime.set_telemetry_level`
- `runtime.enable_trace`
- `runtime.disable_trace`
- `runtime.enter_maintenance`
- `runtime.exit_maintenance`
- `runtime.gc_hint` only for adapters/runtimes that support GC; not for bounded ActionActor arenas

# 2. Supervisor tree

- `supervisor.inspect`
- `supervisor.pause`
- `supervisor.resume`
- `supervisor.restart`
- `supervisor.restart_children`
- `supervisor.stop_children`
- `supervisor.start_children`
- `supervisor.set_restart_strategy`
- `supervisor.set_restart_intensity`
- `supervisor.escalate`
- `supervisor.clear_restart_counter`

# 3. Actor lifecycle

- `actor.spawn`
- `actor.stop`
- `actor.kill`
- `actor.restart`
- `actor.replace`
- `actor.pause`
- `actor.resume`
- `actor.inspect`
- `actor.snapshot`
- `actor.restore`
- `actor.drain_mailbox`
- `actor.clear_mailbox`
- `actor.move_mailbox_to_replacement`
- `actor.retry_last_message`
- `actor.dead_letter_last_message`
- `actor.set_memory_quota`
- `actor.set_mailbox_quota`
- `actor.set_priority`

# 4. Action execution

- `action.execute`
- `action.cancel`
- `action.pause`
- `action.resume`
- `action.retry`
- `action.retry_from_checkpoint`
- `action.skip`
- `action.inspect_input`
- `action.inspect_output`
- `action.inspect_attempts`
- `action.replay`
- `action.benchmark`
- `action.profile`
- `action.trace`
- `action.move_to_server`
- `action.force_local`
- `action.force_remote`

# 5. Flow execution

- `flow.start`
- `flow.stop`
- `flow.cancel`
- `flow.pause`
- `flow.resume`
- `flow.retry`
- `flow.retry_failed_branch`
- `flow.restart_from_node`
- `flow.skip_node`
- `flow.inspect_graph`
- `flow.inspect_state`
- `flow.snapshot`
- `flow.replay`
- `flow.validate`
- `flow.dry_run`
- `flow.set_priority`
- `flow.move_execution`

# 6. Intent management

- `intent.dispatch`
- `intent.cancel`
- `intent.retry`
- `intent.inspect`
- `intent.validate`
- `intent.replay`
- `intent.route_to_agent`
- `intent.escalate_to_human`

# 7. Agent management

- `agent.start`
- `agent.stop`
- `agent.restart`
- `agent.pause`
- `agent.resume`
- `agent.inspect`
- `agent.inspect_context`
- `agent.clear_ephemeral_context`
- `agent.snapshot`
- `agent.restore`
- `agent.rotate_model`
- `agent.set_model`
- `agent.set_tool_policy`
- `agent.set_budget`
- `agent.force_human_handoff`

# 8. Human-in-the-Healing-Loop

- `healing.list_pending`
- `healing.inspect`
- `healing.accept`
- `healing.reject`
- `healing.correct_payload`
- `healing.retry`
- `healing.defer`
- `healing.assign`
- `healing.resolve`

# 9. Configuration

- `config.validate`
- `config.reload`
- `config.preview_reload`
- `config.diff`
- `config.apply`
- `config.rollback`
- `config.show_active`
- `config.show_version`
- `config.export`
- `config.set_runtime_override`
- `config.clear_runtime_override`

# 10. Build

- `build.run`
- `build.clean`
- `build.rebuild`
- `build.debug`
- `build.release_safe`
- `build.release_fast`
- `build.release_small`
- `build.target`
- `build.cancel`
- `build.inspect_artifacts`
- `build.publish_artifact`

# 11. Test and quality

- `test.run_all`
- `test.run_suite`
- `test.run_one`
- `test.run_unit`
- `test.run_integration`
- `test.run_bdd`
- `test.run_e2e`
- `test.run_load`
- `test.run_stress`
- `test.run_security`
- `test.run_dependency_security`
- `test.run_benchmark`
- `test.run_coverage`
- `test.run_lint`
- `test.run_format_check`
- `test.run_static_analysis`
- `test.distribute`
- `test.cancel`
- `test.retry_failed`
- `test.compare_benchmark`
- `test.compare_coverage`
- `test.export_results`

# 12. Git local repository

- `git.status`
- `git.fetch`
- `git.pull`
- `git.push`
- `git.branch_create`
- `git.branch_delete`
- `git.branch_switch`
- `git.checkout`
- `git.commit`
- `git.diff`
- `git.log`
- `git.merge`
- `git.rebase`
- `git.stash`
- `git.stash_pop`
- `git.tag_create`
- `git.tag_delete`
- `git.reset` with destructive confirmation
- `git.clean` with destructive confirmation

# 13. GitHub repository observation

- `github.refresh`
- `github.repo.inspect`
- `github.branch.list`
- `github.commit.list`
- `github.commit.inspect`
- `github.pr.list`
- `github.pr.inspect`
- `github.issue.list`
- `github.issue.inspect`
- `github.workflow.list`
- `github.workflow.inspect`
- `github.workflow.logs`
- `github.workflow.artifacts`
- `github.checks.inspect`
- `github.release.list`

# 14. GitHub repository control

- `github.issue.create`
- `github.issue.update`
- `github.issue.close`
- `github.issue.reopen`
- `github.pr.create`
- `github.pr.update`
- `github.pr.review`
- `github.pr.comment`
- `github.pr.merge`
- `github.pr.close`
- `github.workflow.rerun_failed`
- `github.workflow.rerun_job`
- `github.artifact.download`
- `github.branch.create`
- `github.branch.update`
- `github.release.create` when connector/provider supports it

# 15. Dependency management

- `dependency.inspect`
- `dependency.outdated`
- `dependency.update_one`
- `dependency.update_all`
- `dependency.audit`
- `dependency.lock_refresh`
- `dependency.rollback`

# 16. Server registry / SSH

- `server.connect`
- `server.disconnect`
- `server.reconnect`
- `server.health_check`
- `server.inspect`
- `server.refresh`
- `server.test_auth`
- `server.test_latency`
- `server.rotate_connection`
- `server.enable`
- `server.disable`

# 17. Remote command execution

- `server.command.run_declared`
- `server.command.cancel`
- `server.command.retry`
- `server.command.inspect_output`
- `server.script.run_declared`
- `server.script.upload_and_run`

Unrestricted arbitrary shell should be disabled by default and capability-gated if implemented.

# 18. Processes

- `process.list`
- `process.inspect`
- `process.start`
- `process.stop`
- `process.terminate`
- `process.kill`
- `process.restart`
- `process.signal`
- `process.set_priority`
- `process.pin_cpu`
- `process.unpin_cpu`
- `process.capture_profile`
- `process.capture_trace`
- `process.tail_output`

# 19. Operating-system services

- `service.list`
- `service.inspect`
- `service.start`
- `service.stop`
- `service.restart`
- `service.reload`
- `service.enable`
- `service.disable`
- `service.logs`
- `service.status`

# 20. Containers

- `container.list`
- `container.inspect`
- `container.start`
- `container.stop`
- `container.restart`
- `container.pause`
- `container.resume`
- `container.remove`
- `container.logs`
- `container.stats`
- `container.exec_declared`
- `container.image.pull`
- `container.image.build`
- `container.image.remove`
- `container.clone`

# 21. Deployment

- `deploy.plan`
- `deploy.dry_run`
- `deploy.staging`
- `deploy.production`
- `deploy.canary`
- `deploy.blue_green_prepare`
- `deploy.blue_green_switch`
- `deploy.verify`
- `deploy.rollback`
- `deploy.cancel`
- `deploy.promote`
- `deploy.drain_instance`
- `deploy.restore_instance`

# 22. Scaling and cloning

- `scale.out`
- `scale.in`
- `scale.set_replicas`
- `server.clone`
- `service.clone`
- `runtime.clone`
- `instance.promote`
- `instance.demote`
- `instance.drain`
- `instance.undrain`
- `instance.replace`

# 23. Hardware telemetry/control

Observation:
- `hardware.refresh`
- `hardware.cpu.inspect`
- `hardware.memory.inspect`
- `hardware.disk.inspect`
- `hardware.network.inspect`
- `hardware.gpu.inspect`
- `hardware.temperature.inspect`
- `hardware.top_processes`
- `hardware.top_process_peaks`

Control where platform and policy allow:
- `hardware.cpu.set_affinity`
- `hardware.process.set_priority`
- `hardware.cache.drop` only with explicit destructive/maintenance policy

# 24. Filesystem

- `fs.list`
- `fs.inspect`
- `fs.tail`
- `fs.read`
- `fs.write_declared`
- `fs.copy`
- `fs.move`
- `fs.delete` with destructive confirmation
- `fs.mkdir`
- `fs.permissions.inspect`
- `fs.permissions.apply`
- `fs.disk_usage`
- `fs.find_large_files`

# 25. Logs

- `logs.tail`
- `logs.search`
- `logs.filter`
- `logs.set_level`
- `logs.export`
- `logs.rotate`
- `logs.archive`
- `logs.clear` with destructive confirmation

# 26. Traces

- `trace.list`
- `trace.inspect`
- `trace.follow`
- `trace.export`
- `trace.enable_target`
- `trace.disable_target`
- `trace.set_sampling`
- `trace.replay_related_events`

# 27. Metrics

- `metrics.inspect`
- `metrics.follow`
- `metrics.export`
- `metrics.set_interval`
- `metrics.set_retention_window`
- `metrics.reset_session_peaks`
- `metrics.compare_window`

# 28. EventStore / event sourcing

- `eventstore.health`
- `eventstore.tail`
- `eventstore.inspect_stream`
- `eventstore.replay`
- `eventstore.snapshot`
- `eventstore.compact` where supported
- `eventstore.backup`
- `eventstore.restore`
- `eventstore.verify_integrity`
- `eventstore.rebuild_projection`

# 29. SQL databases

Generic commands, only exposed when the adapter declares support:

- `database.health`
- `database.connections`
- `database.query_stats`
- `database.schema.inspect`
- `database.migration.plan`
- `database.migration.apply`
- `database.migration.rollback`
- `database.backup`
- `database.restore`
- `database.vacuum`
- `database.analyze`
- `database.read_only.enable`
- `database.read_only.disable`
- `database.replica.add`
- `database.replica.remove`
- `database.replica.promote`
- `database.failover`
- `database.shard.plan`
- `database.shard.apply`
- `database.rebalance`
- `database.node.clone`

# 30. NoSQL/document/vector/graph stores

Adapter-declared commands:

- `store.health`
- `store.stats`
- `store.index.inspect`
- `store.index.create`
- `store.index.rebuild`
- `store.index.drop`
- `store.replica.add`
- `store.replica.remove`
- `store.rebalance`
- `store.backup`
- `store.restore`
- `vector.index.optimize`
- `vector.collection.inspect`
- `graph.index.inspect`
- `graph.constraint.inspect`

# 31. Cache

- `cache.health`
- `cache.stats`
- `cache.keys.inspect`
- `cache.invalidate_key`
- `cache.invalidate_namespace`
- `cache.flush` with destructive confirmation
- `cache.replica.inspect`
- `cache.failover` where supported
- `cache.warm`

# 32. Messaging and queues

Generic adapter capabilities:

- `messaging.health`
- `messaging.stats`
- `messaging.topics.list`
- `messaging.subjects.list`
- `messaging.queues.list`
- `messaging.consumers.list`
- `messaging.consumer.inspect`
- `messaging.consumer.pause`
- `messaging.consumer.resume`
- `messaging.consumer.reset_offset`
- `messaging.consumer.retry_dead_letter`
- `messaging.backlog.inspect`
- `messaging.stream.create`
- `messaging.stream.update`
- `messaging.stream.delete`
- `messaging.queue.purge` with destructive confirmation
- `messaging.broker.add`
- `messaging.broker.remove`
- `messaging.rebalance`
- `messaging.partition.add`

# 33. Network

- `network.interfaces`
- `network.connections`
- `network.listeners`
- `network.dns.check`
- `network.route.inspect`
- `network.ping`
- `network.tcp_check`
- `network.http_check`
- `network.tls.inspect`
- `network.quic.check`
- `network.bandwidth.sample`
- `network.connection.close` when safe and capability-gated

# 34. Load balancer / gateway

- `gateway.health`
- `gateway.routes.inspect`
- `gateway.route.enable`
- `gateway.route.disable`
- `gateway.backend.add`
- `gateway.backend.remove`
- `gateway.backend.drain`
- `gateway.backend.undrain`
- `gateway.reload`
- `gateway.rate_limit.inspect`
- `gateway.rate_limit.update`

# 35. Backups and disaster recovery

- `backup.plan`
- `backup.run`
- `backup.verify`
- `backup.list`
- `backup.restore_test`
- `backup.restore`
- `backup.delete` with destructive confirmation
- `dr.failover`
- `dr.failback`
- `dr.simulate`
- `dr.verify_rpo`
- `dr.verify_rto`

# 36. Scheduler / jobs

- `job.list`
- `job.inspect`
- `job.run_now`
- `job.pause`
- `job.resume`
- `job.cancel`
- `job.retry`
- `job.enable`
- `job.disable`
- `job.reschedule`

# 37. Secrets and credentials

- `secret.provider.status`
- `secret.rotate`
- `secret.reload`
- `secret.test_access`
- `ssh.agent.status`
- `ssh.agent.list_identities`
- `ssh.agent.reload_identity`

Secrets themselves must never be rendered into normal RuntimeEvents or logs.

# 38. Certificates and cryptographic material

- `certificate.inspect`
- `certificate.expiry_check`
- `certificate.rotate`
- `certificate.reload`
- `mtls.status`
- `mtls.rotate_identity`
- `dpop.rotate_key`
- `pqc.rotate_key`

# 39. Security operations

- `security.audit`
- `security.scan`
- `security.dependencies.scan`
- `security.permissions.inspect`
- `security.capabilities.inspect`
- `security.session.revoke`
- `security.token.revoke`
- `security.block_target`
- `security.unblock_target`
- `security.rotate_credentials`

# 40. Rate limits / circuit breakers / bulkheads

- `resilience.circuit.inspect`
- `resilience.circuit.open`
- `resilience.circuit.close`
- `resilience.circuit.reset`
- `resilience.rate_limit.inspect`
- `resilience.rate_limit.update`
- `resilience.bulkhead.inspect`
- `resilience.bulkhead.update`

# 41. CPU scheduling and distribution

- `scheduler.inspect`
- `scheduler.mode.set_known`
- `scheduler.mode.set_unknown`
- `scheduler.action.pin_local`
- `scheduler.action.allow_distribution`
- `scheduler.action.force_distribution`
- `scheduler.worker.add`
- `scheduler.worker.remove`
- `scheduler.worker.drain`
- `scheduler.benchmark.refresh`
- `scheduler.threshold.update`

# 42. AI/model execution

- `model.list`
- `model.health`
- `model.load`
- `model.unload`
- `model.warm`
- `model.route`
- `model.set_fallback`
- `model.set_budget`
- `model.set_rate_limit`
- `model.cancel_request`
- `model.inspect_usage`

# 43. Search/indexing

- `search.health`
- `search.index.inspect`
- `search.index.rebuild`
- `search.index.optimize`
- `search.reindex`
- `search.document.retry`

# 44. Project management from GitHub

- `project.issue.create`
- `project.issue.assign`
- `project.issue.label`
- `project.issue.close`
- `project.pr.create`
- `project.pr.review`
- `project.pr.merge`
- `project.task.refresh`
- `project.release.inspect`

# 45. Release management

- `release.prepare`
- `release.validate`
- `release.tag`
- `release.build`
- `release.publish`
- `release.deploy`
- `release.rollback`
- `release.compare`

# 46. Documentation/tooling

- `docs.build`
- `docs.validate_links`
- `docs.generate_reference`
- `docs.serve_local`
- `schema.validate_all`
- `schema.generate`
- `schema.diff`

# 47. Observability dashboard control

- `tui.refresh`
- `tui.pause_stream`
- `tui.resume_stream`
- `tui.filter.set`
- `tui.filter.clear`
- `tui.layout.reset`
- `tui.view.switch`
- `tui.timeline.zoom`
- `tui.trace.follow`
- `tui.export_snapshot`
- `tui.theme.set`

# 48. Runtime EventBus

- `eventbus.inspect`
- `eventbus.subscribers`
- `eventbus.pause_subscriber`
- `eventbus.resume_subscriber`
- `eventbus.disconnect_subscriber`
- `eventbus.set_backpressure_policy`
- `eventbus.set_metric_coalescing`
- `eventbus.reset_counters`

# 49. Transport control

- `transport.list`
- `transport.inspect`
- `transport.start`
- `transport.stop`
- `transport.restart`
- `transport.ws.clients`
- `transport.sse.clients`
- `transport.disconnect_client`
- `transport.rotate_credentials`
- `transport.set_rate_limit`

# 50. Audit

- `audit.tail`
- `audit.search`
- `audit.inspect_command`
- `audit.export`
- `audit.verify_integrity`

---

# Safety classes

Every command should be categorized into at least one of these classes:

## `observe`
No state mutation. Examples: inspect metrics, list processes, inspect GitHub workflow.

## `safe_mutation`
State-changing but expected to be reversible or low-risk. Examples: pause/resume Actor, reload validated config.

## `operational`
Can affect availability. Examples: restart service, deploy, failover, scale.

## `destructive`
Can permanently remove or overwrite state. Examples: delete data, purge queue, drop index, hard reset repository.

`destructive` commands must support explicit policy/confirmation and should expose dry-run or preview where technically possible.

---

# Command invocation sources

The same canonical command may originate from:

- TUI
- REST
- WebSocket
- automation rule
- CI/CD
- Supervisor recovery policy
- test harness
- scheduled job
- remote operator

The source changes authorization/audit metadata, **not the implementation path**.

---

# Core invariant

```text
Automation ─┐
TUI ────────┤
REST ───────┤
WebSocket ──┼──> RuntimeCommand -> CommandRegistry -> Capability Check
CI/CD ──────┤                              │
Supervisor ─┤                              ▼
Tests ──────┘                         Command Actor
                                             │
                                             ▼
                                        RuntimeEvent
```

This invariant prevents hidden administrative behavior and guarantees that any automatic system action remains observable, reproducible and manually executable.