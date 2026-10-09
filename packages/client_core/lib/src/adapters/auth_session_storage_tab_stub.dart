// Non-web builds have no browser tab: nothing is stored here (the mobile
// store is used instead).
String? readTabSession(String key) => null;

void writeTabSession(String key, String value) {}

void deleteTabSession(String key) {}
