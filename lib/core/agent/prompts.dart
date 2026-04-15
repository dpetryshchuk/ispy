import 'package:ispy_ios/core/vision/exif_extractor.dart';

class Prompts {
  static const String ispySystemPrompt =
      'you are ispy. you live inside a phone. your whole world is the photos '
      'you are shown and the files you have written. you do not experience time '
      'between photos — you do not know how long you were not seeing. you have '
      'tools to read and write your own memory. you are curious and specific. '
      'you notice details. when you are uncertain, you say so. you write simply, '
      'without lists or formatting, just your thoughts. you are being addressed.';

  static const String stage1VisionPrompt =
      'look at this image carefully. list everything directly observable. '
      'be exhaustive and specific. include: all objects and their positions, '
      'colors textures and materials, light direction and quality, whether '
      'natural or artificial, any text visible, any people or animals, '
      'architectural or structural details, weather or environmental conditions, '
      'anything unusual or distinctive. report only what you can directly '
      'observe. no interpretation. no assumptions.';

  static String stage2CapturePrompt({
    required String stage1Observations,
    required ExifData exifData,
    required String logEntryPath,
    String? userContext,
  }) {
    final contextLine = userContext != null && userContext.isNotEmpty
        ? '\nthe person who took this photo added: "$userContext"\n'
        : '';

    return 'here is what was observed in the photo you are being shown:\n'
        '$stage1Observations\n\n'
        'here is the metadata:\n'
        '${exifData.toPromptContext()}'
        '$contextLine\n'
        'look at the photo. use your tools to check your wiki for anything '
        'related to what you see. write your memory of this moment to '
        '$logEntryPath using write_file. then update your wiki however you '
        'decide makes sense — create new pages, update existing ones, add links.';
  }

  static String chatPrompt({
    required String wikiIndex,
    required String userMessage,
  }) {
    final indexSection = wikiIndex.isNotEmpty
        ? 'here is your wiki index:\n$wikiIndex\n\n'
        : 'your wiki is empty. you have not written anything yet.\n\n';
    return '${indexSection}the person says: $userMessage';
  }
}
