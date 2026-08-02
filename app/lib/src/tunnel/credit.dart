import 'dart:async';
import 'dart:collection';

/// An async counting semaphore used for per-stream send flow control: a sender
/// must acquire N permits (bytes of window) before putting N bytes on the wire,
/// and the peer's WindowUpdate frames [release] them back.
class Credit {
  int _permits;
  bool _closed = false;
  final Queue<_Waiter> _waiters = Queue();

  Credit(this._permits);

  Future<void> acquire(int n) {
    if (_closed) return Future.error(StateError('stream closed'));
    if (_waiters.isEmpty && _permits >= n) {
      _permits -= n;
      return Future.value();
    }
    final w = _Waiter(n);
    _waiters.add(w);
    return w.completer.future;
  }

  void release(int n) {
    if (_closed) return;
    _permits += n;
    while (_waiters.isNotEmpty && _permits >= _waiters.first.n) {
      final w = _waiters.removeFirst();
      _permits -= w.n;
      w.completer.complete();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completer.completeError(StateError('stream closed'));
    }
  }
}

class _Waiter {
  final int n;
  final Completer<void> completer = Completer<void>();
  _Waiter(this.n);
}
