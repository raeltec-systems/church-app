// Non-web builds have no browser storage (secure storage is used instead).
String? readItem(String key) => null;

void writeItem(String key, String value) {}

void deleteItem(String key) {}
