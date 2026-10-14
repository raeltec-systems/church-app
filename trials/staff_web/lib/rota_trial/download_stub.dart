// Disposable Flutter Web trial (Q10). Do not build on this.

/// Non-web fallback: there is no browser to save a file in, so report failure
/// and let the caller show an honest error.
bool downloadTextFile(String filename, String content, String mimeType) =>
    false;
