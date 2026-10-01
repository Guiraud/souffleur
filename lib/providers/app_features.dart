import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:souffleur/core/constants.dart';

part 'app_features.freezed.dart';

@freezed
abstract class AppFeatures with _$AppFeatures {
  factory AppFeatures(
    List<Feature> features,
    FeatureKind featureKind,
    String featureName,
  ) = _AppFeatures;
}
