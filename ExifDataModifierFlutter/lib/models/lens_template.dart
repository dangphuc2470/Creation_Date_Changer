import 'dart:convert';

class LensTemplate {
  final String id;
  final String name; // e.g., "Carl Zeiss Jena 135mm f/3.5"
  final String make; // User can map Make and Model
  final String model;
  final double focalLength;
  final double fNumber;

  LensTemplate({
    required this.id,
    required this.name,
    required this.make,
    required this.model,
    required this.focalLength,
    required this.fNumber,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'make': make,
      'model': model,
      'focalLength': focalLength,
      'fNumber': fNumber,
    };
  }

  factory LensTemplate.fromMap(Map<String, dynamic> map) {
    return LensTemplate(
      id: map['id'],
      name: map['name'],
      make: map['make'] ?? '',
      model: map['model'] ?? '',
      focalLength: (map['focalLength'] as num).toDouble(),
      fNumber: (map['fNumber'] as num).toDouble(),
    );
  }

  String toJson() => json.encode(toMap());

  factory LensTemplate.fromJson(String source) => LensTemplate.fromMap(json.decode(source));
}
