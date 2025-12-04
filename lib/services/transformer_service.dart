import 'package:flutter/material.dart';

/// Enum representing different content types
enum ContentType { plainText, json, jwt, hexColor }

/// JWT payload data
class JwtPayload {
  const JwtPayload({required this.claims, this.expiration, this.userId});

  final Map<String, dynamic> claims;
  final DateTime? expiration;
  final String? userId;
}

/// Abstract interface for smart content transformation
abstract class ITransformerService {
  /// Detect the content type of the given string
  ContentType detectType(String content);

  /// Prettify JSON content with proper indentation
  String prettifyJson(String json);

  /// Decode a JWT token and extract payload
  JwtPayload? decodeJwt(String token);

  /// Parse a hex color code
  Color? parseHexColor(String text);
}
