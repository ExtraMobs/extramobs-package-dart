/// TLS negotiation policy. Omit it to use FreeTDS configuration and defaults.
sealed class TlsConfig {
  const TlsConfig();
}

/// Capability shared by modes that can authenticate a server certificate.
base mixin TlsWithTrust {
  TlsTrust? get trust;
  String? get certificateHostname;
}

/// Strict mode cannot expose an absent trust source.
base mixin TlsWithRequiredTrust on TlsWithTrust {
  @override
  TlsTrust get trust;
}

final class TlsOff extends TlsConfig {
  const TlsOff();
}

final class TlsRequest extends TlsConfig with TlsWithTrust {
  @override
  final TlsTrust? trust;
  @override
  final String? certificateHostname;

  const TlsRequest({this.trust, this.certificateHostname});
}

final class TlsRequire extends TlsConfig with TlsWithTrust {
  @override
  final TlsTrust? trust;
  @override
  final String? certificateHostname;

  const TlsRequire({this.trust, this.certificateHostname});
}

/// Requires a TDS 8.0 server and an explicit, non-null trust source.
final class TlsStrict extends TlsConfig
    with TlsWithTrust, TlsWithRequiredTrust {
  @override
  final TlsTrust trust;
  @override
  final String? certificateHostname;

  const TlsStrict({required this.trust, this.certificateHostname});
}

sealed class TlsTrust {
  const TlsTrust();
}

/// Uses the certificate authorities available to the native TLS library.
final class TlsSystemTrust extends TlsTrust {
  const TlsSystemTrust();
}

/// An absolute path to a PEM file containing trusted certificate authorities.
final class TlsPemTrust extends TlsTrust {
  final String path;
  const TlsPemTrust(this.path);
}
