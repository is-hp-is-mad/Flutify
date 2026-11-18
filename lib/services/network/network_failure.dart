import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../audio/audio_engine.dart';
import '../../models/track_playback_exception.dart';

/// Retry connection failures, not every error classified as a playback error.
bool isConnectionFailure(Object? error) {
  if (error is TrackPlaybackException) {
    return error.kind == TrackPlaybackFailure.network &&
        isConnectionFailure(error.cause);
  }
  if (error is EmePlaybackException) {
    if (error.isWidevineMissing || error.webSignInSuggested) return false;
    return isConnectionFailure(error.cause) ||
        _connectionMessage(error.message);
  }
  if (error is SocketException || error is TimeoutException) return true;
  // IOClient preserves SocketException on native platforms. Other adapters and
  // native media engines sometimes only preserve the error message.
  if (error is http.ClientException) return _connectionMessage(error.message);
  return false;
}

bool _connectionMessage(String message) {
  final text = message.toLowerCase();
  return const [
    'socketexception',
    'failed host lookup',
    'network is unreachable',
    'network unreachable',
    'no route to host',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection timed out',
    'connection timeout',
    'err_internet_disconnected',
    'err_network_changed',
    'err_name_not_resolved',
    'unknownhostexception',
    'sockettimeoutexception',
    'connectexception',
  ].any(text.contains);
}
