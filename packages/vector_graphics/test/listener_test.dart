// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert' show base64;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics/src/listener.dart';
import 'package:vector_graphics/vector_graphics_compat.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const svgString = '''
<svg width="10" height="10">
  <rect x="0" y="0" height="15" width="15" fill="black" />
</svg>
''';

  const bluePngPixel =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPj/HwADBwIAMCbHYQAAAABJRU5ErkJggg==';

  late ByteData vectorGraphicBuffer;

  setUpAll(() async {
    final Uint8List bytes = encodeSvg(
      xml: svgString,
      debugName: 'test',
      enableClippingOptimizer: false,
      enableMaskingOptimizer: false,
      enableOverdrawOptimizer: false,
    );
    vectorGraphicBuffer = bytes.buffer.asByteData();
  });

  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  test('decode without clip', () async {
    final PictureInfo info = await decodeVectorGraphics(
      vectorGraphicBuffer,
      locale: ui.PlatformDispatcher.instance.locale,
      textDirection: ui.TextDirection.ltr,
      clipViewbox: true,
      loader: const AssetBytesLoader('test'),
    );
    final ui.Image image = info.picture.toImageSync(15, 15);
    final Uint32List imageBytes = (await image.toByteData())!.buffer.asUint32List();
    expect(imageBytes.first, 0xFF000000);
    expect(imageBytes.last, 0x00000000);
  }, skip: kIsWeb);

  test('decode with clip', () async {
    final PictureInfo info = await decodeVectorGraphics(
      vectorGraphicBuffer,
      locale: ui.PlatformDispatcher.instance.locale,
      textDirection: ui.TextDirection.ltr,
      clipViewbox: false,
      loader: const AssetBytesLoader('test'),
    );
    final ui.Image image = info.picture.toImageSync(15, 15);
    final Uint32List imageBytes = (await image.toByteData())!.buffer.asUint32List();
    expect(imageBytes.first, 0xFF000000);
    expect(imageBytes.last, 0xFF000000);
  }, skip: kIsWeb);

  test('Scales image correctly', () async {
    final factory = TestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onImage(0, 0, base64.decode(bluePngPixel));
    await listener.waitForImageDecode();
    listener.onDrawImage(0, 10, 10, 30, 30, null);
    final Invocation drawRect = factory.fakeCanvases.first.invocations.single;
    expect(drawRect.isMethod, true);
    expect(drawRect.memberName, #drawImageRect);
    expect(drawRect.positionalArguments[1], const ui.Rect.fromLTRB(0, 0, 1, 1));
    expect(drawRect.positionalArguments[2], const ui.Rect.fromLTRB(10, 10, 40, 40));
  });

  test('Pattern start clips the new canvas', () async {
    final factory = TestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onPatternStart(0, 0, 0, 100, 100, Matrix4.identity().storage);
    final Invocation clipRect = factory.fakeCanvases.last.invocations.single;
    expect(clipRect.isMethod, true);
    expect(clipRect.memberName, #clipRect);
    expect(clipRect.positionalArguments.single, const ui.Rect.fromLTRB(0, 0, 100, 100));
  });

  test('Mask content is applied in two passes: luminance then alpha', () {
    final factory = _RecordingTestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onPaintObject(
      color: const ui.Color(0xffff0000).toARGB32(),
      strokeCap: null,
      strokeJoin: null,
      blendMode: BlendMode.srcOver.index,
      strokeMiterLimit: null,
      strokeWidth: null,
      paintStyle: ui.PaintingStyle.fill.index,
      id: 0,
      shaderId: null,
    );
    listener.onPathStart(0, 0);
    listener.onPathMoveTo(0, 0);
    listener.onPathLineTo(10, 0);
    listener.onPathLineTo(10, 10);
    listener.onPathLineTo(0, 10);
    listener.onPathClose();
    listener.onPathFinished();

    // A draw before the mask targets the main canvas.
    listener.onDrawPath(0, 0, null);
    listener.onMask();
    // A draw inside the mask targets the mask recording canvas.
    listener.onDrawPath(0, 0, null);
    listener.onRestoreLayer();

    final FakeCanvas mainCanvas = factory.fakeCanvases[0];
    final FakeCanvas maskCanvas = factory.fakeCanvases[1];

    expect(mainCanvas.invocations.first.memberName, #drawPath);
    expect(maskCanvas.invocations.single.memberName, #drawPath);

    final Iterable<Symbol> layerOps = mainCanvas.invocations
        .where(
          (Invocation invocation) =>
              invocation.memberName == #saveLayer ||
              invocation.memberName == #drawPicture ||
              invocation.memberName == #restore,
        )
        .map((Invocation invocation) => invocation.memberName);
    expect(layerOps, <Symbol>[
      #saveLayer, // Pass 1: multiply destination alpha by luminance.
      #drawPicture,
      #restore,
      #saveLayer, // Pass 2: multiply destination alpha by mask alpha.
      #drawPicture,
      #restore,
    ]);

    final List<ui.Paint> layerPaints = mainCanvas.invocations
        .where((Invocation invocation) => invocation.memberName == #saveLayer)
        .map((Invocation invocation) => invocation.positionalArguments[1] as ui.Paint)
        .toList();
    expect(layerPaints[0].blendMode, ui.BlendMode.dstIn);
    expect(layerPaints[0].colorFilter, isNotNull, reason: 'luminance matrix');
    expect(layerPaints[1].blendMode, ui.BlendMode.dstIn);
    expect(layerPaints[1].colorFilter, isNull, reason: 'plain alpha dstIn');
  });

  test('saveLayer within mask content is restored on the mask canvas', () {
    final factory = _RecordingTestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onPaintObject(
      color: const ui.Color(0xffff0000).toARGB32(),
      strokeCap: null,
      strokeJoin: null,
      blendMode: BlendMode.srcOver.index,
      strokeMiterLimit: null,
      strokeWidth: null,
      paintStyle: ui.PaintingStyle.fill.index,
      id: 0,
      shaderId: null,
    );

    listener.onMask();
    listener.onSaveLayer(0);
    listener.onRestoreLayer(); // Restores the mask canvas, does not finalize.
    expect(factory.fakeCanvases[0].invocations, isEmpty);
    expect(
      factory.fakeCanvases[1].invocations.map((Invocation invocation) => invocation.memberName),
      <Symbol>[#saveLayer, #restore],
    );

    listener.onRestoreLayer(); // Finalizes the mask.
    expect(
      factory.fakeCanvases[0].invocations
          .where((Invocation invocation) => invocation.memberName == #saveLayer)
          .length,
      2,
    );
  });

  test('Text position is respected', () async {
    final factory = TestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onPaintObject(
      color: const ui.Color(0xff000000).toARGB32(),
      strokeCap: null,
      strokeJoin: null,
      blendMode: BlendMode.srcIn.index,
      strokeMiterLimit: null,
      strokeWidth: null,
      paintStyle: ui.PaintingStyle.fill.index,
      id: 0,
      shaderId: null,
    );
    listener.onTextPosition(0, 10, 10, null, null, true, null);
    listener.onUpdateTextPosition(0);
    listener.onTextConfig('foo', null, 0, 0, 16, 0, 0, 0, 0);
    await listener.onDrawText(0, 0, null, null);
    await listener.onDrawText(0, 0, null, null);
    // Force flush of the pending anchored chunk by starting a new one.
    listener.onTextPosition(1, 0, 0, null, null, true, null);
    listener.onUpdateTextPosition(1);

    final Invocation drawParagraph0 = factory.fakeCanvases.last.invocations[0];
    final Invocation drawParagraph1 = factory.fakeCanvases.last.invocations[1];

    expect(drawParagraph0.memberName, #drawParagraph);
    // Only checking the X because Y seems to vary a bit by platform within
    // acceptable range. X is what gets managed by the listener anyway.
    expect((drawParagraph0.positionalArguments[1] as Offset).dx, 10);

    expect(drawParagraph1.memberName, #drawParagraph);
    expect((drawParagraph1.positionalArguments[1] as Offset).dx, 58);
  });

  test('Text anchor middle centers the entire chunk across tspans', () async {
    // SVG: <text x="100" y="50" text-anchor="middle">
    //        <tspan>ABCDEFG</tspan><tspan>ABCDEFG</tspan>
    //      </text>
    // Per SVG spec, the concatenation of both tspans forms a single
    // anchored chunk that should be centered around x=100.
    final factory = TestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onPaintObject(
      color: const ui.Color(0xffff0000).toARGB32(),
      strokeCap: null,
      strokeJoin: null,
      blendMode: BlendMode.srcIn.index,
      strokeMiterLimit: null,
      strokeWidth: null,
      paintStyle: ui.PaintingStyle.fill.index,
      id: 0,
      shaderId: null,
    );
    listener.onTextPosition(0, 100, 50, null, null, true, null);
    listener.onUpdateTextPosition(0);
    // xAnchorMultiplier = 0.5 corresponds to text-anchor="middle".
    listener.onTextConfig('ABCDEFG', null, 0.5, 0, 16, 0, 0, 0, 0);
    await listener.onDrawText(0, 0, null, null);
    // The parser emits a TextPosition for every <tspan>, including those
    // with no x/y. That must NOT break the current anchored chunk.
    listener.onTextPosition(1, null, null, null, null, false, null);
    listener.onUpdateTextPosition(1);
    listener.onTextConfig('ABCDEFG', null, 0.5, 0, 16, 0, 0, 0, 1);
    await listener.onDrawText(1, 0, null, null);
    // Force flush of the pending anchored chunk by starting a new one.
    listener.onTextPosition(2, 0, 0, null, null, true, null);
    listener.onUpdateTextPosition(2);

    final Invocation drawParagraph0 = factory.fakeCanvases.last.invocations[0];
    final Invocation drawParagraph1 = factory.fakeCanvases.last.invocations[1];
    expect(drawParagraph0.memberName, #drawParagraph);
    expect(drawParagraph1.memberName, #drawParagraph);

    final double dx0 = (drawParagraph0.positionalArguments[1] as Offset).dx;
    final double dx1 = (drawParagraph1.positionalArguments[1] as Offset).dx;

    // The chunk is two equal tspans of width w. text-anchor="middle" centers
    // the whole chunk (total width 2w) around x=100, so:
    //   dx0 = 100 - w   (left tspan)
    //   dx1 = 100       (right tspan)
    // Therefore the second tspan should start exactly at the original x=100.
    expect(dx1, 100, reason: 'second tspan should start at the original x');
    final double w = 100 - dx0;
    expect(dx1 - dx0, w, reason: 'tspans should be contiguous within the chunk');
  });

  test('should assert when imageId is invalid', () async {
    final factory = TestPictureFactory();
    final listener = FlutterVectorGraphicsListener(pictureFactory: factory);
    listener.onImage(0, 0, base64.decode(bluePngPixel));
    await listener.waitForImageDecode();
    expect(() => listener.onDrawImage(2, 10, 10, 100, 100, null), throwsAssertionError);
  });

  group('luminance mask', () {
    // The repro files from https://github.com/flutter/flutter/issues/190125.
    const maskSvg = '''
<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <mask id="m" style="mask-type:luminance" maskUnits="userSpaceOnUse" x="10" y="10" width="80" height="80">
    <path d="M50 10L90 50L50 90L10 50Z" fill="white"/>
  </mask>
  <g mask="url(#m)">
    <rect width="100" height="100" fill="#1565C0"/>
  </g>
</svg>
''';
    const clipSvg = '''
<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <clipPath id="m">
    <path d="M50 10L90 50L50 90L10 50Z" fill="white"/>
  </clipPath>
  <g clip-path="url(#m)">
    <rect width="100" height="100" fill="#1565C0"/>
  </g>
</svg>
''';
    const maskOpacitySvg = '''
<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <mask id="m" style="mask-type:luminance" maskUnits="userSpaceOnUse" x="10" y="10" width="80" height="80">
    <path d="M50 10L90 50L50 90L10 50Z" fill="white" opacity="0.5"/>
  </mask>
  <g mask="url(#m)">
    <rect width="100" height="100" fill="#1565C0"/>
  </g>
</svg>
''';

    Future<ui.Image> renderToImage(String svg) async {
      final Uint8List bytes = encodeSvg(
        xml: svg,
        debugName: 'test',
        enableClippingOptimizer: false,
        enableMaskingOptimizer: false,
        enableOverdrawOptimizer: false,
      );
      final PictureInfo info = await decodeVectorGraphics(
        bytes.buffer.asByteData(),
        locale: ui.PlatformDispatcher.instance.locale,
        textDirection: ui.TextDirection.ltr,
        clipViewbox: true,
        loader: const AssetBytesLoader('test'),
      );
      return info.picture.toImageSync(100, 100);
    }

    test('antialiases boundaries like an equivalent clipPath', () async {
      final ui.Image maskImage = await renderToImage(maskSvg);
      final ui.Image clipImage = await renderToImage(clipSvg);
      try {
        final ByteData maskData = (await maskImage.toByteData())!;
        final ByteData clipData = (await clipImage.toByteData())!;
        var partialMask = 0;
        var partialClip = 0;
        for (var i = 3; i < maskData.lengthInBytes; i += 4) {
          if (maskData.getUint8(i) > 0 && maskData.getUint8(i) < 255) {
            partialMask++;
          }
          if (clipData.getUint8(i) > 0 && clipData.getUint8(i) < 255) {
            partialClip++;
          }
        }
        // Before the fix, mask.svg had zero partially-opaque pixels.
        expect(partialMask, greaterThan(100));
        expect(partialClip, greaterThan(100));
        // The masked diamond must match the clip reference along the edge row.
        for (var x = 26; x <= 36; x++) {
          final int maskAlpha = maskData.getUint8((30 * 100 + x) * 4 + 3);
          final int clipAlpha = clipData.getUint8((30 * 100 + x) * 4 + 3);
          expect(maskAlpha, clipAlpha, reason: 'mask and clip differ at x=$x');
        }
      } finally {
        maskImage.dispose();
        clipImage.dispose();
      }
    }, skip: kIsWeb);

    test('respects mask content opacity', () async {
      final ui.Image image = await renderToImage(maskOpacitySvg);
      try {
        final ByteData data = (await image.toByteData())!;
        // Interior: luminance(white) * alpha(0.5) -> ~50% opaque.
        final int centerAlpha = data.getUint8((50 * 100 + 50) * 4 + 3);
        expect(centerAlpha, inInclusiveRange(100, 155));
        var partial = 0;
        for (var i = 3; i < data.lengthInBytes; i += 4) {
          final int a = data.getUint8(i);
          if (a > 0 && a < 255) {
            partial++;
          }
        }
        expect(partial, greaterThan(100));
      } finally {
        image.dispose();
      }
    }, skip: kIsWeb);
  });
}

class TestPictureFactory implements PictureFactory {
  final List<FakeCanvas> fakeCanvases = <FakeCanvas>[];
  @override
  ui.Canvas createCanvas(ui.PictureRecorder recorder) {
    fakeCanvases.add(FakeCanvas());
    return fakeCanvases.last;
  }

  @override
  ui.PictureRecorder createPictureRecorder() => FakePictureRecorder();
}

class FakePictureRecorder extends Fake implements ui.PictureRecorder {}

/// A [PictureFactory] that creates real [ui.PictureRecorder]s (so
/// [ui.PictureRecorder.endRecording] returns a valid [ui.Picture]) but fake
/// canvases, so the drawing commands can be inspected.
class _RecordingTestPictureFactory implements PictureFactory {
  final List<FakeCanvas> fakeCanvases = <FakeCanvas>[];

  @override
  ui.Canvas createCanvas(ui.PictureRecorder recorder) {
    // Bind the recorder so that endRecording() produces a valid Picture; the
    // returned fake canvas captures the drawing commands for assertions.
    ui.Canvas(recorder);
    fakeCanvases.add(FakeCanvas());
    return fakeCanvases.last;
  }

  @override
  ui.PictureRecorder createPictureRecorder() => ui.PictureRecorder();
}

class FakeCanvas implements ui.Canvas {
  final List<Invocation> invocations = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    invocations.add(invocation);
  }
}
