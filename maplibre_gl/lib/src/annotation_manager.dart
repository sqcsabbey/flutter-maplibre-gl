part of '../maplibre_gl.dart';

abstract class AnnotationManager<T extends Annotation> {
  final MapLibreMapController controller;
  final _idToAnnotation = <String, T>{};
  final _idToLayerIndex = <String, int>{};

  /// Called if a annotation is tapped
  final ArgumentCallback<T>? onTap;

  /// Called if a annotation is dragged
  final ArgumentCallback2<T, DragEventType>? onDrag;

  /// base id of the manager. User [layerdIds] to get the actual ids.
  final String id;

  List<String> get layerIds =>
      [for (int i = 0; i < allLayerProperties.length; i++) _makeLayerId(i)];

  /// If disabled the manager offers no interaction for the created symbols
  final bool enableInteraction;

  /// If set, this manager's layers are inserted below the layer with this id
  /// instead of on top of the style. Lets an app pin its own layers above the
  /// annotations: add a stable anchor layer on top, point [belowLayerId] at
  /// it, and anything added above the anchor survives the manager's layer
  /// rebuilds (which otherwise re-insert at the very top of the style).
  ///
  /// A rebuild that runs while the anchor is momentarily absent falls back to
  /// adding on top (see [_addManagerLayer]) and self-corrects on the next
  /// rebuild, so a stale id never crashes the manager.
  String? belowLayerId;

  /// implemented to define the layer properties
  List<LayerProperties> get allLayerProperties;

  /// used to spedicy the layer and annotation will life on
  /// This can be replaced by layer filters a soon as they are implemented
  final int Function(T)? selectLayer;

  /// get the an annotation by its id
  T? byId(String id) => _idToAnnotation[id];

  Set<T> get annotations => _idToAnnotation.values.toSet();

  AnnotationManager(
    this.controller, {
    this.onTap,
    this.onDrag,
    this.selectLayer,
    required this.enableInteraction,
    this.belowLayerId,
  }) : id = getRandomString() {
    for (var i = 0; i < allLayerProperties.length; i++) {
      final layerId = _makeLayerId(i);
      controller.addGeoJsonSource(layerId, buildFeatureCollection([]),
          promoteId: "id");
      _addManagerLayer(i);
    }

    if (onTap != null) {
      controller.onFeatureTapped.add(_onFeatureTapped);
    }
    controller.onFeatureDrag.add(_onDrag);
  }

  /// Adds this manager's layer [layerIndex], honoring [belowLayerId] when set.
  /// If anchoring fails — e.g. the anchor layer isn't present yet — retries
  /// unanchored (on top) so a missing anchor never throws; the next rebuild
  /// re-anchors it.
  Future<void> _addManagerLayer(int layerIndex) async {
    final layerId = _makeLayerId(layerIndex);
    final properties = allLayerProperties[layerIndex];
    final below = belowLayerId;
    if (below == null) {
      await controller.addLayer(layerId, layerId, properties);
      return;
    }
    try {
      await controller.addLayer(layerId, layerId, properties,
          belowLayerId: below);
    } catch (_) {
      await controller.addLayer(layerId, layerId, properties);
    }
  }

  /// Sets [belowLayerId] and rebuilds the manager's layers so they move to
  /// the new anchor immediately. Pass null to revert to adding on top.
  Future<void> setBelowLayerId(String? id) async {
    belowLayerId = id;
    await _rebuildLayers();
  }

  /// This function can be used to rebuild all layers after their properties
  /// changed
  Future<void> _rebuildLayers() async {
    for (var i = 0; i < allLayerProperties.length; i++) {
      final layerId = _makeLayerId(i);
      await controller.removeLayer(layerId);
      await _addManagerLayer(i);
    }
  }

  _onFeatureTapped(
      dynamic id, Point<double> point, LatLng coordinates, String layerId) {
    final annotation = _idToAnnotation[id];
    if (annotation != null) {
      onTap!(annotation);
    }
  }

  String _makeLayerId(int layerIndex) => "${id}_$layerIndex";

  Future<void> _setAll() async {
    if (selectLayer != null) {
      final featureBuckets = [for (final _ in allLayerProperties) <T>[]];

      for (final annotation in _idToAnnotation.values) {
        final layerIndex = selectLayer!(annotation);
        _idToLayerIndex[annotation.id] = layerIndex;
        featureBuckets[layerIndex].add(annotation);
      }

      for (var i = 0; i < featureBuckets.length; i++) {
        await controller.setGeoJsonSource(
            _makeLayerId(i),
            buildFeatureCollection(
                [for (final l in featureBuckets[i]) l.toGeoJson()]));
      }
    } else {
      await controller.setGeoJsonSource(
          _makeLayerId(0),
          buildFeatureCollection(
              [for (final l in _idToAnnotation.values) l.toGeoJson()]));
    }
  }

  /// Adds a multiple annotations to the map. This much faster than calling add
  /// multiple times
  Future<void> addAll(Iterable<T> annotations) async {
    for (final a in annotations) {
      _idToAnnotation[a.id] = a;
    }
    await _setAll();
  }

  /// add a single annotation to the map
  Future<void> add(T annotation) async {
    _idToAnnotation[annotation.id] = annotation;
    await _setAll();
  }

  /// Removes multiple annotations from the map
  Future<void> removeAll(Iterable<T> annotations) async {
    for (final a in annotations) {
      _idToAnnotation.remove(a.id);
    }
    await _setAll();
  }

  /// Remove a single annotation form the map
  Future<void> remove(T annotation) async {
    _idToAnnotation.remove(annotation.id);
    await _setAll();
  }

  /// Removes all annotations from the map
  Future<void> clear() async {
    _idToAnnotation.clear();

    await _setAll();
  }

  /// Fully dipose of all the the resouces managed by the annotation manager.
  /// The manager cannot be used after this has been called
  Future<void> dispose() async {
    _idToAnnotation.clear();
    await _setAll();
    for (var i = 0; i < allLayerProperties.length; i++) {
      await controller.removeLayer(_makeLayerId(i));
      await controller.removeSource(_makeLayerId(i));
    }
  }

  _onDrag(dynamic id,
      {required Point<double> point,
      required LatLng origin,
      required LatLng current,
      required LatLng delta,
      required DragEventType eventType}) async {
    final annotation = byId(id);
    if (annotation != null) {
      annotation.translate(delta);
      await set(annotation);
      onDrag?.call(annotation, eventType);
    }
  }

  /// Set an existing anntotation to the map. Use this to do a fast update for a
  /// single annotation
  Future<void> set(T anntotation) async {
    assert(_idToAnnotation.containsKey(anntotation.id),
        "you can only set existing annotations");
    _idToAnnotation[anntotation.id] = anntotation;
    final oldLayerIndex = _idToLayerIndex[anntotation.id];
    final layerIndex = selectLayer != null ? selectLayer!(anntotation) : 0;
    if (oldLayerIndex != layerIndex) {
      // if the annotation has to be moved to another layer/source we have to
      // set all
      await _setAll();
    } else {
      await controller.setGeoJsonFeature(
          _makeLayerId(layerIndex), anntotation.toGeoJson());
    }
  }
}

class LineManager extends AnnotationManager<Line> {
  LineManager(
    super.controller, {
    super.onTap,
    super.onDrag,
    super.enableInteraction = true,
  }) : super(
          selectLayer: (Line line) => line.options.linePattern == null ? 0 : 1,
        );

  static const _baseProperties = LineLayerProperties(
    lineJoin: [Expressions.get, 'lineJoin'],
    lineOpacity: [Expressions.get, 'lineOpacity'],
    lineColor: [Expressions.get, 'lineColor'],
    lineWidth: [Expressions.get, 'lineWidth'],
    lineGapWidth: [Expressions.get, 'lineGapWidth'],
    lineOffset: [Expressions.get, 'lineOffset'],
    lineBlur: [Expressions.get, 'lineBlur'],
  );

  @override
  List<LayerProperties> get allLayerProperties => [
        _baseProperties,
        _baseProperties.copyWith(const LineLayerProperties(
            linePattern: [Expressions.get, 'linePattern'])),
      ];
}

class FillManager extends AnnotationManager<Fill> {
  FillManager(
    super.controller, {
    super.onTap,
    super.onDrag,
    super.enableInteraction = true,
  }) : super(
          selectLayer: (Fill fill) => fill.options.fillPattern == null ? 0 : 1,
        );

  @override
  List<LayerProperties> get allLayerProperties => const [
        FillLayerProperties(
          fillOpacity: [Expressions.get, 'fillOpacity'],
          fillColor: [Expressions.get, 'fillColor'],
          fillOutlineColor: [Expressions.get, 'fillOutlineColor'],
        ),
        FillLayerProperties(
          fillOpacity: [Expressions.get, 'fillOpacity'],
          fillColor: [Expressions.get, 'fillColor'],
          fillOutlineColor: [Expressions.get, 'fillOutlineColor'],
          fillPattern: [Expressions.get, 'fillPattern'],
        )
      ];
}

class CircleManager extends AnnotationManager<Circle> {
  CircleManager(
    super.controller, {
    super.onTap,
    super.onDrag,
    super.enableInteraction = true,
  });

  @override
  List<LayerProperties> get allLayerProperties => const [
        CircleLayerProperties(
          circleRadius: [Expressions.get, 'circleRadius'],
          circleColor: [Expressions.get, 'circleColor'],
          circleBlur: [Expressions.get, 'circleBlur'],
          circleOpacity: [Expressions.get, 'circleOpacity'],
          circleStrokeWidth: [Expressions.get, 'circleStrokeWidth'],
          circleStrokeColor: [Expressions.get, 'circleStrokeColor'],
          circleStrokeOpacity: [Expressions.get, 'circleStrokeOpacity'],
        )
      ];
}

class SymbolManager extends AnnotationManager<Symbol> {
  SymbolManager(
    super.controller, {
    super.onTap,
    super.onDrag,
    bool iconAllowOverlap = false,
    bool textAllowOverlap = false,
    bool iconIgnorePlacement = false,
    bool textIgnorePlacement = false,
    super.enableInteraction = true,
  })  : _iconAllowOverlap = iconAllowOverlap,
        _textAllowOverlap = textAllowOverlap,
        _iconIgnorePlacement = iconIgnorePlacement,
        _textIgnorePlacement = textIgnorePlacement;

  bool _iconAllowOverlap;
  bool _textAllowOverlap;
  bool _iconIgnorePlacement;
  bool _textIgnorePlacement;

  /// If true, the icon will be visible even if it collides with other previously drawn symbols.
  Future<void> setIconAllowOverlap(bool value) async {
    _iconAllowOverlap = value;
    await _rebuildLayers();
  }

  /// If true, other symbols can be visible even if they collide with the icon.
  Future<void> setTextAllowOverlap(bool value) async {
    _textAllowOverlap = value;
    await _rebuildLayers();
  }

  /// If true, the text will be visible even if it collides with other previously drawn symbols.
  Future<void> setIconIgnorePlacement(bool value) async {
    _iconIgnorePlacement = value;
    await _rebuildLayers();
  }

  /// If true, other symbols can be visible even if they collide with the text.
  Future<void> setTextIgnorePlacement(bool value) async {
    _textIgnorePlacement = value;
    await _rebuildLayers();
  }

  @override
  List<LayerProperties> get allLayerProperties => [
        SymbolLayerProperties(
          iconSize: [Expressions.get, 'iconSize'],
          iconImage: [Expressions.get, 'iconImage'],
          iconRotate: [Expressions.get, 'iconRotate'],
          iconOffset: [Expressions.get, 'iconOffset'],
          iconAnchor: [Expressions.get, 'iconAnchor'],
          iconOpacity: [Expressions.get, 'iconOpacity'],
          iconColor: [Expressions.get, 'iconColor'],
          iconHaloColor: [Expressions.get, 'iconHaloColor'],
          iconHaloWidth: [Expressions.get, 'iconHaloWidth'],
          iconHaloBlur: [Expressions.get, 'iconHaloBlur'],
          // note that web does not support setting this in a fully data driven
          // way this is a upstream issue
          textFont: kIsWeb
              ? null
              : [
                  Expressions.caseExpression,
                  [Expressions.has, 'fontNames'],
                  [Expressions.get, 'fontNames'],
                  [
                    Expressions.literal,
                    ["Open Sans Regular", "Arial Unicode MS Regular"]
                  ],
                ],
          textField: [Expressions.get, 'textField'],
          textSize: [Expressions.get, 'textSize'],
          textMaxWidth: [Expressions.get, 'textMaxWidth'],
          textLetterSpacing: [Expressions.get, 'textLetterSpacing'],
          textJustify: [Expressions.get, 'textJustify'],
          textAnchor: [Expressions.get, 'textAnchor'],
          textRotate: [Expressions.get, 'textRotate'],
          textTransform: [Expressions.get, 'textTransform'],
          textOffset: [Expressions.get, 'textOffset'],
          textOpacity: [Expressions.get, 'textOpacity'],
          textColor: [Expressions.get, 'textColor'],
          textHaloColor: [Expressions.get, 'textHaloColor'],
          textHaloWidth: [Expressions.get, 'textHaloWidth'],
          textHaloBlur: [Expressions.get, 'textHaloBlur'],
          symbolSortKey: [Expressions.get, 'zIndex'],
          iconAllowOverlap: _iconAllowOverlap,
          iconIgnorePlacement: _iconIgnorePlacement,
          textAllowOverlap: _textAllowOverlap,
          textIgnorePlacement: _textIgnorePlacement,
        )
      ];
}
