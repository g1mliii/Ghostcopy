import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../link_handler_service.dart';
import 'link_handler_service.dart';

/// Windows: the shell's association for the link's scheme, which honours the
/// user's choice in Settings > Default apps.
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

  /// The shell associates a whole scheme with one app.
  @override
  String cacheKeyFor(Uri uri) => uri.scheme;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    final found = await compute(_handlerForScheme, uri.scheme);
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
_FoundHandler? _handlerForScheme(String scheme) {
  _ensureCom();
  final name = _resolveIndirect(_assocQuery(scheme, _assocStrFriendlyAppName));
  if (name == null || name.isEmpty) return null;
  final icon =
      _iconFromReference(_assocQuery(scheme, _assocStrAppIconReference)) ??
      _iconFromReference(_assocQuery(scheme, _assocStrDefaultIcon));
  return (name: name, png: icon?.png, pngFile: icon?.pngFile);
}

/// SHLoadIndirectString needs COM on the calling thread to resolve a
/// packaged app's ms-resource reference, and the lookup runs on a background
/// isolate's thread, which nothing else has put in COM. Per isolate, as
/// globals are. A thread already in COM answers a harmless S_FALSE or
/// RPC_E_CHANGED_MODE.
bool _comReady = false;
void _ensureCom() {
  if (_comReady) return;
  _comReady = true;
  _coInitializeEx(nullptr, 2); // COINIT_APARTMENTTHREADED
}

final _coInitializeEx = DynamicLibrary.open('ole32.dll')
    .lookupFunction<
      Int32 Function(Pointer<Void> reserved, Uint32 model),
      int Function(Pointer<Void> reserved, int model)
    >('CoInitializeEx');

// AssocQueryStringW.
const _assocfIsProtocol = 0x1000;
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

/// One association string for a URL scheme, or null if there is none.
String? _assocQuery(String scheme, int what) => using((arena) {
  const capacity = 1024;
  final out = arena<Uint16>(capacity).cast<Utf16>();
  final chars = arena<Uint32>()..value = capacity;
  final status = _assocQueryString(
    _assocfIsProtocol | _assocfInitIgnoreUnknown,
    what,
    scheme.toNativeUtf16(allocator: arena),
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
    if (width <= 0 || height <= 0) return null;

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
    // Older icons keep transparency in the mask and leave alpha at zero, which
    // would draw nothing at all. Opaque is closer to right than invisible.
    var anyAlpha = false;
    for (var i = 3; i < bgra.length; i += 4) {
      if (bgra[i] != 0) {
        anyAlpha = true;
        break;
      }
    }
    if (!anyAlpha) {
      for (var i = 3; i < bgra.length; i += 4) {
        bgra[i] = 255;
      }
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
