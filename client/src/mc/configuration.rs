//! Configuration state (introduced in protocol 764 / Minecraft 1.20.2).
//!
//! This transport currently targets protocol 763 (1.20.1), which has no
//! Configuration state on the wire: `Login Success` transitions the
//! connection directly to Play. This module exists so `session.rs` has a
//! stable phase to call between login and play regardless of protocol
//! version, so that supporting 764+ later only means filling this in rather
//! than reshaping the session state machine. For 763 there is nothing to do.

/// Runs the Configuration phase for the active protocol version.
///
/// No-op on protocol 763.
pub async fn run() {}
