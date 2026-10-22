import 'audio_pairing.dart';

abstract class AudioSignaling {
  void Function()? onPeerReady;
  void Function(Map<String, dynamic> description)? onOffer;
  void Function(Map<String, dynamic> description)? onAnswer;
  void Function(Map<String, dynamic> candidate)? onCandidate;
  void Function(Map<String, dynamic> message)? onControl;
  void Function()? onRemoteHangup;

  String? get roomCode;
  String? get pairingUri;

  Future<String> createRoom({AudioPairingCredentials? credentials});
  Future<bool> joinRoom(String pairingValue);
  Future<void> sendOffer(Map<String, dynamic> offer);
  Future<void> sendAnswer(Map<String, dynamic> answer);
  Future<void> sendControl(Map<String, dynamic> message);
  void addCandidate(Map<String, dynamic> candidate);
  Future<void> rearmForNewPeer();
  Future<void> hangUp();
}
