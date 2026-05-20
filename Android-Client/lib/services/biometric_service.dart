import 'dart:convert';
import 'package:local_auth/local_auth.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

class BiometricService {
  static final BiometricService instance = BiometricService._();
  BiometricService._();

  final LocalAuthentication _auth = LocalAuthentication();
  
  // Ephemeral signing key for the current session handshake
  SimpleKeyPair? _signingKey;

  Future<void> initSecurity() async {
    final algorithm = Ed25519();
    _signingKey = await algorithm.newKeyPair();
    debugPrint('Eunify: Generated new Ed25519 signing keypair for session.');
  }

  /// Triggers the native Android BiometricPrompt.
  /// If successful, signs the challenge string and returns the signature.
  Future<String?> authenticateAndSign(String challenge) async {
    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await _auth.isDeviceSupported();

      if (!canAuthenticate) {
        debugPrint('Eunify: Device does not support biometrics.');
        return null;
      }

      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: 'Authorize Mac Unlock',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true, // Force fingerprint/face, no PIN fallback for max security
        ),
      );

      if (didAuthenticate) {
        if (_signingKey == null) await initSecurity();
        
        final algorithm = Ed25519();
        // Sign the raw challenge bytes
        final signature = await algorithm.sign(
          utf8.encode(challenge),
          keyPair: _signingKey!,
        );
        
        final signatureBase64 = base64Encode(signature.bytes);
        debugPrint('Eunify: Authentication successful. Signature generated.');
        return signatureBase64;
      } else {
        debugPrint('Eunify: Biometric authentication failed or canceled.');
      }
    } catch (e) {
      debugPrint('Eunify Biometric Error: $e');
    }
    return null;
  }

  /// Returns the public key to share with the Mac during pairing.
  Future<String?> getPublicKey() async {
    if (_signingKey == null) await initSecurity();
    final pk = await _signingKey!.extractPublicKey();
    return base64Encode(pk.bytes);
  }
}
