import 'dart:convert';

enum HistoryType { url, snippet }

class HistoryItem {
  final String id;
  final String content;
  final HistoryType type;
  final DateTime timestamp;

  HistoryItem({
    required this.id,
    required this.content,
    required this.type,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory HistoryItem.fromMap(Map<String, dynamic> map) {
    return HistoryItem(
      id: map['id'] ?? '',
      content: map['content'] ?? '',
      type: HistoryType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => HistoryType.url,
      ),
      timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
    );
  }

  String toJson() => json.encode(toMap());

  factory HistoryItem.fromJson(String source) =>
      HistoryItem.fromMap(json.decode(source));
}
