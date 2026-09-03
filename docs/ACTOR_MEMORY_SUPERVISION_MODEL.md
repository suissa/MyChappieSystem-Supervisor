# Actor Memory & Supervision Model

## Purpose

Define how AllasCode Actions become supervised Actors with BEAM-inspired lifecycle semantics while maintaining deterministic and explicitly bounded memory.

The objective is not to reproduce the BEAM heap implementation. The objective is to reuse the strongest operational ideas from BEAM:

- isolated lightweight execution entities;
- message-driven behavior;
- parent Supervisors;
- restart/replacement strategies;
- failures contained to the smallest possible unit;
- state recovery through explicit boundaries rather than hidden shared memory.

AllasCode adds a stricter requirement: runtime-critical ActionActor memory must have a hard configured ceiling.

---

# 1. Execution hierarchy

```text
DevelopmentSupervisor
└── ProjectSupervisor
    ├── RuntimeSupervisor
    │   ├── FlowSupervisor
    │   │   ├── IntentSupervisor
    │   │   │   ├── AgentSupervisor
    │   │   │   │   ├── ActorSupervisor
    │   │   │   │   │   ├── ActionActor
    │   │   │   │   │   ├── ActionActor
    │   │   │   │   │   └── ActionActor
    │   │   │   │   └── ...
    │   │   │   └── ...
    │   │   └── ...
    │   └── ...
    ├── GitHubSupervisor
    ├── ServerSupervisor
    ├── DatabaseSupervisor
    ├── MessagingSupervisor
    └── TelemetrySupervisor
```

Every Action execution is represented by an `ActionActor` instance. A canonical Action definition may execute many times; each attempt receives its own Actor identity and bounded runtime state.

---

# 2. Memory ownership rule

An ActionActor must not own business state that must survive the Actor.

```text
Durable/recoverable state
    -> EventStore / checkpoint / supervisor-owned state

Actor memory
    -> temporary execution state only
```

This rule is what makes replacement safe.

If an ActionActor reaches its memory quota, the Supervisor can terminate it and create another Actor without losing the authoritative state required to resume.

---

# 3. Per-Actor fixed memory budget

Each ActionActor is created with a `MemoryBudget` before execution begins.

Example:

```zig
pub const MemoryBudget = struct {
    working_set_bytes: usize,
    mailbox_bytes: usize,
    io_buffer_bytes: usize,
    result_bytes: usize,
    checkpoint_bytes: usize,
};
```

The Supervisor reserves the complete budget before starting the Actor.

No runtime-critical path may silently increase the Actor reservation.

Suggested initial profile:

```yaml
actors:
  defaults:
    working_set: 256KiB
    mailbox: 64KiB
    io_buffer: 64KiB
    result: 64KiB
    checkpoint: 64KiB
    memory_pressure_soft_limit: 80%
    memory_pressure_hard_limit: 100%
```

The real defaults must be benchmarked and configurable by Action class.

---

# 4. Fixed memory layout

A possible Actor reservation:

```text
ActorMemoryRegion
├── Header / metadata
├── Working arena
├── Mailbox ring
├── Input buffer
├── Output/result buffer
├── Scratch buffer
└── Checkpoint staging buffer
```

All structures are fixed-capacity or bounded.

Avoid unbounded runtime containers. Prefer:

- fixed arrays;
- ring buffers;
- bounded hash tables with fixed capacity;
- slab pools;
- object pools;
- fixed-buffer allocators;
- bounded arenas that cannot request another backing allocation.

---

# 5. Memory pressure lifecycle

Do not wait for a hard allocation failure before acting.

```text
0% ----------------------------------------------- 100%
                     ^                         ^
                     |                         |
                 soft limit                hard limit
                  e.g. 80%                   100%
```

At the soft limit:

1. emit `actor.memory_pressure`;
2. stop or reduce intake of new mailbox work;
3. checkpoint resumable progress;
4. ask the Supervisor for replacement/handoff;
5. create a fresh Actor allocation;
6. transfer only canonical checkpoint/mailbox data;
7. resume execution;
8. retire and zero old memory.

At the hard limit:

1. allocator returns a controlled quota error;
2. Actor must not request additional memory;
3. Supervisor marks the attempt `memory_exhausted`;
4. recover from the last committed checkpoint;
5. replace or escalate according to policy.

---

# 6. Replacement semantics

```text
ActionActor A
   |
   | memory_pressure
   v
Supervisor
   |
   +--> commit checkpoint N
   |
   +--> spawn ActionActor B with fresh region
   |
   +--> restore checkpoint N
   |
   +--> move/replay bounded pending messages
   |
   +--> retire Actor A
```

The replacement Actor gets a new `actor_id` but retains:

- `action_id`;
- `execution_id`;
- `trace_id`;
- `correlation_id`;
- last committed checkpoint ID.

This makes the handoff visible in telemetry instead of pretending it was the same process.

---

# 7. Mailbox model

Each Actor has a bounded mailbox.

The mailbox must define capacity in messages and/or bytes.

Overflow policy is explicit per message class:

- backpressure sender;
- coalesce replaceable telemetry;
- reject with structured overload event;
- dead-letter;
- escalate to Supervisor.

Business commands/state transitions must never be silently discarded.

---

# 8. Supervisor-owned memory pools

To avoid general-purpose dynamic allocation during normal execution, Supervisors should reserve memory pools at startup.

```text
ProjectSupervisor MemoryPool
├── Actor slot 0001
├── Actor slot 0002
├── Actor slot 0003
├── ...
└── Actor slot N
```

An Actor receives a slot or a bounded composition of fixed-size slabs.

When an Actor terminates:

1. sensitive buffers are zeroized;
2. region metadata is reset;
3. slot returns to the Supervisor pool.

If no Actor slot is available, the system returns explicit backpressure rather than allocating an unbounded new region.

---

# 9. No hidden business-state sharing

Actors communicate using messages/events.

They must not rely on shared mutable pointers for domain state.

Shared infrastructure may exist for immutable metadata, interned schemas or read-only code, but execution state follows Actor ownership rules.

---

# 10. Native trusted mode versus hard-isolation mode

This distinction is mandatory.

## Native trusted mode

The Action is native Zig code executing inside the DevelopmentSupervisor/runtime process.

The host:

- injects only a bounded allocator/memory region;
- exposes a restricted Action ABI;
- statically checks project code for forbidden allocator patterns where possible;
- audits Action modules;
- refuses unbounded container construction on critical paths by convention/tooling.

This gives deterministic behavior **for trusted code following the runtime contract**, but it is not a security boundary. Native code can theoretically call OS allocation APIs or another allocator if the module is allowed to contain arbitrary code.

## Hard-isolation mode

Required when the phrase "cannot exceed the memory limit" must be true even for buggy/untrusted Action code.

Possible enforcement planes:

### WASM ActionActor

- each Action instance has bounded linear memory;
- host capabilities are explicitly imported;
- no direct OS allocation unless exposed;
- memory growth can be disabled or capped;
- strong fit for dynamically loaded Actions.

### Isolated worker process

- native Action executes outside the Supervisor process;
- Linux: cgroup v2 `memory.max`/related resource controls;
- Windows: Job Object memory/process limits;
- process termination enforces the boundary externally.

The TUI/runtime sees both execution modes through the same Actor protocol.

---

# 11. Recommended AllasCode modes

```yaml
actors:
  isolation:
    default: native_bounded

  profiles:
    trusted_fast:
      mode: native_bounded
      memory: 256KiB

    strict:
      mode: wasm_bounded
      memory: 512KiB

    native_strict:
      mode: process_bounded
      memory: 16MiB
```

This keeps the common trusted Action path extremely lightweight while allowing actual hard isolation when required.

---

# 12. Actor state checkpoints

Checkpoint boundaries should be semantic, not arbitrary memory dumps.

Example:

```text
Action execution
  -> parse input
  -> checkpoint(parsed)
  -> normalize
  -> checkpoint(normalized)
  -> validate
  -> checkpoint(validated)
  -> external effect
  -> checkpoint(effect_committed)
  -> output
```

Do not attempt to copy raw stacks or pointers between Actor instances.

Replacement resumes from a canonical serializable checkpoint.

---

# 13. External effects and exactly-once illusions

A replacement Actor must not blindly repeat an external side effect.

Every effectful Action requires:

- idempotency key;
- effect state (`not_started`, `prepared`, `committed`, `confirmed`);
- durable checkpoint around the effect boundary;
- reconciliation path when outcome is unknown.

Memory-pressure replacement is therefore coupled to Action state semantics, not just memory management.

---

# 14. Runtime events

At minimum emit:

- `actor.created`
- `actor.started`
- `actor.mailbox_pressure`
- `actor.memory_pressure`
- `actor.checkpoint_started`
- `actor.checkpoint_committed`
- `actor.replacement_requested`
- `actor.replacement_started`
- `actor.replaced`
- `actor.memory_exhausted`
- `actor.failed`
- `actor.completed`
- `supervisor.restart_intensity_exceeded`

The TUI must visualize these events.

---

# 15. Metrics

Per Actor:

- reserved bytes
- used bytes
- peak bytes
- quota percentage
- mailbox messages
- mailbox bytes
- messages processed
- execution duration
- checkpoint count/time
- replacement count
- restart count
- CPU time where measurable

Supervisor:

- pool capacity
- pool usage
- free Actor slots
- actors by state
- restart rate
- replacement rate
- backpressure count

---

# 16. TUI representation

Actor memory should be visible directly in the Flow/Actor inspector.

Example:

```text
ActionActor Inventory.removeProducts#attempt-2

State        RUNNING
Memory       184 KiB / 256 KiB   72%
Mailbox      6 / 128 messages
Checkpoint   normalized#42
Restarts     0
Replacements 1
CPU          3.1%
Server       local
```

When soft pressure is reached, the Actor changes state before failure and the replacement transition appears in the execution timeline.

---

# 17. Required tests

- Actor cannot allocate past host-provided bounded allocator.
- Pool exhaustion creates backpressure instead of hidden allocation.
- Mailbox capacity is enforced.
- Actor memory region is zeroized/recycled after termination.
- Soft-limit replacement resumes from checkpoint.
- Hard-limit failure is contained.
- Sibling Actor remains valid after one Actor exhausts memory.
- Restart-intensity limits work.
- Poison message does not create infinite restart loop.
- Effectful Action does not duplicate an already committed side effect after replacement.
- Hard-isolation profile cannot exceed OS/WASM memory ceiling.

---

# Core invariant

```text
The Actor owns bounded transient execution memory.
The Supervisor owns lifecycle and resource allocation.
Durable state lives outside the Actor.
Effects are idempotent/checkpointed.
Replacement is explicit and observable.
```

That is the AllasCode interpretation of BEAM-style supervision under deterministic memory constraints.