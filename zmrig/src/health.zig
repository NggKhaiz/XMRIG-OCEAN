//! Health: is this miner still earning, or only still running?
//!
//! The failure this exists for is the quiet one. A miner that crashed is
//! visible: the service restarts, the log says why. A miner that is *running*
//! while nothing gets accepted looks identical to a healthy one from the
//! outside -- the process is alive, the log ticks, the dashboard shows a
//! hashrate -- and the income is zero. Three things cause it in practice:
//!
//!   * the hashrate collapsed (thermal throttle, a noisy neighbour, a stuck
//!     engine after a seed change) and nobody noticed because the number that
//!     was printed is the one from an hour ago;
//!   * the pool accepts the connection, hands out jobs, and rejects every
//!     share (wrong algorithm after a fork, a wrong wallet, a pool-side bug);
//!   * the pool went silent: connected, no jobs, no answers, and the miner
//!     sits in a read that never returns.
//!
//! Every rule here is a comparison between *this* machine's numbers, not a
//! constant from a manual: the peak a run has actually reached, the accepted
//! shares it has actually sent. A 400 H/s box and a 40 kH/s box are judged the
//! same way.
//!
//! The state machine is pure: `evaluate` takes a snapshot and returns a state,
//! so every rule is tested without a pool, a clock or a network.

const std = @import("std");

pub const Config = struct {
    /// Do not judge anything until the dataset is built and shares can flow.
    /// A seed change costs ~16-30 s of init on a desktop, longer on a laptop.
    warmup_seconds: u32 = 180,
    /// Hashrate this close to zero for this long is a stall, not a dip.
    stall_seconds: u32 = 120,
    /// Below this fraction of the best rate seen, the machine is degraded.
    degraded_ratio: f64 = 0.80,
    /// ... but only if it stays there: a pool switch always dips for a while.
    degraded_seconds: u32 = 600,
    /// Enough rejected shares to tell "the pool dislikes us" from a stray
    /// stale share, which is normal and healthy.
    min_rejections: u64 = 10,
};

pub const State = enum {
    /// Building the dataset, or too early to tell.
    warming,
    ok,
    /// Hashing, but well below the best this session has done, for long
    /// enough that it is not a blip.
    degraded,
    /// No hashes at all while the process is alive.
    stalled,
    /// Shares are being sent and the pool accepts none of them.
    rejected,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .warming => "warming",
            .ok => "ok",
            .degraded => "degraded",
            .stalled => "stalled",
            .rejected => "rejected",
        };
    }

    /// States worth waking someone up for. `warming` and `degraded` are not:
    /// one is normal, the other is a slow machine, not a broken one.
    pub fn isFault(self: State) bool {
        return self == .stalled or self == .rejected;
    }
};

pub const Snapshot = struct {
    /// Seconds since the process started.
    uptime_s: u64 = 0,
    rate_10s: f64 = 0,
    rate_60s: f64 = 0,
    /// Best 60 s rate this session.
    peak: f64 = 0,
    hashes: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    /// Submissions are paused because the pool kept calling shares invalid.
    /// A quarantined miner hashes and earns nothing, which is exactly the
    /// silent fault this file exists to catch.
    quarantined: bool = false,
    /// Shares handed to the submitter, accepted or not.
    submitted: u64 = 0,
    /// The user paused mining (`pause-on-battery`, `--pause-on-active`): the
    /// absence of hashes is intentional and must never be reported as a fault.
    paused: bool = false,
};

pub fn evaluate(snapshot: Snapshot, config: Config) State {
    if (snapshot.paused) return .warming;

    // Nothing is judged before the first hash, and not right after a seed
    // change: the dataset init is the slowest normal thing this program does.
    if (snapshot.hashes == 0 or snapshot.uptime_s < config.warmup_seconds) return .warming;

    // Rejections first: a pool that refuses every share is a fault even while
    // the hashrate looks perfect, and that is exactly the case a hashrate
    // check would miss.
    if (snapshot.quarantined) return .rejected;
    if (snapshot.rejected >= config.min_rejections and snapshot.accepted == 0) return .rejected;

    // A stall is measured on the 10 s window, so recovery is visible within
    // ten seconds of it happening rather than minutes later.
    if (snapshot.rate_10s <= 0) return .stalled;

    // Degraded needs a reference. Before one exists (`peak == 0`) there is
    // nothing to compare against and `ok` is the only honest answer.
    if (snapshot.peak > 0 and snapshot.rate_60s < snapshot.peak * config.degraded_ratio) return .degraded;

    return .ok;
}

/// Tracks how long a condition has held, so "for ten minutes" is enforceable
/// without the caller keeping a timer per state. The clock is passed in, which
/// is what makes the timing testable.
pub const Tracker = struct {
    config: Config = .{},
    state: State = .warming,
    /// When the current *candidate* state was first observed.
    candidate: State = .warming,
    candidate_since_ms: i64 = 0,
    /// Faults are re-checked against their own, longer, threshold.
    last_fault_ms: i64 = -1,
    fault_state: State = .ok,

    /// Feeds one sample. Returns the state that has actually *held* long
    /// enough to be reported, which is what stops a one-second dip from
    /// looking like a crisis.
    pub fn update(self: *Tracker, snapshot: Snapshot, now_ms: i64) State {
        const raw = evaluate(snapshot, self.config);

        if (raw != self.candidate) {
            self.candidate = raw;
            self.candidate_since_ms = now_ms;
        }

        const held_s = @divTrunc(now_ms - self.candidate_since_ms, 1000);
        const needed: i64 = switch (raw) {
            .stalled => @intCast(self.config.stall_seconds),
            .degraded => @intCast(self.config.degraded_seconds),
            .rejected => 0, // covered by min_rejections
            .warming, .ok => 0,
        };

        if (held_s < needed) {
            // Not long enough yet: keep reporting the last settled state, but
            // never keep reporting "ok" while a fault is building -- the
            // caller wants to know that something is wrong *now*.
            return if (raw.isFault()) raw else self.state;
        }

        if (raw.isFault() and self.state != raw) {
            self.last_fault_ms = now_ms;
            self.fault_state = raw;
        }

        self.state = raw;

        return raw;
    }

    /// True when a fault has been reported continuously for `seconds`.
    pub fn faultDurationSeconds(self: *const Tracker, state: State, now_ms: i64) i64 {
        if (state != self.fault_state or self.last_fault_ms < 0) return 0;

        return @divTrunc(now_ms - self.last_fault_ms, 1000);
    }
};

/// The line the miner logs and `oneclick.sh status` reads. One key per line so
/// a person and a script can both read it, and no ANSI colour.
pub fn describe(buf: []u8, state: State, snapshot: Snapshot) []const u8 {
    return std.fmt.bufPrint(buf, "health: {s} rate 60s {d:.1} H/s peak {d:.1} H/s accepted {d} rejected {d} submitted {d}", .{
        state.label(),
        snapshot.rate_60s,
        snapshot.peak,
        snapshot.accepted,
        snapshot.rejected,
        snapshot.submitted,
    }) catch "health: unknown";
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn base() Snapshot {
    return .{
        .uptime_s = 600,
        .rate_10s = 1000,
        .rate_60s = 1000,
        .peak = 1000,
        .hashes = 600_000,
        .accepted = 12,
        .rejected = 0,
        .submitted = 12,
    };
}

test "a healthy miner is ok, and a young one is never judged" {
    const testing = std.testing;

    try testing.expectEqual(State.ok, evaluate(base(), .{}));

    var young = base();
    young.uptime_s = 30;
    try testing.expectEqual(State.warming, evaluate(young, .{}));

    var empty = base();
    empty.hashes = 0;
    empty.rate_10s = 0;
    empty.rate_60s = 0;
    try testing.expectEqual(State.warming, evaluate(empty, .{}));
}

test "a user pause is not a fault" {
    const testing = std.testing;

    // pause-on-battery is a feature; reporting it as a stall would train the
    // user to ignore the alarm.
    var paused = base();
    paused.paused = true;
    paused.rate_10s = 0;
    paused.rate_60s = 0;
    paused.hashes = 0;

    try testing.expectEqual(State.warming, evaluate(paused, .{}));
    try testing.expect(!evaluate(paused, .{}).isFault());
}

test "zero hashrate on a live process is a stall" {
    const testing = std.testing;

    var stalled = base();
    stalled.rate_10s = 0;
    try testing.expectEqual(State.stalled, evaluate(stalled, .{}));
    try testing.expect(evaluate(stalled, .{}).isFault());
}

test "a pool that rejects everything is a fault even at full hashrate" {
    const testing = std.testing;

    var rejecting = base();
    rejecting.accepted = 0;
    rejecting.rejected = 10;
    rejecting.submitted = 10;
    rejecting.rate_60s = 1000;

    try testing.expectEqual(State.rejected, evaluate(rejecting, .{}));
    try testing.expect(evaluate(rejecting, .{}).isFault());

    // A couple of stale shares is normal and must not raise anything.
    var few = base();
    few.rejected = 3;
    try testing.expectEqual(State.ok, evaluate(few, .{}));
}

test "degraded needs a reference rate and a real drop" {
    const testing = std.testing;

    var slow = base();
    slow.rate_60s = 700; // 70 % of peak, below the 80 % threshold
    try testing.expectEqual(State.degraded, evaluate(slow, .{}));
    try testing.expect(!evaluate(slow, .{}).isFault());

    // 85 % of peak is a normal fluctuation on a shared host.
    var fine = base();
    fine.rate_60s = 850;
    try testing.expectEqual(State.ok, evaluate(fine, .{}));

    // No peak yet (first minute): a low rate cannot be "degraded".
    var early = base();
    early.peak = 0;
    early.rate_60s = 100;
    try testing.expectEqual(State.ok, evaluate(early, .{}));
}

test "a dip must persist before it is reported as degraded" {
    const testing = std.testing;

    var tracker = Tracker{};
    var slow = base();
    slow.rate_60s = 500;

    // The first ten seconds of a dip: still ok.
    try testing.expectEqual(State.ok, tracker.update(base(), 0));
    try testing.expectEqual(State.ok, tracker.update(slow, 5_000));
    try testing.expectEqual(State.ok, tracker.update(slow, 20_000));

    // Past the ten-minute threshold it becomes the reported state.
    try testing.expectEqual(State.degraded, tracker.update(slow, 620_000));
}

test "a stall is reported immediately, a recovery clears it" {
    const testing = std.testing;

    var tracker = Tracker{};
    _ = tracker.update(base(), 0);

    var stalled = base();
    stalled.rate_10s = 0;

    // A stall has no "wait and see": zero hashes for the stall window is
    // already the definition. Before the window it is reported (so the log
    // shows it), after it, it is trusted.
    try testing.expectEqual(State.stalled, tracker.update(stalled, 1_000));
    try testing.expectEqual(State.stalled, tracker.update(stalled, 200_000));

    // Back to normal: the next good sample clears it.
    try testing.expectEqual(State.ok, tracker.update(base(), 201_000));
}

test "a quarantined miner is a fault, even though it is still hashing" {
    const testing = std.testing;

    // Three invalid shares stop submissions for ten minutes. The hashrate is
    // unchanged and only three rejects were counted, so neither of the other
    // rules can see it -- and the rig is earning nothing.
    const snapshot = Snapshot{
        .uptime_s = 600,
        .rate_10s = 800,
        .rate_60s = 800,
        .peak = 800,
        .hashes = 1_000_000,
        .accepted = 0,
        .rejected = 3,
        .submitted = 3,
        .quarantined = true,
    };

    try testing.expectEqual(State.rejected, evaluate(snapshot, .{}));
    try testing.expect(State.rejected.isFault());
}
