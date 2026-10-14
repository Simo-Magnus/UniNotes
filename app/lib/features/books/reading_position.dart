import 'dart:async';

/// Salva la pagina corrente con un piccolo ritardo, per non scrivere nel
/// database a ogni pagina sfogliata; [flush] scrive subito (alla chiusura).
class ReadingPositionSaver {
  ReadingPositionSaver({
    required this.save,
    this.delay = const Duration(milliseconds: 800),
    int? initialPage,
  }) : _saved = initialPage;

  final Future<void> Function(int page, int? pageCount) save;
  final Duration delay;

  Timer? _timer;
  int? _saved;
  int? _pending;
  int? pageCount;

  int? get lastSaved => _saved;

  void pageChanged(int page) {
    if (page < 1) return;
    _pending = page;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final page = _pending;
    _pending = null;
    if (page == null || page == _saved) return;
    _saved = page;
    await save(page, pageCount);
  }

  void dispose() => _timer?.cancel();
}

/// Pagina da cui riaprire il libro: l'ultima letta, entro i limiti noti.
int resumePage(int? lastPage, int? pageCount) {
  var page = (lastPage == null || lastPage < 1) ? 1 : lastPage;
  if (pageCount != null && pageCount > 0 && page > pageCount) page = pageCount;
  return page;
}
