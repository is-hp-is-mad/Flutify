/// The Web token endpoint rejected a request. A 403 alone does not establish
/// that the user's login expired; do not include its response body in logs.
class WebTokenHttpException extends StateError {
  WebTokenHttpException(this.statusCode)
    : super('Minting the web token failed: HTTP $statusCode');

  final int statusCode;
}

class WebSignInRequiredException extends StateError {
  WebSignInRequiredException() : super('Missing sp_dc (complete the web login first)');
}
