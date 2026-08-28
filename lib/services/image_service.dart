import 'package:flutter/foundation.dart';
// ↓ Webでエラーを出さないための条件付きインポート（重要！）
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

class ImageService {
  static Future<Uint8List> compressImage(Uint8List data, {int maxBytes = 200 * 1024}) async {
    
    // 1. Webの場合の処理（Dart製ライブラリのみ使用）
    if (kIsWeb) {
      return _compressWeb(data, maxBytes);
    }

    // 2. モバイル（Android/iOS）の場合の処理
    return _compressMobile(data, maxBytes);
  }

  static Future<Uint8List> _compressWeb(Uint8List data, int maxBytes) async {
    final decoded = img.decodeImage(data);
    if (decoded == null) return data;

    // Webは計算コストを抑えるため、まずはリサイズ
    var resized = img.copyResize(decoded, width: 1024);
    var result = Uint8List.fromList(img.encodeJpg(resized, quality: 75));

    if (result.lengthInBytes > maxBytes) {
      result = Uint8List.fromList(img.encodeJpg(resized, quality: 50));
    }
    return result;
  }

  static Future<Uint8List> _compressMobile(Uint8List data, int maxBytes) async {
    try {
      // ネイティブ機能（flutter_image_compress）を使用
      var result = await FlutterImageCompress.compressWithList(
        data,
        minWidth: 1024,
        quality: 75,
        format: CompressFormat.jpeg,
      );

      if (result.lengthInBytes > maxBytes) {
        result = await FlutterImageCompress.compressWithList(
          data,
          minWidth: 800,
          quality: 60,
          format: CompressFormat.jpeg,
        );
      }
      return result;
    } catch (e) {
      // 万が一モバイルで失敗した場合はWeb用ロジックを流用
      return _compressWeb(data, maxBytes);
    }
  }
}