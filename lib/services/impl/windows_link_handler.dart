import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../link_handler_service.dart';
import 'link_handler_service.dart';

/// Windows: the shell's association for the complete web URL or scheme,
/// honoring the user's choice in Settings > Default apps.
///
/// Two kinds of handler come back, and their icons are found differently:
///
/// - A desktop app (Chrome, Firefox, Thunderbird) names an icon inside its
///   executable, `C:\...\chrome.exe,0`. That is extracted at 64px and its
///   pixels read out of the bitmap.
/// - A packaged app (Outlook, Maps, Phone Link) names an indirect resource,
///   `@{Package?ms-resource://...}`, which SHLoadIndirectString resolves to a
///   PNG logo inside the package's install folder. That file is read as is.
///
/// Pure FFI over shlwapi, shell32, user32 and gdi32, in the same style as
/// PackagedAppData's lookup, rather than a method channel in the C++ runner.
/// It runs in a background isolate: a packaged app's resource lookup, the icon
/// extraction and the PNG encode would otherwise land in the frame Spotlight
/// opens in.
class WindowsLinkHandlerService extends CachingLinkHandlerService {
  WindowsLinkHandlerService() : super(platform: 'windows');

  /// Apps for Websites can route different web URLs to different apps.
  @override
  String cacheKeyFor(Uri uri) => uri.isScheme('https') || uri.isScheme('http')
      ? uri.toString()
      : uri.scheme;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    final found = await compute(_handlerForUri, uri.toString());
    if (found == null) return null;
    final (:name, :png, :pngFile) = found;
    return LinkHandler(
      name: name,
      icon: png != null
          ? MemoryImage(png)
          : pngFile != null
          ? FileImage(File(pngFile))
          : null,
    );
  }
}

typedef _FoundHandler = ({String name, Uint8List? png, String? pngFile});
typedef _FoundIcon = ({Uint8List? png, String? pngFile});

/// The whole lookup, on whichever isolate runs it: only plain data comes
/// back, and the ImageProvider is made on the caller's.
///
/// SHLoadIndirectString needs COM on the calling thread to resolve a
/// packaged app's ms-resource reference, and the isolate's thread is one
/// nothing else has put in COM. The VM reuses those threads, so every
/// successful CoInitializeEx - S_FALSE, already initialised, included - is
/// balanced before returning. RPC_E_CHANGED_MODE (negative) is a thread
/// someone else initialised differently, and is not ours to undo.
_FoundHandler? _handlerForUri(String url) {
  final uri = Uri.parse(url);
  final web = uri.isScheme('https') || uri.isScheme('http');
  var association = web ? url : uri.scheme;
  var flags =
      _assocfInitIgnoreUnknown |
      (web ? _assocfIsFullUri | _assocfAppToApp : _assocfIsProtocol);
  final com = _coInitializeEx(nullptr, 2); // COINIT_APARTMENTTHREADED
  try {
    var name = _resolveIndirect(
      _assocQuery(association, _assocStrFriendlyAppName, flags),
    );
    // FULL_URI reports no association when no Apps for Websites rule takes
    // the URL. ShellExecute then uses the ordinary protocol default too.
    if ((name == null || name.isEmpty) && web) {
      association = uri.scheme;
      flags = _assocfInitIgnoreUnknown | _assocfIsProtocol;
      name = _resolveIndirect(
        _assocQuery(association, _assocStrFriendlyAppName, flags),
      );
    }
    if (name == null || name.isEmpty) return null;
    final icon =
        _iconFromReference(
          _assocQuery(association, _assocStrAppIconReference, flags),
        ) ??
        _iconFromReference(
          _assocQuery(association, _assocStrDefaultIcon, flags),
        );
    return (name: name, png: icon?.png, pngFile: icon?.pngFile);
  } finally {
    if (com >= 0) _coUninitialize();
  }
}

final _ole32 = DynamicLibrary.open('ole32.dll');

final _coInitializeEx = _ole32
    .lookupFunction<
      Int32 Function(Pointer<Void> reserved, Uint32 model),
      int Function(Pointer<Void> reserved, int model)
    >('CoInitializeEx');

final _coUninitialize = _ole32.lookupFunction<Void Function(), void Function()>(
  'CoUninitialize',
);

// AssocQueryStringW.
const _assocfIsProtocol = 0x1000;
const _assocfIsFullUri = 0x4000;
const _assocfAppToApp = 0x10000;
const _assocfInitIgnoreUnknown = 0x400;
const _assocStrFriendlyAppName = 4;
const _assocStrDefaultIcon = 15;
const _assocStrAppIconReference = 23;

const _iconPixels = 64;

final _shlwapi = DynamicLibrary.open('shlwapi.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _user32 = DynamicLibrary.open('user32.dll');
final _gdi32 = DynamicLibrary.open('gdi32.dll');

final _assocQueryString = _shlwapi
    .lookupFunction<
      Int32 Function(
        Uint32 flags,
        Int32 str,
        Pointer<Utf16> assoc,
        Pointer<Utf16> extra,
        Pointer<Utf16> out,
        Pointer<Uint32> outChars,
      ),
      int Function(
        int flags,
        int str,
        Pointer<Utf16> assoc,
        Pointer<Utf16> extra,
        Pointer<Utf16> out,
        Pointer<Uint32> outChars,
      )
    >('AssocQueryStringW');

final _shLoadIndirectString = _shlwapi
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16> source,
        Pointer<Utf16> out,
        Uint32 outChars,
        Pointer<Pointer<Void>> reserved,
      ),
      int Function(
        Pointer<Utf16> source,
        Pointer<Utf16> out,
        int outChars,
        Pointer<Pointer<Void>> reserved,
      )
    >('SHLoadIndirectString');

final _shDefExtractIcon = _shell32
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16> file,
        Int32 index,
        Uint32 flags,
        Pointer<IntPtr> large,
        Pointer<IntPtr> small,
        Uint32 sizes,
      ),
      int Function(
        Pointer<Utf16> file,
        int index,
        int flags,
        Pointer<IntPtr> large,
        Pointer<IntPtr> small,
        int sizes,
      )
    >('SHDefExtractIconW');

final _getIconInfo = _user32
    .lookupFunction<
      Int32 Function(IntPtr icon, Pointer<_IconInfo> info),
      int Function(int icon, Pointer<_IconInfo> info)
    >('GetIconInfo');

final _destroyIcon = _user32
    .lookupFunction<Int32 Function(IntPtr icon), int Function(int icon)>(
      'DestroyIcon',
    );

final _getDC = _user32
    .lookupFunction<IntPtr Function(IntPtr window), int Function(int window)>(
      'GetDC',
    );

final _releaseDC = _user32
    .lookupFunction<
      Int32 Function(IntPtr window, IntPtr dc),
      int Function(int window, int dc)
    >('ReleaseDC');

final _getObject = _gdi32
    .lookupFunction<
      Int32 Function(IntPtr object, Int32 size, Pointer<Void> out),
      int Function(int object, int size, Pointer<Void> out)
    >('GetObjectW');

final _getDIBits = _gdi32
    .lookupFunction<
      Int32 Function(
        IntPtr dc,
        IntPtr bitmap,
        Uint32 start,
        Uint32 lines,
        Pointer<Void> bits,
        Pointer<Void> info,
        Uint32 usage,
      ),
      int Function(
        int dc,
        int bitmap,
        int start,
        int lines,
        Pointer<Void> bits,
        Pointer<Void> info,
        int usage,
      )
    >('GetDIBits');

final _deleteObject = _gdi32
    .lookupFunction<Int32 Function(IntPtr object), int Function(int object)>(
      'DeleteObject',
    );

final class _IconInfo extends Struct {
  @Int32()
  external int fIcon;
  @Uint32()
  external int xHotspot;
  @Uint32()
  external int yHotspot;
  @IntPtr()
  external int hbmMask;
  @IntPtr()
  external int hbmColor;
}

final class _Bitmap extends Struct {
  @Int32()
  external int bmType;
  @Int32()
  external int bmWidth;
  @Int32()
  external int bmHeight;
  @Int32()
  external int bmWidthBytes;
  @Uint16()
  external int bmPlanes;
  @Uint16()
  external int bmBitsPixel;
  external Pointer<Void> bmBits;
}

final class _BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

/// One association string for a full web URL or protocol.
String? _assocQuery(String association, int what, int flags) => using((arena) {
  const capacity = 1024;
  final out = arena<Uint16>(capacity).cast<Utf16>();
  final chars = arena<Uint32>()..value = capacity;
  final status = _assocQueryString(
    flags,
    what,
    association.toNativeUtf16(allocator: arena),
    nullptr,
    out,
    chars,
  );
  if (status != 0) return null;
  final value = out.toDartString();
  return value.isEmpty ? null : value;
});

/// `@{Package?ms-resource://...}` and `@file.dll,-123` resolved to the text
/// or file path they stand for. Anything not starting with `@` is returned
/// as it is.
String? _resolveIndirect(String? value) {
  if (value == null || !value.startsWith('@')) return value;
  return using((arena) {
    const capacity = 1024;
    final out = arena<Uint16>(capacity).cast<Utf16>();
    final status = _shLoadIndirectString(
      value.toNativeUtf16(allocator: arena),
      out,
      capacity,
      nullptr,
    );
    if (status != 0) return null;
    final resolved = out.toDartString();
    return resolved.isEmpty ? null : resolved;
  });
}

/// An icon reference - `path,index`, a bare path, or an indirect string that
/// resolves to a PNG - as PNG bytes or the PNG file.
_FoundIcon? _iconFromReference(String? reference) {
  if (reference == null) return null;
  if (reference.startsWith('@')) {
    final file = _resolveIndirect(reference);
    if (file == null || !file.toLowerCase().endsWith('.png')) return null;
    return (png: null, pngFile: file);
  }
  // "C:\Program Files\App\app.exe",0 - quotes optional, index optional.
  var location = reference;
  var index = 0;
  final comma = reference.lastIndexOf(',');
  if (comma > 0) {
    final parsed = int.tryParse(reference.substring(comma + 1).trim());
    if (parsed != null) {
      index = parsed;
      location = reference.substring(0, comma);
    }
  }
  location = location.trim().replaceAll('"', '');
  if (location.isEmpty) return null;
  final png = _extractIconPng(location, index);
  return png == null ? null : (png: png, pngFile: null);
}

/// The icon at [index] in [file], at 64px, as PNG bytes.
Uint8List? _extractIconPng(String file, int index) => using((arena) {
  final large = arena<IntPtr>();
  // LOWORD is the large size asked for, HIWORD the small one.
  final status = _shDefExtractIcon(
    file.toNativeUtf16(allocator: arena),
    index,
    0,
    large,
    nullptr,
    _iconPixels,
  );
  if (status != 0 || large.value == 0) return null;
  final icon = large.value;
  try {
    return _iconToPng(icon, arena);
  } finally {
    _destroyIcon(icon);
  }
});

Uint8List? _iconToPng(int icon, Arena arena) {
  final info = arena<_IconInfo>();
  if (_getIconInfo(icon, info) == 0) return null;
  final color = info.ref.hbmColor;
  final mask = info.ref.hbmMask;
  try {
    // A monochrome icon has no colour bitmap; nothing worth showing.
    if (color == 0) return null;
    final bitmap = arena<_Bitmap>();
    if (_getObject(color, sizeOf<_Bitmap>(), bitmap.cast()) == 0) return null;
    final width = bitmap.ref.bmWidth;
    final height = bitmap.ref.bmHeight;
    // Asked for at 64px; anything far off that is not a bitmap to allocate
    // for. Malformed native data is null here, not an Error further on.
    if (width <= 0 || height <= 0 || width > 1024 || height > 1024) {
      return null;
    }

    // BITMAPINFO is the header plus a colour table GetDIBits leaves unused at
    // 32bpp; the spare bytes are room for it all the same.
    final header = arena<Uint8>(
      sizeOf<_BitmapInfoHeader>() + 16,
    ).cast<_BitmapInfoHeader>();
    header.ref
      ..biSize = sizeOf<_BitmapInfoHeader>()
      ..biWidth = width
      // Negative: rows top-down, the order the image package expects.
      ..biHeight = -height
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = 0; // BI_RGB
    final byteCount = width * height * 4;
    final pixels = arena<Uint8>(byteCount);

    final dc = _getDC(0);
    final lines = _getDIBits(
      dc,
      color,
      0,
      height,
      pixels.cast(),
      header.cast(),
      0,
    );
    _releaseDC(0, dc);
    if (lines == 0) return null;

    final bgra = Uint8List.fromList(pixels.asTypedList(byteCount));
    Uint8List? andMask;
    if (!_hasAlpha(bgra)) {
      final maskBitmap = arena<_Bitmap>();
      if (mask == 0 ||
          _getObject(mask, sizeOf<_Bitmap>(), maskBitmap.cast()) == 0 ||
          maskBitmap.ref.bmWidth != width ||
          maskBitmap.ref.bmHeight != height) {
        return null;
      }
      // A one-bit AND mask is MSB-first, with DWORD-aligned scanlines.
      final stride = ((width + 31) ~/ 32) * 4;
      final maskHeader = arena<Uint8>(
        sizeOf<_BitmapInfoHeader>() + 8,
      ).cast<_BitmapInfoHeader>();
      maskHeader.ref
        ..biSize = sizeOf<_BitmapInfoHeader>()
        ..biWidth = width
        ..biHeight = -height
        ..biPlanes = 1
        ..biBitCount = 1
        ..biCompression = 0
        ..biClrUsed = 2;
      final maskPixels = arena<Uint8>(stride * height);
      final maskDc = _getDC(0);
      if (maskDc == 0) return null;
      try {
        if (_getDIBits(
              maskDc,
              mask,
              0,
              height,
              maskPixels.cast(),
              maskHeader.cast(),
              0,
            ) !=
            height) {
          return null;
        }
      } finally {
        _releaseDC(0, maskDc);
      }
      andMask = Uint8List.fromList(maskPixels.asTypedList(stride * height));
    }
    if (!restoreWindowsIconAlpha(
      bgra,
      width: width,
      height: height,
      andMask: andMask,
    )) {
      return null;
    }
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgra.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    return img.encodePng(image);
  } finally {
    _deleteObject(color);
    _deleteObject(mask);
  }
}

bool _hasAlpha(Uint8List pixels) {
  for (var i = 3; i < pixels.length; i += 4) {
    if (pixels[i] != 0) return true;
  }
  return false;
}

/// Restores legacy HICON transparency from a top-down one-bit [andMask].
/// Existing alpha in [bgra] takes precedence over the mask. Invalid bitmap
/// sizes or an absent legacy mask return false instead of guessing opacity.
@visibleForTesting
bool restoreWindowsIconAlpha(
  Uint8List bgra, {
  required int width,
  required int height,
  Uint8List? andMask,
}) {
  if (width <= 0 ||
      height <= 0 ||
      width > 1024 ||
      height > 1024 ||
      bgra.length != width * height * 4) {
    return false;
  }
  if (_hasAlpha(bgra)) return true;
  final stride = ((width + 31) ~/ 32) * 4;
  if (andMask == null || andMask.length != stride * height) return false;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final transparent = andMask[y * stride + x ~/ 8] & (0x80 >> (x % 8)) != 0;
      bgra[(y * width + x) * 4 + 3] = transparent ? 0 : 255;
    }
  }
  return true;
}
