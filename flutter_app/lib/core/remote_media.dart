import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Unified Plan may deliver audio/video in separate streams, or no stream at all.
/// Own only the aggregate stream; the peer connection owns its remote tracks.
class RemoteMedia {
  RemoteMedia({Future<MediaStream> Function()? create})
      : _create = create ?? (() => createLocalMediaStream('remote'));
  final Future<MediaStream> Function() _create;
  MediaStream? stream;
  Future<void> _work = Future.value();
  bool _closed = false;
  bool get hasVideo => stream?.getVideoTracks().isNotEmpty ?? false;

  Future<void> add(MediaStreamTrack track, void Function(MediaStream) changed) {
    _work = _work.catchError((_) {}).then((_) async {
      if (_closed) return;
      final target = stream ??= await _create();
      if (_closed) return;
      if (!target.getTracks().any((t) => t.id == track.id)) {
        await target.addTrack(track);
      }
      if (!_closed) changed(target); // rebind when video arrives after audio
    });
    return _work;
  }

  Future<void> dispose() async {
    _closed = true;
    await _work.catchError((_) {});
    await stream?.dispose();
    stream = null;
  }
}
