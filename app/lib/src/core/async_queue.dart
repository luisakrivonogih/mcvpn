import 'dart:async';
import 'dart:collection';

/// A single-consumer async FIFO. Producers [add]; the consumer awaits [next],
/// which yields items in order and returns null once [close]d and drained.
class AsyncQueue<T> {
  final Queue<T> _items = Queue<T>();
  Completer<T?>? _waiter;
  bool _closed = false;

  void add(T item) {
    if (_closed) return;
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete(item);
    } else {
      _items.add(item);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete(null);
    }
  }

  bool get isClosed => _closed;

  Future<T?> next() {
    if (_items.isNotEmpty) return Future.value(_items.removeFirst());
    if (_closed) return Future.value(null);
    final c = Completer<T?>();
    _waiter = c;
    return c.future;
  }
}
