/// A sink for human-readable diagnostic lines, surfaced in the app's Logs view.
typedef LogSink = void Function(String message);

/// A no-op sink for contexts that don't care about logs.
void discardLog(String _) {}
