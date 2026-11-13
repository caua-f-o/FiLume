import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'editor.dart';
import 'ffmpeg.dart' show FfError;

/// Ponte com o PDFium (o motor de PDF do Chrome), que roda dentro do próprio
/// app: nada sai do computador. É ele que abre o arquivo, desenha as páginas e
/// grava as alterações do editor.

typedef _H = Pointer<Void>;

final class _FsMatrix extends Struct {
  @Float()
  external double a;
  @Float()
  external double b;
  @Float()
  external double c;
  @Float()
  external double d;
  @Float()
  external double e;
  @Float()
  external double f;
}

typedef _WriteBlockC = Int32 Function(Pointer<_FileWrite>, Pointer<Void>, UnsignedLong);

final class _FileWrite extends Struct {
  @Int32()
  external int version;
  external Pointer<NativeFunction<_WriteBlockC>> writeBlock;
}

RandomAccessFile? _saveTarget;

/// Chamado pelo PDFium a cada bloco do arquivo que está sendo gravado.
int _writeBlock(Pointer<_FileWrite> self, Pointer<Void> data, int size) {
  final f = _saveTarget;
  if (f == null) return 0;
  try {
    f.writeFromSync(data.cast<Uint8>().asTypedList(size));
    return 1;
  } catch (_) {
    return 0;
  }
}

class Pdfium {
  Pdfium._(DynamicLibrary lib)
      : initLibrary = lib.lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary'),
        getLastError = lib.lookupFunction<UnsignedLong Function(), int Function()>('FPDF_GetLastError'),
        loadMemDocument =
            lib.lookupFunction<_H Function(Pointer<Void>, Size, Pointer<Uint8>), _H Function(Pointer<Void>, int, Pointer<Uint8>)>('FPDF_LoadMemDocument64'),
        closeDocument = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDF_CloseDocument'),
        getPageCount = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDF_GetPageCount'),
        loadPage = lib.lookupFunction<_H Function(_H, Int32), _H Function(_H, int)>('FPDF_LoadPage'),
        closePage = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDF_ClosePage'),
        pageWidth = lib.lookupFunction<Float Function(_H), double Function(_H)>('FPDF_GetPageWidthF'),
        pageHeight = lib.lookupFunction<Float Function(_H), double Function(_H)>('FPDF_GetPageHeightF'),
        pageToDevice = lib.lookupFunction<
            Int32 Function(_H, Int32, Int32, Int32, Int32, Int32, Double, Double, Pointer<Int32>, Pointer<Int32>),
            int Function(_H, int, int, int, int, int, double, double, Pointer<Int32>, Pointer<Int32>)>('FPDF_PageToDevice'),
        bitmapCreate =
            lib.lookupFunction<_H Function(Int32, Int32, Int32, Pointer<Void>, Int32), _H Function(int, int, int, Pointer<Void>, int)>('FPDFBitmap_CreateEx'),
        bitmapFill = lib.lookupFunction<Int32 Function(_H, Int32, Int32, Int32, Int32, UnsignedLong), int Function(_H, int, int, int, int, int)>(
            'FPDFBitmap_FillRect'),
        bitmapBuffer = lib.lookupFunction<Pointer<Void> Function(_H), Pointer<Void> Function(_H)>('FPDFBitmap_GetBuffer'),
        bitmapStride = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFBitmap_GetStride'),
        bitmapDestroy = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDFBitmap_Destroy'),
        renderPage = lib.lookupFunction<Void Function(_H, _H, Int32, Int32, Int32, Int32, Int32, Int32),
            void Function(_H, _H, int, int, int, int, int, int)>('FPDF_RenderPageBitmap'),
        countObjects = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPage_CountObjects'),
        getObject = lib.lookupFunction<_H Function(_H, Int32), _H Function(_H, int)>('FPDFPage_GetObject'),
        objType = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPageObj_GetType'),
        objBounds = lib.lookupFunction<Int32 Function(_H, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>),
            int Function(_H, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>)>('FPDFPageObj_GetBounds'),
        objTransform = lib.lookupFunction<Void Function(_H, Double, Double, Double, Double, Double, Double),
            void Function(_H, double, double, double, double, double, double)>('FPDFPageObj_Transform'),
        objMatrix = lib.lookupFunction<Int32 Function(_H, Pointer<_FsMatrix>), int Function(_H, Pointer<_FsMatrix>)>('FPDFPageObj_GetMatrix'),
        removeObject = lib.lookupFunction<Int32 Function(_H, _H), int Function(_H, _H)>('FPDFPage_RemoveObject'),
        objDestroy = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDFPageObj_Destroy'),
        insertObject = lib.lookupFunction<Void Function(_H, _H), void Function(_H, _H)>('FPDFPage_InsertObject'),
        generateContent = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPage_GenerateContent'),
        textLoadPage = lib.lookupFunction<_H Function(_H), _H Function(_H)>('FPDFText_LoadPage'),
        textClosePage = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDFText_ClosePage'),
        textObjText =
            lib.lookupFunction<UnsignedLong Function(_H, _H, Pointer<Uint16>, UnsignedLong), int Function(_H, _H, Pointer<Uint16>, int)>('FPDFTextObj_GetText'),
        textObjFontSize = lib.lookupFunction<Int32 Function(_H, Pointer<Float>), int Function(_H, Pointer<Float>)>('FPDFTextObj_GetFontSize'),
        textObjFont = lib.lookupFunction<_H Function(_H), _H Function(_H)>('FPDFTextObj_GetFont'),
        fontFlags = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFFont_GetFlags'),
        fontWeight = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFFont_GetWeight'),
        fontEmbedded = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFFont_GetIsEmbedded'),
        fontClose = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDFFont_Close'),
        getFillColor = lib.lookupFunction<Int32 Function(_H, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>),
            int Function(_H, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>)>('FPDFPageObj_GetFillColor'),
        setFillColor = lib.lookupFunction<Int32 Function(_H, Uint32, Uint32, Uint32, Uint32), int Function(_H, int, int, int, int)>('FPDFPageObj_SetFillColor'),
        setStrokeColor =
            lib.lookupFunction<Int32 Function(_H, Uint32, Uint32, Uint32, Uint32), int Function(_H, int, int, int, int)>('FPDFPageObj_SetStrokeColor'),
        setStrokeWidth = lib.lookupFunction<Int32 Function(_H, Float), int Function(_H, double)>('FPDFPageObj_SetStrokeWidth'),
        setLineCap = lib.lookupFunction<Int32 Function(_H, Int32), int Function(_H, int)>('FPDFPageObj_SetLineCap'),
        setLineJoin = lib.lookupFunction<Int32 Function(_H, Int32), int Function(_H, int)>('FPDFPageObj_SetLineJoin'),
        setBlendMode = lib.lookupFunction<Void Function(_H, Pointer<Uint8>), void Function(_H, Pointer<Uint8>)>('FPDFPageObj_SetBlendMode'),
        createTextObj = lib.lookupFunction<_H Function(_H, _H, Float), _H Function(_H, _H, double)>('FPDFPageObj_CreateTextObj'),
        setText = lib.lookupFunction<Int32 Function(_H, Pointer<Uint16>), int Function(_H, Pointer<Uint16>)>('FPDFText_SetText'),
        loadFont = lib.lookupFunction<_H Function(_H, Pointer<Uint8>, Uint32, Int32, Int32), _H Function(_H, Pointer<Uint8>, int, int, int)>(
            'FPDFText_LoadFont'),
        loadStandardFont = lib.lookupFunction<_H Function(_H, Pointer<Uint8>), _H Function(_H, Pointer<Uint8>)>('FPDFText_LoadStandardFont'),
        createPath = lib.lookupFunction<_H Function(Float, Float), _H Function(double, double)>('FPDFPageObj_CreateNewPath'),
        pathMoveTo = lib.lookupFunction<Int32 Function(_H, Float, Float), int Function(_H, double, double)>('FPDFPath_MoveTo'),
        pathLineTo = lib.lookupFunction<Int32 Function(_H, Float, Float), int Function(_H, double, double)>('FPDFPath_LineTo'),
        pathBezierTo = lib.lookupFunction<Int32 Function(_H, Float, Float, Float, Float, Float, Float),
            int Function(_H, double, double, double, double, double, double)>('FPDFPath_BezierTo'),
        pathClose = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPath_Close'),
        pathSetDrawMode = lib.lookupFunction<Int32 Function(_H, Int32, Int32), int Function(_H, int, int)>('FPDFPath_SetDrawMode'),
        newImageObj = lib.lookupFunction<_H Function(_H), _H Function(_H)>('FPDFPageObj_NewImageObj'),
        imageSetBitmap =
            lib.lookupFunction<Int32 Function(Pointer<_H>, Int32, _H, _H), int Function(Pointer<_H>, int, _H, _H)>('FPDFImageObj_SetBitmap'),
        imageSetMatrix = lib.lookupFunction<Int32 Function(_H, Double, Double, Double, Double, Double, Double),
            int Function(_H, double, double, double, double, double, double)>('FPDFImageObj_SetMatrix'),
        saveAsCopy = lib.lookupFunction<Int32 Function(_H, Pointer<_FileWrite>, UnsignedLong), int Function(_H, Pointer<_FileWrite>, int)>('FPDF_SaveAsCopy'),
        // O nome desta função mudou entre versões do PDFium.
        fontName = lib.lookupFunction<Size Function(_H, Pointer<Uint8>, Size), int Function(_H, Pointer<Uint8>, int)>(
            lib.providesSymbol('FPDFFont_GetBaseFontName') ? 'FPDFFont_GetBaseFontName' : 'FPDFFont_GetFamilyName') {
    final crt = Platform.isWindows ? DynamicLibrary.open('msvcrt.dll') : DynamicLibrary.process();
    _malloc = crt.lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>('malloc');
    _free = crt.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
    initLibrary();
  }

  final void Function() initLibrary;
  final int Function() getLastError;
  final _H Function(Pointer<Void>, int, Pointer<Uint8>) loadMemDocument;
  final void Function(_H) closeDocument;
  final int Function(_H) getPageCount;
  final _H Function(_H, int) loadPage;
  final void Function(_H) closePage;
  final double Function(_H) pageWidth, pageHeight;
  final int Function(_H, int, int, int, int, int, double, double, Pointer<Int32>, Pointer<Int32>) pageToDevice;
  final _H Function(int, int, int, Pointer<Void>, int) bitmapCreate;
  final int Function(_H, int, int, int, int, int) bitmapFill;
  final Pointer<Void> Function(_H) bitmapBuffer;
  final int Function(_H) bitmapStride;
  final void Function(_H) bitmapDestroy;
  final void Function(_H, _H, int, int, int, int, int, int) renderPage;
  final int Function(_H) countObjects;
  final _H Function(_H, int) getObject;
  final int Function(_H) objType;
  final int Function(_H, Pointer<Float>, Pointer<Float>, Pointer<Float>, Pointer<Float>) objBounds;
  final void Function(_H, double, double, double, double, double, double) objTransform;
  final int Function(_H, Pointer<_FsMatrix>) objMatrix;
  final int Function(_H, _H) removeObject;
  final void Function(_H) objDestroy;
  final void Function(_H, _H) insertObject;
  final int Function(_H) generateContent;
  final _H Function(_H) textLoadPage;
  final void Function(_H) textClosePage;
  final int Function(_H, _H, Pointer<Uint16>, int) textObjText;
  final int Function(_H, Pointer<Float>) textObjFontSize;
  final _H Function(_H) textObjFont;
  final _H Function(_H, Pointer<Uint8>, int, int, int) loadFont;
  final int Function(_H) fontFlags, fontWeight, fontEmbedded;
  final void Function(_H) fontClose;
  final int Function(_H, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>) getFillColor;
  final int Function(_H, int, int, int, int) setFillColor, setStrokeColor;
  final int Function(_H, double) setStrokeWidth;
  final int Function(_H, int) setLineCap, setLineJoin;
  final void Function(_H, Pointer<Uint8>) setBlendMode;
  final _H Function(_H, _H, double) createTextObj;
  final int Function(_H, Pointer<Uint16>) setText;
  final _H Function(_H, Pointer<Uint8>) loadStandardFont;
  final _H Function(double, double) createPath;
  final int Function(_H, double, double) pathMoveTo, pathLineTo;
  final int Function(_H, double, double, double, double, double, double) pathBezierTo;
  final int Function(_H) pathClose;
  final int Function(_H, int, int) pathSetDrawMode;
  final _H Function(_H) newImageObj;
  final int Function(Pointer<_H>, int, _H, _H) imageSetBitmap;
  final int Function(_H, double, double, double, double, double, double) imageSetMatrix;
  final int Function(_H, Pointer<_FileWrite>, int) saveAsCopy;
  final int Function(_H, Pointer<Uint8>, int) fontName;

  late final Pointer<Void> Function(int) _malloc;
  late final void Function(Pointer<Void>) _free;

  Pointer<T> alloc<T extends NativeType>(int bytes) {
    final ptr = _malloc(bytes < 1 ? 1 : bytes);
    if (ptr == nullptr) throw FfError('Sem memória para abrir o PDF.');
    return ptr.cast<T>();
  }

  void free(Pointer ptr) => _free(ptr.cast());

  /// Texto em ASCII/UTF-8 terminado em zero.
  Pointer<Uint8> cstr(String s) {
    final ptr = alloc<Uint8>(s.length + 1);
    final view = ptr.asTypedList(s.length + 1);
    view.setAll(0, s.codeUnits);
    view[s.length] = 0;
    return ptr;
  }

  /// Texto em UTF-16 terminado em zero.
  Pointer<Uint16> wstr(String s) {
    final ptr = alloc<Uint16>((s.length + 1) * 2);
    final view = ptr.asTypedList(s.length + 1);
    view.setAll(0, s.codeUnits);
    view[s.length] = 0;
    return ptr;
  }

  static Pdfium? _instance;

  /// Por que o PDFium não carregou (para mostrar à pessoa).
  static String? loadError;

  static String? locate() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'pdfium.dll' : (Platform.isMacOS ? 'libpdfium.dylib' : 'libpdfium.so');
    final env = Platform.environment['FILUME_PDFIUM'];
    for (final c in [
      if (env != null && env.isNotEmpty) env,
      p.join(exeDir, name),
      p.join(exeDir, 'lib', name),
      p.join(exeDir, 'pdfium', name),
      p.join('third_party', 'pdfium', 'bin', name),
      p.join('third_party', 'pdfium', 'lib', name),
    ]) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return null;
  }

  static Pdfium? load() {
    if (_instance != null) return _instance;
    final path = locate();
    if (path == null) {
      loadError = 'O componente de edição (PDFium) não foi encontrado na pasta do FiLume.';
      return null;
    }
    try {
      return _instance = Pdfium._(DynamicLibrary.open(path));
    } catch (e) {
      loadError = 'O componente de edição (PDFium) não pôde ser carregado: $e';
      return null;
    }
  }
}

/// Um PDF aberto para edição pelo PDFium.
class PdfiumBackend implements EditBackend {
  PdfiumBackend._(this._pdf, this._doc, this._data);
  final Pdfium _pdf;
  final _H _doc;
  final Pointer<Uint8> _data;
  final Map<int, _H> _pages = {};
  final Map<int, Mat> _p2v = {};
  final Map<String, _H> _fonts = {};
  final Map<String, _H> _sysFonts = {};
  final List<Pointer<Uint8>> _fontData = [];
  final Map<String, double> _widths = {};
  bool _closed = false;

  static PdfiumBackend open(String path, Pdfium pdf) {
    final Uint8List bytes;
    try {
      bytes = File(path).readAsBytesSync();
    } catch (e) {
      throw FfError('Não foi possível ler "${p.basename(path)}".', '$e');
    }
    final data = pdf.alloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final doc = pdf.loadMemDocument(data.cast(), bytes.length, nullptr);
    if (doc == nullptr) {
      final err = pdf.getLastError();
      pdf.free(data);
      throw FfError(err == 4
          ? '"${p.basename(path)}" é protegido por senha. Remova a senha antes de editar (ferramenta Senha).'
          : 'Não foi possível abrir "${p.basename(path)}" para edição.');
    }
    return PdfiumBackend._(pdf, doc, data);
  }

  @override
  int get pageCount => _pdf.getPageCount(_doc);

  _H _page(int i) => _pages[i] ??= () {
        final h = _pdf.loadPage(_doc, i);
        if (h == nullptr) throw FfError('Não foi possível abrir a página ${i + 1}.');
        return h;
      }();

  @override
  (double, double) pageSize(int page) {
    final h = _page(page);
    return (_pdf.pageWidth(h), _pdf.pageHeight(h));
  }

  /// Coordenadas internas da página → coordenadas de tela (pontos, y para baixo).
  Mat _toView(int page) => _p2v[page] ??= () {
        final h = _page(page);
        const s = 100;
        final w = (_pdf.pageWidth(h) * s).round(), ht = (_pdf.pageHeight(h) * s).round();
        final xy = _pdf.alloc<Int32>(8);
        (double, double) dev(double x, double y) {
          _pdf.pageToDevice(h, 0, 0, w, ht, 0, x, y, xy, xy + 1);
          return (xy[0].toDouble(), xy[1].toDouble());
        }

        final o = dev(0, 0), px = dev(1000, 0), py = dev(0, 1000);
        _pdf.free(xy);
        const k = 1000.0 * s;
        return Mat((px.$1 - o.$1) / k, (px.$2 - o.$2) / k, (py.$1 - o.$1) / k, (py.$2 - o.$2) / k, o.$1 / s, o.$2 / s);
      }();

  void _generate(int page) {
    if (_pdf.generateContent(_page(page)) == 0) throw FfError('O PDFium não conseguiu regravar a página ${page + 1}.');
  }

  String _readText(_H obj, _H textPage) {
    final need = _pdf.textObjText(obj, textPage, nullptr, 0);
    if (need <= 2) return '';
    final buf = _pdf.alloc<Uint16>(need + 2);
    final got = _pdf.textObjText(obj, textPage, buf, need);
    final units = buf.asTypedList(got ~/ 2);
    var len = units.length;
    while (len > 0 && units[len - 1] == 0) {
      len--;
    }
    final s = String.fromCharCodes(units.sublist(0, len));
    _pdf.free(buf);
    return s;
  }

  String _fontName(_H font) {
    if (font == nullptr) return '';
    final buf = _pdf.alloc<Uint8>(256);
    final n = _pdf.fontName(font, buf, 256);
    final len = n <= 0 ? 0 : math.min(n, 256) - 1;
    final s = String.fromCharCodes(buf.asTypedList(len < 0 ? 0 : len));
    _pdf.free(buf);
    return s;
  }

  @override
  List<PdfObj> objects(int page) {
    final h = _page(page);
    final m = _toView(page);
    final n = _pdf.countObjects(h);
    final f4 = _pdf.alloc<Float>(16);
    final c4 = _pdf.alloc<Uint32>(16);
    final mat = _pdf.alloc<_FsMatrix>(24);
    final textPage = _pdf.textLoadPage(h);
    final out = <PdfObj>[];
    try {
      for (var i = 0; i < n; i++) {
        final obj = _pdf.getObject(h, i);
        if (obj == nullptr) {
          out.add(PdfObj(index: i, kind: ObjKind.other, l: 0, t: 0, r: 0, b: 0));
          continue;
        }
        final type = _pdf.objType(obj);
        var l = 0.0, t = 0.0, r = 0.0, b = 0.0;
        if (_pdf.objBounds(obj, f4, f4 + 1, f4 + 2, f4 + 3) != 0) {
          // (esquerda, baixo, direita, cima) na página → caixa na tela
          final xs = <double>[], ys = <double>[];
          for (final (x, y) in [(f4[0], f4[1]), (f4[2], f4[1]), (f4[2], f4[3]), (f4[0], f4[3])]) {
            final (vx, vy) = m.apply(x, y);
            xs.add(vx);
            ys.add(vy);
          }
          l = xs.reduce(math.min);
          r = xs.reduce(math.max);
          t = ys.reduce(math.min);
          b = ys.reduce(math.max);
        }
        if (type != 1) {
          out.add(PdfObj(index: i, kind: type == 3 ? ObjKind.image : (type == 2 ? ObjKind.path : ObjKind.other), l: l, t: t, r: r, b: b));
          continue;
        }
        var size = 0.0, baseX = l, baseY = b;
        var upright = true;
        final hasSize = _pdf.textObjFontSize(obj, f4) != 0;
        final fontSize = hasSize ? f4[0] : 0.0;
        if (_pdf.objMatrix(obj, mat) != 0) {
          final om = mat.ref;
          final (ux, uy) = m.vec(om.a, om.b);
          final (vx, vy) = m.vec(om.c, om.d);
          size = fontSize * math.sqrt(vx * vx + vy * vy);
          upright = ux > 0 && uy.abs() <= 0.03 * ux.abs();
          (baseX, baseY) = m.apply(om.e, om.f);
        }
        final font = _pdf.textObjFont(obj);
        final name = _fontName(font);
        final lower = name.toLowerCase();
        final flags = font == nullptr ? 0 : _pdf.fontFlags(font);
        final weight = font == nullptr ? 400 : _pdf.fontWeight(font);
        var color = 0xFF000000;
        if (_pdf.getFillColor(obj, c4, c4 + 1, c4 + 2, c4 + 3) != 0) {
          color = ((c4[3] & 255) << 24) | ((c4[0] & 255) << 16) | ((c4[1] & 255) << 8) | (c4[2] & 255);
        }
        out.add(PdfObj(
          index: i,
          kind: ObjKind.text,
          l: l,
          t: t,
          r: r,
          b: b,
          text: textPage == nullptr ? '' : _readText(obj, textPage),
          size: size,
          baseX: baseX,
          baseY: baseY,
          upright: upright,
          font: name,
          bold: weight >= 600 || flags & 0x40000 != 0 || RegExp(r'bold|black|heavy|semibold|demi').hasMatch(lower),
          italic: flags & 0x40 != 0 || RegExp(r'italic|oblique').hasMatch(lower),
          embedded: font != nullptr && _pdf.fontEmbedded(font) != 0,
          color: color,
        ));
      }
    } finally {
      if (textPage != nullptr) _pdf.textClosePage(textPage);
      _pdf.free(f4);
      _pdf.free(c4);
      _pdf.free(mat);
    }
    return out;
  }

  @override
  void move(int page, List<int> indices, double dx, double dy) {
    final h = _page(page);
    final (px, py) = _toView(page).inverse().vec(dx, dy);
    for (final i in indices) {
      final obj = _pdf.getObject(h, i);
      if (obj != nullptr) _pdf.objTransform(obj, 1, 0, 0, 1, px, py);
    }
    _generate(page);
  }

  @override
  void scale(int page, List<int> indices, double sx, double sy, double anchorX, double anchorY) {
    final h = _page(page);
    final v = _toView(page);
    final t = v.then(Mat.scaleAbout(sx, sy, anchorX, anchorY)).then(v.inverse());
    for (final i in indices) {
      final obj = _pdf.getObject(h, i);
      if (obj != nullptr) _pdf.objTransform(obj, t.a, t.b, t.c, t.d, t.e, t.f);
    }
    _generate(page);
  }

  void _removeRaw(_H pageHandle, List<int> indices) {
    for (final i in indices.toList()..sort((a, b) => b.compareTo(a))) {
      final obj = _pdf.getObject(pageHandle, i);
      if (obj != nullptr && _pdf.removeObject(pageHandle, obj) != 0) _pdf.objDestroy(obj);
    }
  }

  @override
  void remove(int page, List<int> indices) {
    _removeRaw(_page(page), indices);
    _generate(page);
  }

  _H _font(int page, FontSpec spec) {
    final std = spec.standard;
    if (std != null) {
      return _fonts[std] ??= () {
        final name = _pdf.cstr(std);
        final f = _pdf.loadStandardFont(_doc, name);
        _pdf.free(name);
        if (f == nullptr) throw FfError('Não foi possível carregar a fonte $std.');
        return f;
      }();
    }
    final obj = _pdf.getObject(_page(page), spec.fromObject!);
    return obj == nullptr ? nullptr : _pdf.textObjFont(obj);
  }

  double _right(_H obj, Pointer<Float> f4) => _pdf.objBounds(obj, f4, f4 + 1, f4 + 2, f4 + 3) != 0 ? f4[2] : 0;

  @override
  double textWidth(int page, FontSpec spec, double size, String text) {
    if (text.isEmpty) return 0;
    final font = _font(page, spec);
    if (font == nullptr) return 0;
    final fontKey = spec.standard ?? _fontName(font);
    final key = '$fontKey\u0000$text';
    final cached = _widths[key];
    if (cached != null) return cached * size / 100;
    // O avanço de um texto é a diferença entre a borda direita de "texto+x" e a
    // de "x" sozinho. O "x" de apoio tem de existir na fonte: nas padrão serve
    // a barra; numa fonte do documento, uma letra do próprio texto.
    final probe = spec.standard != null
        ? '|'
        : String.fromCharCode(text.runes.firstWhere((r) => r != 0x20, orElse: () => _probeFor(page, spec.fromObject!)));
    final obj = _pdf.createTextObj(_doc, font, 100);
    if (obj == nullptr) return 0;
    final f4 = _pdf.alloc<Float>(16);
    final a = _pdf.wstr('$text$probe'), b = _pdf.wstr(probe);
    _pdf.setText(obj, a);
    final r1 = _right(obj, f4);
    _pdf.setText(obj, b);
    final r0 = _right(obj, f4);
    _pdf.free(a);
    _pdf.free(b);
    _pdf.free(f4);
    _pdf.objDestroy(obj);
    final w = math.max(0.0, r1 - r0);
    _widths[key] = w;
    return w * size / 100;
  }

  /// Uma letra que com certeza existe na fonte do objeto [index]: a primeira dele.
  int _probeFor(int page, int index) {
    final h = _page(page);
    final tp = _pdf.textLoadPage(h);
    var rune = 0x61;
    if (tp != nullptr) {
      final obj = _pdf.getObject(h, index);
      if (obj != nullptr) {
        final t = _readText(obj, tp).runes.where((r) => r != 0x20);
        if (t.isNotEmpty) rune = t.first;
      }
      _pdf.textClosePage(tp);
    }
    return rune;
  }

  static String _squash(String s) => s.replaceAll(RegExp(r'\s+'), '');

  /// Fontes do Windows com as mesmas medidas das 12 padrão do PDF.
  static const _ttf = {
    'Helvetica': 'arial.ttf',
    'Helvetica-Bold': 'arialbd.ttf',
    'Helvetica-Oblique': 'ariali.ttf',
    'Helvetica-BoldOblique': 'arialbi.ttf',
    'Times-Roman': 'times.ttf',
    'Times-Bold': 'timesbd.ttf',
    'Times-Italic': 'timesi.ttf',
    'Times-BoldItalic': 'timesbi.ttf',
    'Courier': 'cour.ttf',
    'Courier-Bold': 'courbd.ttf',
    'Courier-Oblique': 'couri.ttf',
    'Courier-BoldOblique': 'courbi.ttf',
  };

  /// A equivalente do Windows de uma fonte padrão, embutida no PDF.
  _H _systemFont(String std) => _sysFonts[std] ??= () {
        final file = _ttf[std];
        if (file == null) return nullptr;
        final dir = Platform.environment['FILUME_FONTS_DIR'] ?? p.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'Fonts');
        final f = File(p.join(dir, file));
        if (!f.existsSync()) return nullptr;
        final bytes = f.readAsBytesSync();
        final data = _pdf.alloc<Uint8>(bytes.length);
        data.asTypedList(bytes.length).setAll(0, bytes);
        _fontData.add(data);
        // 2 = TrueType; CID ligado: escreve qualquer letra que a fonte tenha.
        return _pdf.loadFont(_doc, data, bytes.length, 2, 1);
      }();

  /// Fonte do documento, não embutida e com o mesmo nome de [std], usada na
  /// página. Ao gravar, o PDFium junta as duas num recurso só (pelo nome), e o
  /// texto novo herdaria a codificação dela: acentos trocados.
  _H _clash(int page, String std, _H mine) {
    final h = _page(page);
    final n = _pdf.countObjects(h);
    for (var i = 0; i < n; i++) {
      final obj = _pdf.getObject(h, i);
      if (obj == nullptr || _pdf.objType(obj) != 1) continue;
      final f = _pdf.textObjFont(obj);
      if (f == nullptr || f == mine || _pdf.fontEmbedded(f) != 0) continue;
      if (_fontName(f) == std) return f;
    }
    return nullptr;
  }

  @override
  bool addText(int page, List<TextLine> lines, FontSpec spec, double size, int color) {
    final std = spec.standard;
    if (std != null) {
      final other = _clash(page, std, _font(page, spec));
      if (other != nullptr) {
        // Primeiro com a própria fonte do documento (sai igual ao resto);
        // se ela não tiver as letras, com a equivalente do Windows.
        if (_write(page, lines, other, size, color, verify: true)) return true;
        final sys = _systemFont(std);
        if (sys != nullptr && _write(page, lines, sys, size, color, verify: true)) return true;
        throw FfError('Não foi possível escrever esse texto na página ${page + 1} sem trocar letras acentuadas.',
            'A página já usa a fonte $std com outra codificação.');
      }
    }
    final font = _font(page, spec);
    if (font == nullptr) return false;
    final reuse = std == null;
    if (reuse && lines.any((l) => l.text.contains(' ')) && textWidth(page, spec, size, ' ') < 0.08 * size) {
      return false; // a fonte do documento não tem o espaço: as palavras grudariam
    }
    final ok = _write(page, lines, font, size, color, verify: reuse);
    if (!ok && !reuse) throw FfError('Não foi possível escrever o texto na página ${page + 1}.');
    return ok;
  }

  /// Escreve as linhas com [font]; com [verify], confere lendo de volta e
  /// desfaz tudo se o texto não sair igual.
  bool _write(int page, List<TextLine> lines, _H font, double size, int color, {required bool verify}) {
    final h = _page(page);
    final inv = _toView(page).inverse();
    final (a, b) = inv.vec(1, 0);
    final (c, d) = inv.vec(0, -1);
    final before = _pdf.countObjects(h);
    var ok = true;
    for (final line in lines) {
      if (line.text.isEmpty) continue;
      final obj = _pdf.createTextObj(_doc, font, size);
      if (obj == nullptr) {
        ok = false;
        break;
      }
      final w = _pdf.wstr(line.text);
      final set = _pdf.setText(obj, w);
      _pdf.free(w);
      if (set == 0) {
        _pdf.objDestroy(obj);
        ok = false;
        break;
      }
      _pdf.setFillColor(obj, (color >> 16) & 255, (color >> 8) & 255, color & 255, (color >> 24) & 255);
      final (e, f) = inv.apply(line.x, line.baseline);
      _pdf.objTransform(obj, a, b, c, d, e, f);
      _pdf.insertObject(h, obj);
    }
    final after = _pdf.countObjects(h);
    if (ok && verify) {
      // Confere se a fonte escreveu mesmo o que foi pedido.
      final tp = _pdf.textLoadPage(h);
      if (tp == nullptr) {
        ok = false;
      } else {
        final wanted = lines.where((l) => l.text.isNotEmpty).toList();
        if (after - before != wanted.length) ok = false;
        for (var i = 0; ok && i < wanted.length; i++) {
          final got = _readText(_pdf.getObject(h, before + i), tp);
          if (_squash(got) != _squash(wanted[i].text)) ok = false;
        }
        _pdf.textClosePage(tp);
      }
    }
    if (!ok) {
      _removeRaw(h, [for (var i = before; i < after; i++) i]);
      return false;
    }
    _generate(page);
    return true;
  }

  @override
  void addPath(int page, PathSpec path) {
    final h = _page(page);
    final inv = _toView(page).inverse();
    _H obj = nullptr;
    for (final s in path.segs) {
      final kind = s[0].toInt();
      if (kind == 0) {
        final (x, y) = inv.apply(s[1], s[2]);
        if (obj == nullptr) {
          obj = _pdf.createPath(x, y);
          if (obj == nullptr) throw FfError('Não foi possível criar o desenho.');
        } else {
          _pdf.pathMoveTo(obj, x, y);
        }
      } else if (obj == nullptr) {
        continue;
      } else if (kind == 1) {
        final (x, y) = inv.apply(s[1], s[2]);
        _pdf.pathLineTo(obj, x, y);
      } else if (kind == 2) {
        final (x1, y1) = inv.apply(s[1], s[2]);
        final (x2, y2) = inv.apply(s[3], s[4]);
        final (x, y) = inv.apply(s[5], s[6]);
        _pdf.pathBezierTo(obj, x1, y1, x2, y2, x, y);
      } else {
        _pdf.pathClose(obj);
      }
    }
    if (obj == nullptr) return;
    final stroke = path.stroke, fill = path.fill;
    if (stroke != null) {
      _pdf.setStrokeColor(obj, (stroke >> 16) & 255, (stroke >> 8) & 255, stroke & 255, (stroke >> 24) & 255);
      _pdf.setStrokeWidth(obj, path.width);
      _pdf.setLineCap(obj, 1);
      _pdf.setLineJoin(obj, 1);
    }
    if (fill != null) _pdf.setFillColor(obj, (fill >> 16) & 255, (fill >> 8) & 255, fill & 255, (fill >> 24) & 255);
    _pdf.pathSetDrawMode(obj, fill != null ? 1 : 0, stroke != null ? 1 : 0);
    if (path.multiply) {
      final mode = _pdf.cstr('Multiply');
      _pdf.setBlendMode(obj, mode);
      _pdf.free(mode);
    }
    _pdf.insertObject(h, obj);
    _generate(page);
  }

  @override
  void addImage(int page, Uint8List rgba, int width, int height, double l, double t, double w, double hgt) {
    final h = _page(page);
    final buf = _pdf.alloc<Uint8>(width * height * 4);
    final px = buf.asTypedList(width * height * 4);
    for (var i = 0; i + 3 < rgba.length && i + 3 < px.length; i += 4) {
      px[i] = rgba[i + 2];
      px[i + 1] = rgba[i + 1];
      px[i + 2] = rgba[i];
      px[i + 3] = rgba[i + 3];
    }
    final bmp = _pdf.bitmapCreate(width, height, 4, buf.cast(), width * 4);
    final img = _pdf.newImageObj(_doc);
    try {
      if (bmp == nullptr || img == nullptr || _pdf.imageSetBitmap(nullptr, 0, img, bmp) == 0) {
        if (img != nullptr) _pdf.objDestroy(img);
        throw FfError('Não foi possível inserir a imagem.');
      }
      // O quadrado (0,0)-(1,1) da imagem vai para o retângulo pedido na tela.
      final inv = _toView(page).inverse();
      final (a, b) = inv.vec(w, 0);
      final (c, d) = inv.vec(0, -hgt);
      final (e, f) = inv.apply(l, t + hgt);
      _pdf.imageSetMatrix(img, a, b, c, d, e, f);
      _pdf.insertObject(h, img);
    } finally {
      if (bmp != nullptr) _pdf.bitmapDestroy(bmp);
      _pdf.free(buf);
    }
    _generate(page);
  }

  @override
  RenderedPage render(int page, double scale) {
    final h = _page(page);
    final w = math.max(1, (_pdf.pageWidth(h) * scale).round()), ht = math.max(1, (_pdf.pageHeight(h) * scale).round());
    final bmp = _pdf.bitmapCreate(w, ht, 4, nullptr, 0);
    if (bmp == nullptr) throw FfError('Sem memória para desenhar a página.');
    try {
      _pdf.bitmapFill(bmp, 0, 0, w, ht, 0xFFFFFFFF);
      _pdf.renderPage(bmp, h, 0, 0, w, ht, 0, 0x01);
      final stride = _pdf.bitmapStride(bmp);
      final src = _pdf.bitmapBuffer(bmp).cast<Uint8>().asTypedList(stride * ht);
      final out = Uint8List(w * ht * 4);
      for (var y = 0; y < ht; y++) {
        out.setRange(y * w * 4, (y + 1) * w * 4, src, y * stride);
      }
      return RenderedPage(out, w, ht);
    } finally {
      _pdf.bitmapDestroy(bmp);
    }
  }

  @override
  void save(String path) {
    final file = File(path).openSync(mode: FileMode.write);
    final fw = _pdf.alloc<_FileWrite>(32);
    fw.ref.version = 1;
    fw.ref.writeBlock = Pointer.fromFunction<_WriteBlockC>(_writeBlock, 0);
    _saveTarget = file;
    var ok = false;
    try {
      ok = _pdf.saveAsCopy(_doc, fw, 2) != 0; // 2 = arquivo completo, sem acréscimos
    } finally {
      _saveTarget = null;
      file.closeSync();
      _pdf.free(fw);
    }
    if (!ok) {
      try {
        File(path).deleteSync();
      } catch (_) {}
      throw FfError('O PDFium não conseguiu gravar o PDF.');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final h in _pages.values) {
      _pdf.closePage(h);
    }
    for (final f in [..._fonts.values, ..._sysFonts.values]) {
      if (f != nullptr) _pdf.fontClose(f);
    }
    _pdf.closeDocument(_doc);
    _pdf.free(_data);
    for (final d in _fontData) {
      _pdf.free(d);
    }
  }
}
