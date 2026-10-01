abstract interface class PublicIpProbe {
  Future<String?> measure();
}

final class UnavailablePublicIpProbe implements PublicIpProbe {
  const UnavailablePublicIpProbe();
  @override
  Future<String?> measure() async => null;
}
