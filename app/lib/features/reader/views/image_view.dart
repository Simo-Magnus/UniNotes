import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../reader_controller.dart';
import 'reader_surface.dart';

/// Immagine con zoom (pizzico, rotellina, Ctrl +/−/0) e trascinamento.
/// File (PNG, JPEG, GIF, WebP, BMP, HEIC dove il sistema lo decodifica),
/// byte già convertiti (TIFF) o SVG.
class ImageView extends StatefulWidget {
  const ImageView({
    super.key,
    this.path,
    this.bytes,
    this.svg = false,
    this.controller,
    this.onUnsupported,
  });

  final String? path;
  final Uint8List? bytes;
  final bool svg;
  final ReaderPaneController? controller;

  /// Immagine non decodificabile (es. HEIC su Windows): messaggio sostitutivo.
  final Widget Function(BuildContext context)? onUnsupported;

  @override
  State<ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<ImageView> {
  final _t = TransformationController();

  @override
  void initState() {
    super.initState();
    widget.controller?.update(() => widget.controller!.onZoom = _zoom);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _zoom(int dir) {
    if (dir == 0) {
      _t.value = Matrix4.identity();
      return;
    }
    final size = context.size ?? Size.zero;
    final center = Offset(size.width / 2, size.height / 2);
    final f = dir > 0 ? 1.25 : 0.8;
    final current = _t.value.getMaxScaleOnAxis();
    final next = (current * f).clamp(1.0, 8.0);
    final k = next / current;
    _t.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_t.value);
  }

  Widget _error(BuildContext context) =>
      widget.onUnsupported?.call(context) ??
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Questa immagine non si può mostrare su questo dispositivo.',
            textAlign: TextAlign.center,
            style: TextStyle(color: ReaderSurface.of(context).muted),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final Widget image;
    if (widget.svg && widget.bytes != null) {
      image = SvgPicture.memory(
        widget.bytes!,
        fit: BoxFit.contain,
        errorBuilder: (c, _, _) => _error(c),
      );
    } else if (widget.bytes != null) {
      image = Image.memory(
        widget.bytes!,
        fit: BoxFit.contain,
        errorBuilder: (c, _, _) => _error(c),
      );
    } else {
      image = Image.file(
        File(widget.path!),
        fit: BoxFit.contain,
        errorBuilder: (c, _, _) => _error(c),
      );
    }
    return ColoredBox(
      color: ReaderSurface.of(context).background,
      child: InteractiveViewer(
        transformationController: _t,
        minScale: 1,
        maxScale: 8,
        child: SizedBox.expand(child: image),
      ),
    );
  }
}

/// Pagina a schermo intero per un'immagine di un documento.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.bytes, required this.title});
  final Uint8List bytes;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
    body: ImageView(bytes: bytes),
  );
}
