# DevelopmentSupervisor — Implementation Backlog

This document is an issue-ready backlog for transforming this ZigZag fork into the AllasCode **DevelopmentSupervisor**: a bidirectional real-time terminal control plane for development, implementation, CI/CD, runtime supervision, infrastructure, production operations, telemetry, GitHub and SSH-managed servers.

> Repository note: GitHub Issues are currently disabled. Each section below is intentionally structured as an independent issue and can be created as soon as Issues are enabled.

---

## 1. [EPIC] Transform the ZigZag fork into the AllasCode DevelopmentSupervisor

### Goal
Turn the project into the single terminal control plane for an AllasCode project across local development, CI, runtime, production, telemetry, GitHub, databases, messaging infrastructure and remote servers.

### Core principles
- Zig 0.16+.
- ZigZag remains the TUI foundation.
- Every runtime Action executes as an isolated Actor managed by a Supervisor.
- Supervision is BEAM-inspired, but runtime-critical memory is strictly bounded and preallocated.
- Canonical `RuntimeEvent` and `RuntimeCommand` protocol independent of transport.
- Commands: REST + WebSocket.
- Events/telemetry: WebSocket + SSE.
- Local bridge: stdio/NDJSON.
- GitHub operations available from the TUI.
- Servers declared in `config.yml` and managed over SSH.
- Any automatic operation must also be invokable manually through the same command registry.
- All state-changing commands are auditable and capability-gated.

### Definition of done
Starting the supervisor opens a complete real-time dashboard capable of observing and controlling the configured project, local runtime, GitHub repository, tests, databases, messaging infrastructure and remote servers.

---

## 2. Define canonical RuntimeEvent, RuntimeCommand, RuntimeSnapshot and EntityRef protocols

### Goal
Create a single transport-agnostic protocol consumed by the TUI, EventStore, WebSocket, SSE, stdio, OTEL and future transports.

### Required entities
`project`, `flow`, `intent`, `agent`, `actor`, `action`, `attempt`, `function`, `event`, `process`, `thread`, `server`, `database`, `queue`, `workflow`, `test`.

### RuntimeEvent requirements
- protocol version
- monotonic sequence number
- timestamp
- project/runtime/server IDs
- trace/span/parent span IDs
- entity reference
- event kind
- bounded payload
- severity
- causation/correlation IDs

### RuntimeCommand requirements
- command ID
- target entity
- command type
- parameters
- actor/user/source
- capability required
- timeout/deadline
- idempotency key
- expected state/version when applicable

### Acceptance criteria
- Versioned schema.
- Deterministic serialization.
- Bounded payload limits.
- NDJSON representation.
- Golden tests for compatibility.

---

## 3. Convert Actions into bounded-memory Actors with BEAM-inspired Supervisors

### Goal
Every executable Action must run inside an isolated Actor with a mailbox and a parent Supervisor.

### Important distinction
This must be **BEAM-inspired supervision**, not a literal BEAM heap implementation. BEAM processes use independently managed heaps that may grow and garbage collect. The AllasCode runtime instead requires strict deterministic memory ceilings.

### Requirements
- one Action execution context = one Actor instance
- supervisor-owned actor lifecycle
- isolated actor state
- bounded mailbox
- explicit actor memory quota
- fixed arena/slab/pool allocated before execution
- no unbounded `ArrayList`, HashMap growth or implicit heap allocation on runtime-critical paths
- no shared mutable actor state
- actor state transitions emitted as RuntimeEvents
- restart strategy configurable per Actor/Action

### Actor states
`created`, `queued`, `running`, `waiting`, `paused`, `completed`, `failed`, `memory_exhausted`, `cancelled`, `restarting`, `replaced`.

### Acceptance criteria
- Actor cannot allocate beyond configured quota.
- Quota violation is observable and recoverable.
- Actor failure cannot corrupt sibling actors.
- Supervisor tests demonstrate isolation and replacement.

---

## 4. Implement SupervisorTree and restart/replacement strategies

### Goal
Implement a supervision tree comparable in operational behavior to BEAM supervisors while preserving AllasCode deterministic memory constraints.

### Strategies
- `one_for_one`
- `one_for_all`
- `rest_for_one`
- `temporary`
- `transient`
- `permanent`

### Memory exhaustion behavior
When an Actor approaches or reaches its quota:
1. stop accepting new messages for that Actor;
2. emit `actor.memory_pressure`;
3. persist/checkpoint recoverable state outside the Actor-owned memory region;
4. start a replacement Actor with a fresh fixed allocation;
5. resume from the last stable action boundary;
6. emit `actor.replaced` with old/new IDs.

### Guardrails
- restart intensity window
- maximum restart count
- exponential backoff where appropriate
- poison-message detection
- dead-letter handling
- supervisor escalation

### Acceptance criteria
Demonstrate deterministic restart behavior for failure, timeout, mailbox overflow and memory exhaustion.

---

## 5. Replace AsyncRunner internals with bounded concurrent queues and worker pools

### Goal
Remove race/leak risk and avoid one OS thread per async task.

### Requirements
- bounded MPSC/MPMC queue as appropriate
- fixed-capacity worker pool
- explicit queue pressure metrics
- no unbounded task allocation
- task cancellation
- deadlines
- priority support
- safe reclamation of task contexts
- deterministic shutdown

### Acceptance criteria
- thread sanitizer/race-oriented stress tests where supported
- zero leaked task contexts in long-running tests
- queue full behavior tested
- configurable backpressure policy

---

## 6. Implement RuntimeEventBus with bounded fan-out and backpressure

### Goal
Decouple producers from TUI, storage and transport consumers.

### Consumers
- TUI
- WebSocket
- SSE
- stdio
- EventStore
- OpenTelemetry
- file/log sink

### Requirements
- bounded per-consumer ring buffer
- priority classes
- never drop critical state transitions/errors/command results
- configurable dropping/coalescing for high-frequency metrics
- lag metrics per subscriber
- subscriber disconnect policy

### Acceptance criteria
A slow dashboard/browser cannot block the runtime or another subscriber.

---

## 7. Implement bidirectional REST/WebSocket/SSE control plane

### Goal
Provide remote control and real-time observability.

### Protocol roles
- REST: commands, queries, snapshots and administrative operations
- WebSocket: bidirectional commands + events
- SSE: server-to-client event/telemetry stream

### Required endpoints
- `GET /health`
- `GET /snapshot`
- `GET /events` (SSE)
- `GET /ws`
- `POST /commands`
- `GET /commands/{id}`
- `GET /capabilities`

### Requirements
- command acknowledgements
- command result events
- idempotency
- reconnection/resume by sequence
- bounded request/response sizes
- authentication hooks

---

## 8. Implement stdio/NDJSON bridge for local processes and tooling

### Goal
Bridge local process stdio to the canonical runtime protocol without mixing ANSI TUI output with machine-readable events.

### Architecture
- TUI uses `/dev/tty` on POSIX or `CONIN$`/`CONOUT$` on Windows when needed.
- stdin/stdout can remain machine-readable NDJSON.
- one event/command per line.
- transport adapter translates NDJSON to RuntimeEvent/RuntimeCommand.

### Modes
- stdio -> WebSocket
- WebSocket -> stdio
- SSE -> stdio observer mode
- stdio -> SSE broadcaster

### Acceptance criteria
Pipe the supervisor through another process while the TUI remains fully interactive and ANSI never contaminates NDJSON.

---

## 9. Build the DevelopmentSupervisor TUI shell and fixed real-time header

### Goal
Create the main production-grade dashboard UI.

### Header
Always visible and continuously updated:
- runtime state
- active flows
- running/waiting/failed Actors
- Actions completed/failed
- CPU
- RAM
- disk I/O
- network I/O
- event rate
- p95 latency
- test status
- GitHub workflow status
- connected servers

### Visual system
Use a dark terminal dashboard with an adaptive neon gradient ranging from light cyan/blue to purple for graphs, progress indicators and active state accents, while retaining semantic warning/error colors.

### Main views
- Overview
- Flows
- Agents/Actors
- Actions
- Traces
- Metrics
- Events
- Logs
- Processes
- GitHub
- Servers
- Databases
- Tests
- Deployments
- Control

---

## 10. Implement LiveGraph for 2flow/Intent/Agent/Actor/Action execution

### Goal
Render live AllasCode execution topology instead of presenting only logs.

### Hierarchy
`Project -> Flow -> Intent -> Agent -> Actor -> Action -> Attempt -> Span`

### Features
- active node highlighting
- edge event animation
- waiting state
- retry state
- failure state
- elapsed duration
- expand/collapse
- node inspector
- input/output metadata with safe truncation
- trace correlation

### Acceptance criteria
A running `.2flow` can be visually followed from start to completion in real time.

---

## 11. Implement Timeline, TraceWaterfall and historical attempts view

### Goal
Expose temporal causality and retries.

### Requirements
- waterfall per trace
- Action attempts shown individually
- parent/child spans
- queue time vs execution time
- remote server origin
- CPU/memory samples per span when available
- failed/retried annotations
- zoom and filter

### Acceptance criteria
A user can identify where a Flow spent time without opening an external trace UI.

---

## 12. Implement complete hardware and process telemetry

### Goal
Monitor local and remote hardware in real time.

### Metrics
- total/per-core CPU
- memory used/available
- swap
- filesystem capacity
- disk read/write throughput and latency
- network RX/TX
- load average
- open files/handles where available
- thread/process count
- temperatures/frequencies when supported
- GPU utilization/memory when supported by platform adapter

### Top-10 process views
Maintain both:
1. current top 10 heaviest processes;
2. historical top 10 process peaks observed during the session/window.

Rank dimensions:
- CPU peak
- memory peak
- cumulative CPU
- disk I/O
- network I/O where observable

### Visualization
- sparkline history
- time-series charts
- gauges
- heatmaps
- cyan/blue -> purple gradients

---

## 13. Add OpenTelemetry-compatible trace/metric/log adapter

### Goal
Keep DevelopmentSupervisor telemetry interoperable with external observability tooling.

### Requirements
- RuntimeEvent -> trace/span mapping
- metrics export
- logs export
- resource attributes for project/runtime/server/actor/action
- trace ID propagation
- sampling configuration
- local-only mode without OTEL dependency at core runtime level

---

## 14. Integrate EventStore/replay/resume for reconnect and historical inspection

### Goal
Allow reconnect without gaps and inspect prior execution.

### Requirements
- monotonic event sequence
- last-seen sequence tracking
- replay from sequence
- live tail after catch-up
- snapshot + delta bootstrap
- bounded local cache
- EventStore adapter
- offline/reconnect state in TUI

### Acceptance criteria
Disconnecting and reconnecting a dashboard does not lose critical execution state.

---

## 15. Implement GitHub Control Plane integration

### Goal
Normal project supervision should not require opening github.com.

### Observe
- repository state
- branches
- commits
- pull requests
- review state
- issues
- checks/statuses
- workflow runs
- workflow jobs and steps
- logs
- artifacts
- releases/tags when supported

### Control
- rerun failed workflow jobs
- rerun selected job
- inspect logs/artifacts
- create/update issues
- create/update PRs
- add reviews/comments
- merge PR
- update branches where permitted

### UX
Dedicated GitHub view plus global status in the main header.

### Authentication
Use configured GitHub App/token/credential provider; never place tokens in plain-text config.

---

## 16. Implement SSH Server Registry and authentication modes from config.yml

### Goal
Declare managed servers in configuration and operate them from the DevelopmentSupervisor.

### Example model
```yaml
servers:
  - id: prod-1
    host: 203.0.113.10
    port: 22
    user: deploy
    auth:
      mode: agent

  - id: staging-1
    host: 203.0.113.11
    user: deploy
    auth:
      mode: identity_file
      identity_file: ~/.ssh/id_ed25519
```

### Supported auth modes
- `agent`: reuse `ssh-agent`, including identities already loaded by WSL/session
- `identity_file`: SSH private key, preferably passphrase-protected and unlocked through agent
- `interactive_password`: prompt when required; keep only in a bounded zeroized secret buffer for the shortest possible lifetime
- `batch`: fail instead of prompting

### Important rule
Do not persist SSH passwords in config or state. Prefer `ssh-agent` so a passphrase is entered once per agent/session and subsequent server connections reuse the unlocked identity.

### Additional requirements
- known_hosts verification
- configurable strict host-key checking
- connection status/latency
- reconnect policy
- per-server capability restrictions

---

## 17. Implement remote ServerActor/Supervisor and SSH command execution

### Goal
Each configured server is represented as a supervised runtime entity.

### Capabilities
- inspect processes/services
- start/stop/restart service
- tail logs
- execute declared maintenance commands
- inspect files/configuration
- upload/download approved artifacts
- health checks
- deploy/rollback
- clone/scale service instances
- collect telemetry
- execute tests/benchmarks remotely

### Guardrails
- allowlist commands/capabilities
- no unrestricted shell by default
- per-server concurrency limits
- timeout
- output size limit
- audit trail

---

## 18. Implement transactional config.yml hot reload without runtime restart

### Goal
Allow `config.reload` from the TUI, REST or WebSocket without restarting the system.

### Algorithm
1. read candidate config
2. parse and validate schema
3. resolve dependencies
4. produce semantic diff
5. reject unsafe/incompatible changes
6. apply atomically
7. notify affected Supervisors/Actors
8. rollback on apply failure
9. emit config version/change events

### Required controls
- reload
- validate only
- preview diff
- rollback previous config
- show active config version

---

## 19. Implement universal CommandRegistry: every automatic operation must also be manually invokable

### Goal
Create one command abstraction shared by automation, TUI, REST, WebSocket and tests.

### Command metadata
- canonical name
- description
- target types
- parameter schema
- required capability
- safety classification
- idempotency semantics
- timeout
- supports dry-run
- supports rollback
- automation sources allowed

### UX
- searchable command palette
- contextual command menu
- command history
- repeat command
- inspect result

### Required command families
See `docs/CONTROL_ACTION_CATALOG.md`.

---

## 20. Implement database administration adapters

### Goal
Manage configured data stores from the same control plane.

### Generic capabilities
- health/status
- connections
- storage size
- query latency
- replication state
- backup
- restore
- compact/vacuum where applicable
- migration status
- schema/version inspection
- read-only toggle where supported

### Cluster capabilities
- add/remove replica
- promote replica
- failover
- rebalance
- shard/split shard where supported
- clone node
- bootstrap node

### Rule
Database-specific operations live behind adapters and capability schemas; never assume all databases support replication/sharding in the same way.

---

## 21. Implement messaging/queue administration adapters

### Goal
Operate NATS, QUIC adapters, Kafka, RabbitMQ, Redpanda, BullMQ and future messaging systems through one control model.

### Capabilities
- health
- broker/node status
- topics/subjects/streams/queues
- consumer lag
- backlog
- throughput
- redelivery
- pause/resume consumer
- purge with explicit destructive confirmation
- add/remove/replace broker where supported
- rebalance/partition operations where supported

---

## 22. Implement Test & Quality Orchestrator

### Goal
Run and observe all project validation from the TUI locally, remotely or in CI.

### Test classes
- unit
- integration
- security
- Snyk/dependency security where configured
- load
- stress
- benchmark
- BDD
- E2E
- static analysis/lint
- format checks
- coverage

### Controls
- run all
- run selected suite
- run selected test
- parallel execution
- distribute to configured servers
- cancel
- retry failures
- compare benchmark to baseline
- inspect coverage
- export result

### TUI
Real-time totals, passed/failed/running/skipped, duration, coverage and resource usage.

---

## 23. Implement CI/CD and deployment control plane

### Goal
Treat build, release, deploy and rollback as observable RuntimeActions.

### Commands
- build
- package
- publish artifact
- deploy staging
- deploy production
- canary deploy
- blue/green switch
- rollback
- restart service
- scale out/in
- create clone instance
- drain instance
- health verify

### Requirements
- deployment graph
- server targets
- logs
- rollback metadata
- audit trail

---

## 24. Integrate DevelopmentSupervisor into Zig build workflow

### Goal
Make project-level Zig builds able to start the DevelopmentSupervisor as a first-class build step/module.

### Clarification
`zig build` consumes `build.zig`; a source file is normally compiled directly with commands such as `zig build-exe main.zig`. Therefore integration should be implemented in `build.zig`, for example:

- `zig build supervise`
- optional project-defined default run step that starts the supervisor
- reusable build module/helper that another AllasCode project's `build.zig` can import

### Requirements
- no hidden global configuration
- config path option
- headless mode for CI
- TUI mode for interactive terminals
- graceful fallback when no TTY is available

---

## 25. Implement security, capabilities, audit and destructive-operation safeguards

### Goal
A control plane capable of SSH, deploy, DB operations and GitHub writes must make authorization explicit.

### Requirements
- capability model per command/target
- observe-only mode
- local-admin mode
- remote-control mode
- immutable audit event for every command
- who/what initiated command
- before/after state references
- dry-run support
- explicit confirmation class for destructive commands
- command idempotency
- replay protection
- bounded secret buffers with zeroization
- secrets never emitted into logs/events

---

## 26. Implement adaptive rendering and high-rate telemetry performance controls

### Goal
Keep the TUI inexpensive even while the runtime emits high-volume telemetry.

### Requirements
- dirty rendering/event-driven refresh
- configurable FPS ceiling
- metric coalescing
- chart sampling/downsampling
- virtualized large lists
- bounded history windows
- no unbounded UI state
- render/update timing metrics
- dropped/coalesced telemetry counters

### Acceptance criteria
Dashboard remains responsive under stress while runtime work retains priority.

---

## 27. Add DevelopmentSupervisor self-observability and self-supervision

### Goal
The supervisor itself must expose its own health.

### Metrics
- memory used/quota by internal Actor
- mailbox depth
- restart counts
- event bus lag
- transport clients
- command latency
- dropped/coalesced metric count
- renderer latency/FPS
- GitHub API state/rate limit where available
- SSH connection pool state

### Failure model
Transport/UI failures must not terminate supervised project processes unnecessarily.

---

## 28. Build end-to-end reference scenario

### Goal
Demonstrate the complete control plane on a realistic AllasCode project.

### Scenario
1. start DevelopmentSupervisor
2. load config.yml
3. connect GitHub
4. connect local runtime
5. connect two SSH servers through ssh-agent
6. render hardware telemetry
7. start a Flow
8. follow Agent -> Actor -> Action execution live
9. trigger a test suite manually
10. hot reload config.yml
11. rerun a failed GitHub workflow job
12. clone/scale a configured service on a server
13. invoke a database maintenance command through an adapter
14. disconnect/reconnect UI and replay missed events
15. inspect audit log

### Definition of done
All operations are visible in the TUI, produce RuntimeEvents, preserve bounded-memory guarantees and can be driven through the appropriate REST/WebSocket command API.