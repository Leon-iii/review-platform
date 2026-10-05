/// Version 2 separates term-only short answers from written essay answers.
/// Missing versions belong to the old, unrestricted short-answer pipeline.
abstract final class QuestionAnswerFormat {
  static const version = 2;
  static String syncedType(Map<String, Object?> payload) =>
      payload['type'] == 'shortAnswer' &&
          !(payload['answerFormatVersion'] is num &&
              (payload['answerFormatVersion'] as num) >= version)
      ? 'essay'
      : payload['type']! as String;

  static Map<String, Object?> pendingSnapshot(Map<String, Object?> snapshot) =>
      {
        ...snapshot,
        'type': syncedType(snapshot),
        'answerFormatVersion': version,
      };
}
