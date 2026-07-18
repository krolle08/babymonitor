/// Connection health states (spec.md F3).
///
/// [connecting] is the initial state before the first heartbeat arrives;
/// the five operational states are exactly the spec's FSM.
enum HealthState {
  connecting,
  connected,
  degraded,
  reconnecting,
  frozen,
  failed,
}
